(function () {
  "use strict";

  const bridge = window.ROCKY_ONLYOFFICE_BRIDGE;
  let polling = false;

  async function complete(id) {
    await fetch(`http://127.0.0.1:${bridge.port}/complete?token=${encodeURIComponent(bridge.token)}&id=${encodeURIComponent(id)}`, {
      method: "POST"
    });
  }

  async function apply(command) {
    window.Asc.scope.rockyCommand = command;
    await new Promise((resolve) => {
      window.Asc.plugin.callCommand(function () {
        const update = Asc.scope.rockyCommand;
        if (update.type === "save_active_document") {
          if (Asc.editor && Asc.editor.asc_Save) Asc.editor.asc_Save();
          return;
        }
        const sheet = Api.GetActiveSheet();
        if (update.type === "replace_active_sheet") {
          sheet.GetRange(update.clearRange).Clear();
          const range = sheet.GetRange(update.targetRange);
          range.SetValue(update.values);
          range.SetWrap(true);
          range.SetAlignVertical("top");
          const header = sheet.GetRange(`A1:${update.targetRange.split(":")[1].replace(/\d+$/, "")}1`);
          header.SetBold(true);
          header.SetFontColor(Api.CreateColorFromRGB(247, 251, 255));
          header.SetFillColor(Api.CreateColorFromRGB(40, 71, 92));
          range.AutoFit(false, true);
        }
        if (update.type === "edit_active_sheet") {
          for (const cell of update.cells || []) {
            const range = sheet.GetRange(cell.address);
            range.SetValue(cell.value);
            range.SetWrap(true);
          }
          for (const item of update.ranges || []) {
            const range = sheet.GetRange(item.targetRange);
            range.SetValue(item.values);
            range.SetWrap(true);
            range.SetAlignVertical("top");
            range.AutoFit(false, true);
          }
        }
      }, false, true, resolve);
    });
    if (command.type === "save_active_document") {
      await new Promise((resolve) => window.setTimeout(resolve, 700));
    }
    await complete(command.id);
  }

  async function poll() {
    if (polling || !bridge?.token) return;
    polling = true;
    try {
      const response = await fetch(`http://127.0.0.1:${bridge.port}/next?token=${encodeURIComponent(bridge.token)}`);
      if (response.ok && response.status !== 204) await apply(await response.json());
    } catch (_) {
      // Rocky may not be running yet. Polling resumes quietly.
    } finally {
      polling = false;
    }
  }

  window.Asc.plugin.init = function () {
    poll();
    window.setInterval(poll, 350);
  };
  window.Asc.plugin.event_onDocumentContentReady = poll;
})();
