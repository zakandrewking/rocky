import { useCallback, useEffect, useRef, useState, type SetStateAction } from "react";

import type {
  BackgroundResearchInput,
  BackgroundResearchResult,
  BackgroundResearchStatus,
  DebugLogEntry,
  HowToDocSpec,
  MemoryFactInput,
  OnlyOfficeBridgeStatus,
  RockyFileListInput,
  RockyFileOpenInput,
  SpreadsheetEditSpec,
  SpreadsheetInspectSpec,
  SpreadsheetSpec,
} from "../../shared/types";
import {
  evaluateRockyStyle,
  ROCKY_DEFAULT_REPLY_CASE,
  ROCKY_GREETING_CASE,
} from "../../shared/rockyStyle";
import { RESPONSE_CANCEL_EVENT, RESPONSE_CREATE_EVENT } from "../../shared/realtimeEvents";
import { splitSpeechChunks } from "../../shared/speechChunks";
import { EridianAudio } from "./eridianAudio";
import { HumePcmAudio } from "./humePcmAudio";

type Phase = "idle" | "connecting" | "listening" | "thinking" | "speaking" | "error";

interface DebugSnapshot {
  phase: Phase;
  session: string;
  peer: string;
  channel: string;
  response: string;
  pending: string;
  output: string;
  greeting: string;
  last: string;
}

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

interface ResearchDebugItem {
  id: string;
  status: "started" | "complete" | "error";
  question?: string;
  message: string;
  at: string;
}

