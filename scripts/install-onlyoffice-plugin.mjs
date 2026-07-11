import { cp, mkdir, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const root = path.resolve(new URL("..", import.meta.url).pathname);
const localConfig = JSON.parse(
  await readFile(path.join(root, "local-data/onlyoffice-bridge.json"), "utf8"),
);
if (typeof localConfig.token !== "string" || !localConfig.token) {
  throw new Error("Start Rocky once to create local-data/onlyoffice-bridge.json, then retry.");
}

const guid = "{5D8D57B6-1C62-4B62-935E-7B364E46A210}";
const source = path.join(root, "integrations/onlyoffice-rocky");
const destination = path.join(
  os.homedir(),
  "Library/Application Support/asc.onlyoffice.ONLYOFFICE/data/sdkjs-plugins",
  guid,
);
await mkdir(destination, { recursive: true });
for (const filename of ["config.json", "index.html", "code.js"]) {
  await cp(path.join(source, filename), path.join(destination, filename));
}
await writeFile(
  path.join(destination, "bridge-config.js"),
  `window.ROCKY_ONLYOFFICE_BRIDGE = ${JSON.stringify({ port: localConfig.port, token: localConfig.token })};\n`,
  { mode: 0o600 },
);
console.log(`Installed Rocky's private ONLYOFFICE plugin under the current macOS user profile.`);
console.log("Restart ONLYOFFICE Desktop Editors to activate it.");
