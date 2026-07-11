import { useCallback, useEffect, useRef, useState } from "react";

import type { RockyConfig, SpreadsheetSpec } from "../../shared/types";

type Phase = "idle" | "connecting" | "listening" | "thinking" | "speaking" | "error";

interface RealtimeEvent {
  type?: string;
  transcript?: string;
  response?: {
    output?: Array<{
      type?: string;
      name?: string;
      call_id?: string;
      arguments?: string;
    }>;
  };
  error?: { message?: string };
}

const phaseCopy: Record<Phase, string> = {
  idle: "Ready for first contact",
  connecting: "Opening a space channel…",
  listening: "Listening",
  thinking: "Thinking in five dimensions…",
  speaking: "Rocky is talking",
  error: "Signal needs repair",
};

function friendlyError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function App(): React.JSX.Element {
  const [config, setConfig] = useState<RockyConfig | null>(null);
  const [phase, setPhase] = useState<Phase>("idle");
  const [error, setError] = useState<string | null>(null);
  const [lastOpened, setLastOpened] = useState<string | null>(null);
  const peerRef = useRef<RTCPeerConnection | null>(null);
  const channelRef = useRef<RTCDataChannel | null>(null);
  const streamRef = useRef<MediaStream | null>(null);

  useEffect(() => {
    window.rocky.getConfig().then(setConfig).catch((caught) => setError(friendlyError(caught)));
    return () => {
      channelRef.current?.close();
      peerRef.current?.close();
      streamRef.current?.getTracks().forEach((track) => track.stop());
    };
  }, []);

  const sendEvent = useCallback((event: object) => {
    const channel = channelRef.current;
    if (!channel || channel.readyState !== "open") throw new Error("Rocky’s data channel is not open.");
    channel.send(JSON.stringify(event));
  }, []);

  const handleSpreadsheetTool = useCallback(
    async (callId: string, argumentText: string) => {
      setPhase("thinking");
      try {
        const spec = JSON.parse(argumentText) as SpreadsheetSpec;
        const result = await window.rocky.createSpreadsheet(spec);
        setLastOpened(result.filename);
        sendEvent({
          type: "conversation.item.create",
          item: {
            type: "function_call_output",
            call_id: callId,
            output: JSON.stringify({
              success: true,
              filename: result.filename,
              path: result.path,
              message: "Workbook created and pulled onscreen in the Mac's default spreadsheet app.",
            }),
          },
        });
      } catch (caught) {
        sendEvent({
          type: "conversation.item.create",
          item: {
            type: "function_call_output",
            call_id: callId,
            output: JSON.stringify({ success: false, error: friendlyError(caught) }),
          },
        });
      }
      sendEvent({ type: "response.create" });
    },
    [sendEvent],
  );

  const handleRealtimeEvent = useCallback(
    (event: RealtimeEvent) => {
      switch (event.type) {
        case "input_audio_buffer.speech_started":
          setPhase("listening");
          break;
        case "input_audio_buffer.speech_stopped":
        case "response.created":
          setPhase("thinking");
          break;
        case "response.output_audio.delta":
          setPhase("speaking");
          break;
        case "response.output_audio.done":
          setPhase("listening");
          break;
        case "response.done":
          for (const item of event.response?.output ?? []) {
            if (item.type === "function_call" && item.name === "create_spreadsheet" && item.call_id) {
              void handleSpreadsheetTool(item.call_id, item.arguments ?? "{}");
            }
          }
          break;
        case "error":
          setError(event.error?.message ?? "The Realtime API reported an unknown error.");
          setPhase("error");
          break;
      }
    },
    [handleSpreadsheetTool],
  );

  const disconnect = useCallback(() => {
    channelRef.current?.close();
    peerRef.current?.close();
    streamRef.current?.getTracks().forEach((track) => track.stop());
    channelRef.current = null;
    peerRef.current = null;
    streamRef.current = null;
    setPhase("idle");
  }, []);

  const connect = useCallback(async () => {
    if (peerRef.current) {
      disconnect();
      return;
    }

    setError(null);
    setPhase("connecting");
    try {
      const secret = await window.rocky.createRealtimeSession();
      const peer = new RTCPeerConnection();
      peerRef.current = peer;

      const audio = document.createElement("audio");
      audio.autoplay = true;
      peer.ontrack = (event) => {
        audio.srcObject = event.streams[0] ?? null;
      };
      peer.onconnectionstatechange = () => {
        if (peer.connectionState === "failed" || peer.connectionState === "disconnected") {
          setError("The voice connection dropped. Tap the orb to reconnect.");
          disconnect();
        }
      };

      const stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
        },
      });
      streamRef.current = stream;
      const track = stream.getAudioTracks()[0];
      if (!track) throw new Error("No microphone was found.");
      peer.addTrack(track, stream);

      const channel = peer.createDataChannel("oai-events");
      channelRef.current = channel;
      channel.onmessage = (message) => {
        try {
          handleRealtimeEvent(JSON.parse(String(message.data)) as RealtimeEvent);
        } catch {
          // Ignore malformed diagnostic events while keeping the conversation alive.
        }
      };
      channel.onopen = () => {
        setPhase("listening");
        channel.send(
          JSON.stringify({
            type: "response.create",
            response: {
              instructions: "Give your brief first-contact greeting now, then listen.",
            },
          }),
        );
      };

      const offer = await peer.createOffer();
      await peer.setLocalDescription(offer);
      if (!offer.sdp) throw new Error("The browser could not create a voice connection offer.");
      const response = await fetch("https://api.openai.com/v1/realtime/calls", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${secret.value}`,
          "Content-Type": "application/sdp",
        },
        body: offer.sdp,
      });
      if (!response.ok) throw new Error(`Voice connection failed (${response.status}): ${await response.text()}`);
      await peer.setRemoteDescription({ type: "answer", sdp: await response.text() });
    } catch (caught) {
      disconnect();
      setError(friendlyError(caught));
      setPhase("error");
    }
  }, [disconnect, handleRealtimeEvent]);

  const isConnected = phase !== "idle" && phase !== "error";

  return (
    <main className="orb-only">
      <div className="star-field" aria-hidden="true" />
      <section className="orb-stage">
        <button
          className={`rock-orb phase-${phase}`}
          onClick={() => void connect()}
          aria-label={isConnected ? "End conversation" : "Start conversation"}
          type="button"
        >
          <span className="facet facet-one" />
          <span className="facet facet-two" />
          <span className="facet facet-three" />
          <span className="orb-core">
            <span className="wave wave-a" />
            <span className="wave wave-b" />
            <span className="wave wave-c" />
            <span className="wave wave-d" />
            <span className="wave wave-e" />
          </span>
        </button>
        <h1>{phaseCopy[phase]}</h1>
        <p>{isConnected ? "Tap Rocky to say goodbye" : "Tap Rocky and start talking"}</p>
        <small>
          {!config
            ? "Checking ship systems…"
            : config.hasApiKey
              ? "AI voice companion · microphone active only while connected"
              : "API key missing from .env"}
        </small>
        {lastOpened ? <div className="file-signal">Spreadsheet opened: {lastOpened}</div> : null}
        {error ? <div className="error-card">{error}</div> : null}
      </section>
    </main>
  );
}