function friendlyError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function App(): React.JSX.Element {
  const [phase, setPhase] = useState<Phase>("idle");
  const [debugSnapshot, setDebugSnapshot] = useState<DebugSnapshot>({
    phase: "idle",
    session: "none",
    peer: "none",
    channel: "none",
    response: "no",
    pending: "no",
    output: "no",
    greeting: "no",
    last: "boot",
  });
  const [debugOpen, setDebugOpen] = useState(false);
  const [researchDebug, setResearchDebug] = useState<ResearchDebugItem[]>([]);
  const [onlyOfficeStatus, setOnlyOfficeStatus] = useState<OnlyOfficeBridgeStatus | null>(null);
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
  const userSpeechActiveRef = useRef(false);
  const initialGreetingDoneRef = useRef(false);
  const rockyOutputActiveRef = useRef(false);
  const ignoreSpeechStartedUntilRef = useRef(0);
  const rockyUtteranceCountRef = useRef(0);
  const userSpokeBeforeFirstRockyRef = useRef(false);
  const phaseRef = useRef<Phase>("idle");

  const buildDebugSnapshot = useCallback((last: string): DebugSnapshot => ({
    phase: phaseRef.current,
    session: sessionIdRef.current ? sessionIdRef.current.slice(-8) : "none",
    peer: peerRef.current?.connectionState ?? "none",
    channel: channelRef.current?.readyState ?? "none",
    response: responseInProgressRef.current ? "yes" : "no",
    pending: userTurnPendingRef.current ? "yes" : "no",
    output: rockyOutputActiveRef.current ? "yes" : "no",
    greeting: initialGreetingDoneRef.current ? "yes" : "no",
    last,
  }), []);

  const writeDebugLog = useCallback((event: string, detail: Record<string, unknown> = {}) => {
    const snapshot = buildDebugSnapshot(event);
    setDebugSnapshot(snapshot);
    const entry: DebugLogEntry = {
      event,
      phase: snapshot.phase,
      detail: { ...snapshot, ...detail },
    };
    if (sessionIdRef.current) entry.sessionId = sessionIdRef.current;
    void window.rocky.appendDebugLog(entry).catch(() => undefined);
  }, [buildDebugSnapshot]);

  const refreshDebug = useCallback((last: string) => {
    setDebugSnapshot(buildDebugSnapshot(last));
  }, [buildDebugSnapshot]);

  const setRockyPhase = useCallback((next: SetStateAction<Phase>, reason: string) => {
    const current = phaseRef.current;
    const resolved = typeof next === "function" ? next(current) : next;
    phaseRef.current = resolved;
    setPhase(resolved);
    writeDebugLog(`phase:${reason}`);
  }, [writeDebugLog]);

  const pushResearchDebug = useCallback((item: Omit<ResearchDebugItem, "at">) => {
    setResearchDebug((current) => [
      { ...item, at: new Date().toLocaleTimeString() },
      ...current,
    ].slice(0, 8));
  }, []);

  const loadPersistedResearchDebug = useCallback(async () => {
    try {
      const statuses: BackgroundResearchStatus[] = await window.rocky.listBackgroundResearch();
      setResearchDebug((current) => {
        const existing = new Set(current.map((item) => item.id));
        const persisted = statuses
          .filter((status) => !existing.has(status.id))
          .map((status): ResearchDebugItem => ({
            id: status.id,
            status: status.status,
            ...(status.question ? { question: status.question } : {}),
            message: status.message ?? status.path ?? status.status,
            at: new Date(status.updatedAt).toLocaleTimeString(),
          }));
        return [...current, ...persisted].slice(0, 12);
      });
    } catch {
      // Debug detail loading must never affect the voice loop.
    }
  }, []);

  const loadOnlyOfficeStatus = useCallback(async () => {
    try {
      setOnlyOfficeStatus(await window.rocky.getOnlyOfficeStatus());
    } catch {
      setOnlyOfficeStatus(null);
    }
  }, []);

  const toggleDebugOpen = useCallback(() => {
    setDebugOpen((open) => {
      if (!open) {
        void loadPersistedResearchDebug();
        void loadOnlyOfficeStatus();
      }
      return !open;
    });
  }, [loadOnlyOfficeStatus, loadPersistedResearchDebug]);

  useEffect(() => {
    return () => {
      writeDebugLog("renderer:unmount");
      channelRef.current?.close();
      peerRef.current?.close();
      streamRef.current?.getTracks().forEach((track) => track.stop());
      if (remoteAudioFrameRef.current !== null) cancelAnimationFrame(remoteAudioFrameRef.current);
      void remoteAudioContextRef.current?.close();
      void eridianAudioRef.current?.close();
      void humeAudioRef.current?.close();
    };
  }, [writeDebugLog]);

  useEffect(() => {
    const timer = window.setInterval(() => refreshDebug("tick"), 1_000);
    return () => window.clearInterval(timer);
  }, [refreshDebug]);

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
          setRockyPhase("speaking", "remote-audio-start");
        }
      } else if (remoteSpeakingRef.current && now - lastAudibleAt > 280) {
        remoteSpeakingRef.current = false;
        rockyOutputActiveRef.current = false;
        setRockyPhase((current) => current === "speaking" ? "listening" : current, "remote-audio-stop");
      }
      remoteAudioFrameRef.current = requestAnimationFrame(sample);
    };
    sample();
  }, [setRockyPhase, stopRemoteAudioMonitor]);

  const sendEvent = useCallback((event: object) => {
    const channel = channelRef.current;
    if (!channel || channel.readyState !== "open") throw new Error("Rocky’s data channel is not open.");
    writeDebugLog("send-event", { eventType: "type" in event ? event.type : "unknown" });
    channel.send(JSON.stringify(event));
  }, [writeDebugLog]);

  const requestResponse = useCallback((reason: "initial_greeting" | "user_turn" | "tool_result") => {
    if (responseInProgressRef.current) return false;
    if (reason !== "initial_greeting" && !initialGreetingDoneRef.current) {
      writeDebugLog("request-response-blocked", { reason, why: "initial greeting not done" });
      return false;
    }
    responseInProgressRef.current = true;
    setRockyPhase("thinking", `request-response-${reason}`);
    try {
      sendEvent(RESPONSE_CREATE_EVENT);
      return true;
    } catch {
      responseInProgressRef.current = false;
      throw new Error("Rocky could not start a response.");
    }
  }, [sendEvent, setRockyPhase, writeDebugLog]);

  const answerPendingUserTurn = useCallback(() => {
    if (!userTurnPendingRef.current) return;
    if (userSpeechActiveRef.current) return;
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

  const speakLocalInitialGreeting = useCallback(() => {
    const text = "Can hear. Rocky here. First target, question?";
    initialGreetingDoneRef.current = true;
    humeTextBufferRef.current = "";
    humeResponseTextRef.current = text;
    humeAudioRef.current?.beginResponse();
    rockyOutputActiveRef.current = true;
    setRockyPhase("speaking", "local-initial-greeting");
    eridianAudioRef.current?.pushTranscriptDelta(text);
    eridianAudioRef.current?.flushTranscript();
    sendHumeChunks(text, true);
    recordRockyUtterance(text);
    humeResponseTextRef.current = "";
  }, [recordRockyUtterance, sendHumeChunks, setRockyPhase]);

  const startInitialGreeting = useCallback(() => {
    if (speechProviderRef.current === "hume") {
      speakLocalInitialGreeting();
      return;
    }
    requestResponse("initial_greeting");
  }, [requestResponse, speakLocalInitialGreeting]);

  const stopRockyOutput = useCallback((reason: string) => {
    const hadResponse = responseInProgressRef.current;
    const hadOutput = rockyOutputActiveRef.current;
    eridianAudioRef.current?.stop();
    humeAudioRef.current?.stop();
    humeTextBufferRef.current = "";
    humeResponseTextRef.current = "";
    rockyOutputActiveRef.current = false;
    if (sessionIdRef.current && speechProviderRef.current === "hume") {
      void window.rocky.cancelHumeSpeech(sessionIdRef.current).catch(() => undefined);
    }
    if (hadResponse && channelRef.current?.readyState === "open") {
      try {
        sendEvent(RESPONSE_CANCEL_EVENT);
      } catch {
        // If the channel closed while handling a barge-in, normal disconnect cleanup will reset state.
      }
    }
    responseInProgressRef.current = false;
    writeDebugLog("rocky-output-stopped", { reason, hadResponse, hadOutput });
  }, [sendEvent, writeDebugLog]);

  const handleSpreadsheetTool = useCallback(
    async (callId: string, argumentText: string) => {
      setRockyPhase("thinking", "spreadsheet-tool");
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
    [requestResponse, sendEvent, setRockyPhase],
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
      setRockyPhase("thinking", "active-spreadsheet-tool");
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
    [requestResponse, sendEvent, setRockyPhase],
  );

  const handleEditSpreadsheetTool = useCallback(
    async (callId: string, argumentText: string) => {
      setRockyPhase("thinking", "edit-spreadsheet-tool");
      try {
        const spec = JSON.parse(argumentText) as SpreadsheetEditSpec;
        const result = await window.rocky.editCurrentSpreadsheet(spec, sessionIdRef.current ?? undefined);
        sendEvent({
          type: "conversation.item.create",
          item: {
            type: "function_call_output",
            call_id: callId,
            output: JSON.stringify({
              success: true,
              filename: result.filename,
              path: result.path,
              message: "Current workbook edited and visible sheet refreshed.",
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
    [requestResponse, sendEvent, setRockyPhase],
  );

  const handleInspectSpreadsheetTool = useCallback(
    async (callId: string, argumentText: string) => {
      setRockyPhase("thinking", "inspect-spreadsheet-tool");
      try {
        const spec = JSON.parse(argumentText) as SpreadsheetInspectSpec;
        const result = await window.rocky.inspectCurrentSpreadsheet(spec, sessionIdRef.current ?? undefined);
        sendEvent({
          type: "conversation.item.create",
          item: {
            type: "function_call_output",
            call_id: callId,
            output: JSON.stringify({
              success: true,
              filename: result.filename,
              sheets: result.sheets,
              inspected: result.inspected,
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
    [requestResponse, sendEvent, setRockyPhase],
  );

  const handleHowToDocTool = useCallback(
    async (callId: string, argumentText: string) => {
      setRockyPhase("thinking", "how-to-doc-tool");
      try {
        const spec = JSON.parse(argumentText) as HowToDocSpec;
        const result = await window.rocky.createHowToDoc(spec, sessionIdRef.current ?? undefined);
        sendEvent({
          type: "conversation.item.create",
          item: {
            type: "function_call_output",
            call_id: callId,
            output: JSON.stringify({
              success: true,
              filename: result.filename,
              path: result.path,
              message: "How-to DOCX created and opened in the local document app.",
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
    [requestResponse, sendEvent, setRockyPhase],
  );

  const handleBackgroundResearchTool = useCallback(
    async (callId: string, argumentText: string) => {
      try {
        const input = JSON.parse(argumentText) as BackgroundResearchInput;
        const result = await window.rocky.startBackgroundResearch(input, sessionIdRef.current ?? undefined);
        pushResearchDebug({
          id: result.id,
          status: "started",
          question: result.question,
          message: result.message,
        });
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
        pushResearchDebug({
          id: "request",
          status: "error",
          message: friendlyError(caught),
        });
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
    [pushResearchDebug, requestResponse, sendEvent],
  );

  const handleListRockyFilesTool = useCallback(
    async (callId: string, argumentText: string) => {
      setRockyPhase("thinking", "list-files-tool");
      try {
        const input = JSON.parse(argumentText || "{}") as RockyFileListInput;
        const files = await window.rocky.listRockyFiles(input, sessionIdRef.current ?? undefined);
        sendEvent({
          type: "conversation.item.create",
          item: {
            type: "function_call_output",
            call_id: callId,
            output: JSON.stringify({ success: true, files }),
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
    [requestResponse, sendEvent, setRockyPhase],
  );

  const handleOpenRockyFileTool = useCallback(
    async (callId: string, argumentText: string) => {
      setRockyPhase("thinking", "open-file-tool");
      try {
        const input = JSON.parse(argumentText || "{}") as RockyFileOpenInput;
        const file = await window.rocky.openRockyFile(input, sessionIdRef.current ?? undefined);
        sendEvent({
          type: "conversation.item.create",
          item: {
            type: "function_call_output",
            call_id: callId,
            output: JSON.stringify({
              success: true,
              file,
              message: "Saved Rocky file opened in ONLYOFFICE.",
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
    [requestResponse, sendEvent, setRockyPhase],
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
      writeDebugLog("realtime-event", {
        type: event.type ?? "unknown",
        outputItems: event.response?.output?.length ?? 0,
      });
      switch (event.type) {
        case "input_audio_buffer.speech_started": {
          const ignoreWindow = performance.now() < ignoreSpeechStartedUntilRef.current;
          const isLikelySelfAudio = ignoreWindow && !userTurnPendingRef.current;
          if (isLikelySelfAudio) {
            writeDebugLog("speech-started-ignored", {
              responseInProgress: responseInProgressRef.current,
              rockyOutputActive: rockyOutputActiveRef.current,
              ignoreWindow,
            });
            break;
          }
          userSpeechActiveRef.current = true;
          userTurnPendingRef.current = true;
          if (responseInProgressRef.current || rockyOutputActiveRef.current) {
            stopRockyOutput("user-barge-in");
          }
          setRockyPhase("listening", "speech-started");
          break;
        }
        case "input_audio_buffer.speech_stopped":
          if (userTurnPendingRef.current) {
            if (rockyOutputActiveRef.current) stopRockyOutput("pending-turn-after-speech-stopped");
            userSpeechActiveRef.current = false;
            setRockyPhase("thinking", "speech-stopped");
            answerPendingUserTurn();
          } else {
            userSpeechActiveRef.current = false;
          }
          break;
        case "response.created":
          responseInProgressRef.current = true;
          setRockyPhase("thinking", "response-created");
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
          writeDebugLog("response-done", {
            toolCalls: toolCalls.map((item) => item.name ?? "unknown"),
            outputItems: event.response?.output?.length ?? 0,
          });
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
            if (item.type === "function_call" && item.name === "inspect_current_spreadsheet" && item.call_id) {
              void handleInspectSpreadsheetTool(item.call_id, item.arguments ?? "{}");
            }
            if (item.type === "function_call" && item.name === "edit_current_spreadsheet" && item.call_id) {
              void handleEditSpreadsheetTool(item.call_id, item.arguments ?? "{}");
            }
            if (item.type === "function_call" && item.name === "create_how_to_doc" && item.call_id) {
              void handleHowToDocTool(item.call_id, item.arguments ?? "{}");
            }
            if (item.type === "function_call" && item.name === "list_rocky_files" && item.call_id) {
              void handleListRockyFilesTool(item.call_id, item.arguments ?? "{}");
            }
            if (item.type === "function_call" && item.name === "open_rocky_file" && item.call_id) {
              void handleOpenRockyFileTool(item.call_id, item.arguments ?? "{}");
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
          setRockyPhase("error", "realtime-error");
          break;
      }
    },
    [
      answerPendingUserTurn,
      handleActiveSpreadsheetTool,
      handleBackgroundResearchTool,
      handleEditSpreadsheetTool,
      handleHowToDocTool,
      handleInspectSpreadsheetTool,
      handleListRockyFilesTool,
      handleMemoryTool,
      handleOpenRockyFileTool,
      handleSpreadsheetTool,
      logTranscript,
      recordRockyUtterance,
      sendHumeChunks,
      setRockyPhase,
      stopRockyOutput,
      writeDebugLog,
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
    userSpeechActiveRef.current = false;
    initialGreetingDoneRef.current = false;
    rockyOutputActiveRef.current = false;
    ignoreSpeechStartedUntilRef.current = 0;
    rockyUtteranceCountRef.current = 0;
    userSpokeBeforeFirstRockyRef.current = false;
    setRockyPhase("idle", "disconnect");
  }, [logTranscript, setRockyPhase, stopRemoteAudioMonitor]);

  useEffect(() => window.rocky.onResearchComplete((sessionId, result) => {
    if (sessionId && sessionId !== sessionIdRef.current) return;
    pushResearchDebug({
      id: result.id,
      status: "complete",
      question: result.question,
      message: result.answer.slice(0, 240),
    });
    logTranscript("tool", `Background research ready: ${result.question}`);
    injectResearchResult(result);
  }), [injectResearchResult, logTranscript, pushResearchDebug]);

  useEffect(() => window.rocky.onResearchError((sessionId, result) => {
    if (sessionId && sessionId !== sessionIdRef.current) return;
    pushResearchDebug({
      id: result.id,
      status: "error",
      message: result.message,
    });
    logTranscript("system", `Background research failed: ${result.message}`);
  }), [logTranscript, pushResearchDebug]);

  const connect = useCallback(async () => {
    if (peerRef.current) {
      disconnect();
      return;
    }

    setRockyPhase("connecting", "connect");
    try {
      const config = await window.rocky.getConfig();
      speechProviderRef.current = config.speechProvider;
      writeDebugLog("connect:config", {
        speechProvider: config.speechProvider,
        alienVoiceEnabled: config.alienVoiceEnabled,
        hasApiKey: config.hasApiKey,
      });
      if (config.speechProvider === "hume") {
        humeAudioRef.current ??= new HumePcmAudio((speaking) => {
          rockyOutputActiveRef.current = speaking;
          setRockyPhase(speaking ? "speaking" : responseInProgressRef.current ? "thinking" : "listening", "hume-speaking");
          if (!speaking && !userSpeechActiveRef.current) answerPendingUserTurn();
        }, config.humeExtraDelayMs);
        await humeAudioRef.current.resume();
      }
      if (config.alienVoiceEnabled) {
        eridianAudioRef.current ??= new EridianAudio(config.alienVoiceVolume, config.alienVoiceTimeScale);
        await eridianAudioRef.current.resume();
      }
      const transcriptSession = await window.rocky.startTranscript();
      sessionIdRef.current = transcriptSession.sessionId;
      writeDebugLog("connect:transcript-started", { transcriptSession: transcriptSession.sessionId });
      const secret = await window.rocky.createRealtimeSession();
      writeDebugLog("connect:realtime-secret-created", { expiresAt: secret.expires_at ?? null });
      const peer = new RTCPeerConnection();
      peerRef.current = peer;

      const audio = document.createElement("audio");
      audio.autoplay = true;
      peer.ontrack = (event) => {
        const remoteStream = event.streams[0];
        writeDebugLog("peer:ontrack", { hasStream: Boolean(remoteStream) });
        audio.srcObject = remoteStream ?? null;
        if (remoteStream) monitorRemoteAudio(remoteStream);
      };
      peer.onconnectionstatechange = () => {
        writeDebugLog("peer:connection-state", { state: peer.connectionState });
        if (peer.connectionState === "failed" || peer.connectionState === "disconnected") {
          disconnect();
        }
      };

      writeDebugLog("mic:request");
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
      writeDebugLog("mic:ready", { trackState: track.readyState, trackLabel: track.label });
      peer.addTrack(track, stream);

      const channel = peer.createDataChannel("oai-events");
      channelRef.current = channel;
      channel.onclose = () => writeDebugLog("data-channel:close");
      channel.onerror = () => writeDebugLog("data-channel:error");
      channel.onmessage = (message) => {
        try {
          handleRealtimeEvent(JSON.parse(String(message.data)) as RealtimeEvent);
        } catch {
          writeDebugLog("data-channel:malformed-message");
          // Ignore malformed diagnostic events while keeping the conversation alive.
        }
      };
      channel.onopen = () => {
        writeDebugLog("data-channel:open");
        ignoreSpeechStartedUntilRef.current = performance.now() + 1_500;
        startInitialGreeting();
      };

      const offer = await peer.createOffer();
      await peer.setLocalDescription(offer);
      if (!offer.sdp) throw new Error("The browser could not create a voice connection offer.");
      writeDebugLog("peer:local-description-set");
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
      writeDebugLog("peer:remote-description-set");
    } catch (caught) {
      writeDebugLog("connect:error", { error: friendlyError(caught) });
      logTranscript("system", `Connection failed: ${friendlyError(caught)}`);
      disconnect();
      setRockyPhase("error", "connect-error");
    }
  }, [
    answerPendingUserTurn,
    disconnect,
    handleRealtimeEvent,
    logTranscript,
    monitorRemoteAudio,
    setRockyPhase,
    startInitialGreeting,
    writeDebugLog,
  ]);

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
        <aside
          className={`debug-state ${debugOpen ? "debug-state-open" : ""}`}
          aria-label="Rocky state"
          onClick={toggleDebugOpen}
          onKeyDown={(event) => {
            if (event.key === "Enter" || event.key === " ") {
              event.preventDefault();
              toggleDebugOpen();
            }
          }}
          role="button"
          tabIndex={0}
        >
          <span>{debugSnapshot.phase}</span>
          <small>
            p:{debugSnapshot.peer} c:{debugSnapshot.channel} r:{debugSnapshot.response} u:{debugSnapshot.pending} o:{debugSnapshot.output}
          </small>
          <small>{debugSnapshot.last}</small>
          {debugOpen ? (
            <div className="debug-details">
              <strong>onlyoffice</strong>
              {onlyOfficeStatus ? (
                <p>
                  {onlyOfficeStatus.connected ? "connected" : "not connected"} · q:{onlyOfficeStatus.queued} p:{onlyOfficeStatus.pending}
                  {onlyOfficeStatus.msSinceLastPoll === null ? "" : ` · ${Math.round(onlyOfficeStatus.msSinceLastPoll)}ms`}
                </p>
              ) : <p>status unavailable</p>}
              <strong>background research</strong>
              {researchDebug.length ? researchDebug.map((item) => (
                <div className={`research-debug research-${item.status}`} key={`${item.id}-${item.at}`}>
                  <b>{item.status}</b>
                  <em>{item.at} · {item.id.slice(0, 8)}</em>
                  {item.question ? <span>{item.question}</span> : null}
                  <p>{item.message}</p>
                </div>
              )) : <p>No research agents yet.</p>}
            </div>
          ) : null}
        </aside>
      </section>
    </main>
  );
}
