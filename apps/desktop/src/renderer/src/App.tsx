import { useCallback, useEffect, useRef, useState } from "react";

import type { MemoryFactInput, SpreadsheetSpec } from "../../shared/types";
import {
  evaluateRockyStyle,
  ROCKY_DEFAULT_REPLY_CASE,
  ROCKY_GREETING_CASE,
} from "../../shared/rockyStyle";
import { START_GREETING_EVENT } from "../../shared/realtimeEvents";
import { EridianAudio } from "./eridianAudio";

type Phase = "idle" | "connecting" | "listening" | "thinking" | "speaking" | "error";

interface RealtimeEvent {
  type?: string;
  transcript?: string;
  delta?: string;
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

function friendlyError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function App(): React.JSX.Element {
  const [phase, setPhase] = useState<Phase>("idle");
  const peerRef = useRef<RTCPeerConnection | null>(null);
  const channelRef = useRef<RTCDataChannel | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const remoteAudioContextRef = useRef<AudioContext | null>(null);
  const remoteAudioFrameRef = useRef<number | null>(null);
  const remoteSpeakingRef = useRef(false);
  const eridianAudioRef = useRef<EridianAudio | null>(null);
  const sessionIdRef = useRef<string | null>(null);
  const rockyUtteranceCountRef = useRef(0);
  const userSpokeBeforeFirstRockyRef = useRef(false);

  useEffect(() => {
    return () => {
      channelRef.current?.close();
      peerRef.current?.close();
      streamRef.current?.getTracks().forEach((track) => track.stop());
      if (remoteAudioFrameRef.current !== null) cancelAnimationFrame(remoteAudioFrameRef.current);
      void remoteAudioContextRef.current?.close();
      void eridianAudioRef.current?.close();
    };
  }, []);

  const stopRemoteAudioMonitor = useCallback(() => {
    if (remoteAudioFrameRef.current !== null) cancelAnimationFrame(remoteAudioFrameRef.current);
    remoteAudioFrameRef.current = null;
    remoteSpeakingRef.current = false;
    void remoteAudioContextRef.current?.close();
    remoteAudioContextRef.current = null;
  }, []);

  const monitorRemoteAudio = useCallback((stream: MediaStream) => {
    stopRemoteAudioMonitor();
    const context = new AudioContext();
    const analyser = context.createAnalyser();
    const source = context.createMediaStreamSource(stream);
    let lastAudibleAt = 0;
    analyser.fftSize = 256;
    analyser.smoothingTimeConstant = 0.55;
    const samples = new Float32Array(analyser.fftSize);
    source.connect(analyser);
    remoteAudioContextRef.current = context;
    void context.resume();

    const sample = (): void => {
      analyser.getFloatTimeDomainData(samples);
      const rms = Math.sqrt(samples.reduce((sum, value) => sum + value * value, 0) / samples.length);
      const now = performance.now();
      if (rms > 0.012) {
        lastAudibleAt = now;
        if (!remoteSpeakingRef.current) {
          remoteSpeakingRef.current = true;
          setPhase("speaking");
        }
      } else if (remoteSpeakingRef.current && now - lastAudibleAt > 280) {
        remoteSpeakingRef.current = false;
        setPhase((current) => current === "speaking" ? "listening" : current);
      }
      remoteAudioFrameRef.current = requestAnimationFrame(sample);
    };
    sample();
  }, [stopRemoteAudioMonitor]);

  const sendEvent = useCallback((event: object) => {
    const channel = channelRef.current;
    if (!channel || channel.readyState !== "open") throw new Error("Rocky’s data channel is not open.");
    channel.send(JSON.stringify(event));
  }, []);

  const logTranscript = useCallback((role: "user" | "rocky" | "tool" | "system", text: string) => {
    const sessionId = sessionIdRef.current;
    if (!sessionId || !text.trim()) return;
    void window.rocky.appendTranscript({ sessionId, role, text }).catch(() => undefined);
  }, []);

  const handleSpreadsheetTool = useCallback(
    async (callId: string, argumentText: string) => {
      setPhase("thinking");
      try {
        const spec = JSON.parse(argumentText) as SpreadsheetSpec;
        const result = await window.rocky.createSpreadsheet(spec, sessionIdRef.current ?? undefined);
        sendEvent({
          type: "conversation.item.create",
          item: {
            type: "function_call_output",
            call_id: callId,
            output: JSON.stringify({
              success: true,
              filename: result.filename,
              path: result.path,
              message: "Workbook created and pulled onscreen in ONLYOFFICE Spreadsheet Editor.",
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

  const handleMemoryTool = useCallback(
    async (callId: string, argumentText: string) => {
      try {
        const input = JSON.parse(argumentText) as MemoryFactInput;
        const result = await window.rocky.rememberFamilyFact(input);
        logTranscript(
          "tool",
          `${result.saved ? "Remembered" : "Already remembered"} for ${result.person}: ${result.fact}`,
        );
        sendEvent({
          type: "conversation.item.create",
          item: {
            type: "function_call_output",
            call_id: callId,
            output: JSON.stringify({
              success: true,
              saved: result.saved,
              message: "Safe local memory updated. Respond naturally without explaining the memory system.",
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
    [logTranscript, sendEvent],
  );

  const handleRealtimeEvent = useCallback(
    (event: RealtimeEvent) => {
      switch (event.type) {
        case "input_audio_buffer.speech_started":
          eridianAudioRef.current?.stop();
          setPhase("listening");
          break;
        case "input_audio_buffer.speech_stopped":
        case "response.created":
          setPhase("thinking");
          break;
        case "conversation.item.input_audio_transcription.completed":
          if (event.transcript) {
            if (rockyUtteranceCountRef.current === 0) userSpokeBeforeFirstRockyRef.current = true;
            logTranscript("user", event.transcript);
          }
          break;
        case "response.output_audio_transcript.delta":
          if (event.delta) eridianAudioRef.current?.pushTranscriptDelta(event.delta);
          break;
        case "response.output_audio_transcript.done":
          if (event.transcript) {
            eridianAudioRef.current?.flushTranscript();
            logTranscript("rocky", event.transcript);
            const styleCase = rockyUtteranceCountRef.current === 0 && !userSpokeBeforeFirstRockyRef.current
              ? ROCKY_GREETING_CASE
              : ROCKY_DEFAULT_REPLY_CASE;
            const result = evaluateRockyStyle(styleCase, event.transcript);
            if (result.failures.length) {
              logTranscript("system", `${styleCase.name} failed: ${result.failures.join("; ")}`);
              void window.rocky.recordStyleFailure({
                caseName: styleCase.name,
                text: event.transcript,
                failures: result.failures,
              }).catch(() => undefined);
            }
            rockyUtteranceCountRef.current += 1;
          }
          break;
        case "response.done":
          for (const item of event.response?.output ?? []) {
            if (item.type === "function_call" && item.name === "create_spreadsheet" && item.call_id) {
              void handleSpreadsheetTool(item.call_id, item.arguments ?? "{}");
            }
            if (item.type === "function_call" && item.name === "remember_family_fact" && item.call_id) {
              void handleMemoryTool(item.call_id, item.arguments ?? "{}");
            }
          }
          break;
        case "error":
          setPhase("error");
          break;
      }
    },
    [handleMemoryTool, handleSpreadsheetTool, logTranscript],
  );

  const disconnect = useCallback(() => {
    logTranscript("system", "Conversation ended.");
    channelRef.current?.close();
    peerRef.current?.close();
    streamRef.current?.getTracks().forEach((track) => track.stop());
    channelRef.current = null;
    peerRef.current = null;
    streamRef.current = null;
    stopRemoteAudioMonitor();
    void eridianAudioRef.current?.close();
    eridianAudioRef.current = null;
    sessionIdRef.current = null;
    rockyUtteranceCountRef.current = 0;
    userSpokeBeforeFirstRockyRef.current = false;
    setPhase("idle");
  }, [logTranscript, stopRemoteAudioMonitor]);

  const connect = useCallback(async () => {
    if (peerRef.current) {
      disconnect();
      return;
    }

    setPhase("connecting");
    try {
      const config = await window.rocky.getConfig();
      if (config.alienVoiceEnabled) {
        eridianAudioRef.current ??= new EridianAudio(config.alienVoiceVolume);
        await eridianAudioRef.current.resume();
      }
      const transcriptSession = await window.rocky.startTranscript();
      sessionIdRef.current = transcriptSession.sessionId;
      const secret = await window.rocky.createRealtimeSession();
      const peer = new RTCPeerConnection();
      peerRef.current = peer;

      const audio = document.createElement("audio");
      audio.autoplay = true;
      peer.ontrack = (event) => {
        const remoteStream = event.streams[0];
        audio.srcObject = remoteStream ?? null;
        if (remoteStream) monitorRemoteAudio(remoteStream);
      };
      peer.onconnectionstatechange = () => {
        if (peer.connectionState === "failed" || peer.connectionState === "disconnected") {
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
        channel.send(JSON.stringify(START_GREETING_EVENT));
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
      logTranscript("system", `Connection failed: ${friendlyError(caught)}`);
      disconnect();
      setPhase("error");
    }
  }, [disconnect, handleRealtimeEvent, logTranscript, monitorRemoteAudio]);

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
      </section>
    </main>
  );
}
