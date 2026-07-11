import { useCallback, useEffect, useRef, useState } from "react";

import type { BackgroundResearchInput, BackgroundResearchResult, MemoryFactInput, SpreadsheetSpec } from "../../shared/types";
import {
  evaluateRockyStyle,
  ROCKY_DEFAULT_REPLY_CASE,
  ROCKY_GREETING_CASE,
} from "../../shared/rockyStyle";
import { RESPONSE_CREATE_EVENT } from "../../shared/realtimeEvents";
import { splitSpeechChunks } from "../../shared/speechChunks";
import { EridianAudio } from "./eridianAudio";
import { HumePcmAudio } from "./humePcmAudio";

type Phase = "idle" | "connecting" | "listening" | "thinking" | "speaking" | "error";

interface RealtimeEvent {
  type?: string;
  transcript?: string;
  text?: string;
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
  const humeAudioRef = useRef<HumePcmAudio | null>(null);
  const speechProviderRef = useRef<"openai" | "hume">("openai");
  const humeTextBufferRef = useRef("");
  const humeResponseTextRef = useRef("");
  const sessionIdRef = useRef<string | null>(null);
  const responseInProgressRef = useRef(false);
  const userTurnPendingRef = useRef(false);
  const initialGreetingDoneRef = useRef(false);
  const rockyOutputActiveRef = useRef(false);
  const ignoreSpeechStartedUntilRef = useRef(0);
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
      void humeAudioRef.current?.close();
    };
  }, []);

  useEffect(() => window.rocky.onHumeAudio((sessionId, event) => {
    if (sessionId !== sessionIdRef.current) return;
    if (event.type === "audio") {
      humeAudioRef.current?.push(event.audio, event.sampleRate);
    } else {
      void window.rocky.appendTranscript({
        sessionId,
        role: "system",
        text: `Hume speech error: ${event.message}`,
      }).catch(() => undefined);
    }
  }), []);

  const stopRemoteAudioMonitor = useCallback(() => {
    if (remoteAudioFrameRef.current !== null) cancelAnimationFrame(remoteAudioFrameRef.current);
    remoteAudioFrameRef.current = null;
    remoteSpeakingRef.current = false;
    rockyOutputActiveRef.current = false;
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
          rockyOutputActiveRef.current = true;
          setPhase("speaking");
        }
      } else if (remoteSpeakingRef.current && now - lastAudibleAt > 280) {
        remoteSpeakingRef.current = false;
        rockyOutputActiveRef.current = false;
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

  const requestResponse = useCallback((reason: "initial_greeting" | "user_turn" | "tool_result") => {
    if (responseInProgressRef.current) return false;
    if (reason !== "initial_greeting" && !initialGreetingDoneRef.current) return false;
    responseInProgressRef.current = true;
    setPhase("thinking");
    try {
      sendEvent(RESPONSE_CREATE_EVENT);
      return true;
    } catch {
      responseInProgressRef.current = false;
      throw new Error("Rocky could not start a response.");
    }
  }, [sendEvent]);

  const answerPendingUserTurn = useCallback(() => {
    if (!userTurnPendingRef.current) return;
    if (rockyOutputActiveRef.current) return;
    if (requestResponse("user_turn")) userTurnPendingRef.current = false;
  }, [requestResponse]);

  const logTranscript = useCallback((role: "user" | "rocky" | "tool" | "system", text: string) => {
    const sessionId = sessionIdRef.current;
    if (!sessionId || !text.trim()) return;
    void window.rocky.appendTranscript({ sessionId, role, text }).catch(() => undefined);
  }, []);

  const recordRockyUtterance = useCallback((text: string) => {
    if (!text.trim()) return;
    logTranscript("rocky", text);
    const styleCase = rockyUtteranceCountRef.current === 0 && !userSpokeBeforeFirstRockyRef.current
      ? ROCKY_GREETING_CASE
      : ROCKY_DEFAULT_REPLY_CASE;
    const result = evaluateRockyStyle(styleCase, text);
    if (result.failures.length) {
      logTranscript("system", `${styleCase.name} failed: ${result.failures.join("; ")}`);
      void window.rocky.recordStyleFailure({
        caseName: styleCase.name,
        text,
        failures: result.failures,
      }).catch(() => undefined);
    }
    rockyUtteranceCountRef.current += 1;
  }, [logTranscript]);

  const sendHumeChunks = useCallback((delta: string, flush = false) => {
    const sessionId = sessionIdRef.current;
    if (!sessionId || speechProviderRef.current !== "hume") return;
    const split = splitSpeechChunks(humeTextBufferRef.current, delta, flush);
    humeTextBufferRef.current = split.remainder;
    for (const chunk of split.complete) {
      void window.rocky.speakWithHume(sessionId, chunk, flush && !split.remainder).catch((error) => {
        logTranscript("system", `Hume speech request failed: ${friendlyError(error)}`);
      });
    }
  }, [logTranscript]);

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
      requestResponse("tool_result");
    },
    [requestResponse, sendEvent],
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
      requestResponse("tool_result");
    },
    [logTranscript, requestResponse, sendEvent],
  );

  const handleActiveSpreadsheetTool = useCallback(
    async (callId: string, argumentText: string) => {
      setPhase("thinking");
      try {
        const spec = JSON.parse(argumentText) as SpreadsheetSpec;
        await window.rocky.updateActiveSpreadsheet(spec, sessionIdRef.current ?? undefined);
        sendEvent({
          type: "conversation.item.create",
          item: {
            type: "function_call_output",
            call_id: callId,
            output: JSON.stringify({ success: true, message: "Visible active spreadsheet updated in place." }),
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
      requestResponse("tool_result");
    },
    [requestResponse, sendEvent],
  );

  const handleBackgroundResearchTool = useCallback(
    async (callId: string, argumentText: string) => {
      try {
        const input = JSON.parse(argumentText) as BackgroundResearchInput;
        const result = await window.rocky.startBackgroundResearch(input, sessionIdRef.current ?? undefined);
        sendEvent({
          type: "conversation.item.create",
          item: {
            type: "function_call_output",
            call_id: callId,
            output: JSON.stringify({
              success: true,
              id: result.id,
              message: "Background research started. A short result will return later.",
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
      requestResponse("tool_result");
    },
    [requestResponse, sendEvent],
  );

  const injectResearchResult = useCallback((result: BackgroundResearchResult) => {
    if (!channelRef.current || channelRef.current.readyState !== "open") return;
    sendEvent({
      type: "conversation.item.create",
      item: {
        type: "message",
        role: "user",
        content: [{
          type: "input_text",
          text: `Background research result ready. Question: ${result.question}\n\nResult: ${result.answer}`,
        }],
      },
    });
    requestResponse("tool_result");
  }, [requestResponse, sendEvent]);

  const handleRealtimeEvent = useCallback(
    (event: RealtimeEvent) => {
      switch (event.type) {
        case "input_audio_buffer.speech_started": {
          const isLikelySelfAudio = responseInProgressRef.current
            || rockyOutputActiveRef.current
            || performance.now() < ignoreSpeechStartedUntilRef.current;
          if (isLikelySelfAudio) break;
          eridianAudioRef.current?.stop();
          humeAudioRef.current?.stop();
          humeTextBufferRef.current = "";
          humeResponseTextRef.current = "";
          if (sessionIdRef.current && speechProviderRef.current === "hume") {
            void window.rocky.cancelHumeSpeech(sessionIdRef.current).catch(() => undefined);
          }
          userTurnPendingRef.current = true;
          setPhase("listening");
          break;
        }
        case "input_audio_buffer.speech_stopped":
          if (userTurnPendingRef.current) {
            setPhase("thinking");
            answerPendingUserTurn();
          }
          break;
        case "response.created":
          responseInProgressRef.current = true;
          setPhase("thinking");
          break;
        case "conversation.item.input_audio_transcription.completed":
          if (event.transcript) {
            if (rockyUtteranceCountRef.current === 0) userSpokeBeforeFirstRockyRef.current = true;
            logTranscript("user", event.transcript);
            if (!responseInProgressRef.current || !initialGreetingDoneRef.current) {
              userTurnPendingRef.current = true;
              answerPendingUserTurn();
            }
          }
          break;
        case "response.output_audio_transcript.delta":
          if (event.delta) eridianAudioRef.current?.pushTranscriptDelta(event.delta);
          break;
        case "response.output_audio_transcript.done":
          if (event.transcript) {
            eridianAudioRef.current?.flushTranscript();
            recordRockyUtterance(event.transcript);
          }
          break;
        case "response.output_text.delta":
          if (event.delta) {
            if (!humeResponseTextRef.current) humeAudioRef.current?.beginResponse();
            rockyOutputActiveRef.current = true;
            humeResponseTextRef.current += event.delta;
            eridianAudioRef.current?.pushTranscriptDelta(event.delta);
            sendHumeChunks(event.delta);
          }
          break;
        case "response.output_text.done": {
          sendHumeChunks("", true);
          eridianAudioRef.current?.flushTranscript();
          const text = event.text ?? humeResponseTextRef.current;
          humeResponseTextRef.current = "";
          recordRockyUtterance(text);
          break;
        }
        case "response.done": {
          responseInProgressRef.current = false;
          if (!initialGreetingDoneRef.current && rockyUtteranceCountRef.current > 0) {
            initialGreetingDoneRef.current = true;
          }
          const toolCalls = event.response?.output?.filter((item) => item.type === "function_call") ?? [];
          for (const item of event.response?.output ?? []) {
            if (item.type === "function_call" && item.name === "create_spreadsheet" && item.call_id) {
              void handleSpreadsheetTool(item.call_id, item.arguments ?? "{}");
            }
            if (item.type === "function_call" && item.name === "remember_family_fact" && item.call_id) {
              void handleMemoryTool(item.call_id, item.arguments ?? "{}");
            }
            if (item.type === "function_call" && item.name === "update_active_spreadsheet" && item.call_id) {
              void handleActiveSpreadsheetTool(item.call_id, item.arguments ?? "{}");
            }
            if (item.type === "function_call" && item.name === "start_background_research" && item.call_id) {
              void handleBackgroundResearchTool(item.call_id, item.arguments ?? "{}");
            }
          }
          if (!toolCalls.length) answerPendingUserTurn();
          break;
        }
        case "error":
          responseInProgressRef.current = false;
          setPhase("error");
          break;
      }
    },
    [
      answerPendingUserTurn,
      handleActiveSpreadsheetTool,
      handleBackgroundResearchTool,
      handleMemoryTool,
      handleSpreadsheetTool,
      logTranscript,
      recordRockyUtterance,
      sendHumeChunks,
    ],
  );

  const disconnect = useCallback(() => {
    logTranscript("system", "Conversation ended.");
    const sessionId = sessionIdRef.current;
    if (sessionId && speechProviderRef.current === "hume") {
      void window.rocky.cancelHumeSpeech(sessionId).catch(() => undefined);
    }
    channelRef.current?.close();
    peerRef.current?.close();
    streamRef.current?.getTracks().forEach((track) => track.stop());
    channelRef.current = null;
    peerRef.current = null;
    streamRef.current = null;
    stopRemoteAudioMonitor();
    void eridianAudioRef.current?.close();
    eridianAudioRef.current = null;
    void humeAudioRef.current?.close();
    humeAudioRef.current = null;
    humeTextBufferRef.current = "";
    humeResponseTextRef.current = "";
    sessionIdRef.current = null;
    responseInProgressRef.current = false;
    userTurnPendingRef.current = false;
    initialGreetingDoneRef.current = false;
    rockyOutputActiveRef.current = false;
    ignoreSpeechStartedUntilRef.current = 0;
    rockyUtteranceCountRef.current = 0;
    userSpokeBeforeFirstRockyRef.current = false;
    setPhase("idle");
  }, [logTranscript, stopRemoteAudioMonitor]);

  useEffect(() => window.rocky.onResearchComplete((sessionId, result) => {
    if (sessionId && sessionId !== sessionIdRef.current) return;
    logTranscript("tool", `Background research ready: ${result.question}`);
    injectResearchResult(result);
  }), [injectResearchResult, logTranscript]);

  useEffect(() => window.rocky.onResearchError((sessionId, result) => {
    if (sessionId && sessionId !== sessionIdRef.current) return;
    logTranscript("system", `Background research failed: ${result.message}`);
  }), [logTranscript]);

  const connect = useCallback(async () => {
    if (peerRef.current) {
      disconnect();
      return;
    }

    setPhase("connecting");
    try {
      const config = await window.rocky.getConfig();
      speechProviderRef.current = config.speechProvider;
      if (config.speechProvider === "hume") {
        humeAudioRef.current ??= new HumePcmAudio((speaking) => {
          rockyOutputActiveRef.current = speaking;
          setPhase(speaking ? "speaking" : responseInProgressRef.current ? "thinking" : "listening");
          if (!speaking) answerPendingUserTurn();
        }, config.humeExtraDelayMs);
        await humeAudioRef.current.resume();
      }
      if (config.alienVoiceEnabled) {
        eridianAudioRef.current ??= new EridianAudio(config.alienVoiceVolume, config.alienVoiceTimeScale);
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
        ignoreSpeechStartedUntilRef.current = performance.now() + 1_500;
        requestResponse("initial_greeting");
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
  }, [answerPendingUserTurn, disconnect, handleRealtimeEvent, logTranscript, monitorRemoteAudio, requestResponse]);

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
