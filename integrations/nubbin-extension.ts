// Nubbin reporter for pi and omp. Installed by `make hooks` from
// nubbin/integrations/nubbin-extension.ts; edit there, not here.
// Sends Claude-Code-shaped hook events to the Nubbin app over its Unix socket.
// @ts-nocheck

import net from "node:net";
import os from "node:os";
import path from "node:path";

const AGENT = "__AGENT__"; // "pi" or "omp", substituted at install time
const SOCKET = path.join(os.homedir(), "Library/Application Support/Nubbin/events.sock");
const FORWARDED_ENV = ["ZELLIJ_SESSION_NAME", "ZELLIJ_PANE_ID", "__CFBundleIdentifier", "TERM_PROGRAM"];

function sendNow(message: unknown): Promise<void> {
  const { promise, resolve } = Promise.withResolvers<void>();
  const socket = net.createConnection(SOCKET);
  const done = () => {
    socket.destroy();
    resolve();
  };
  socket.setTimeout(500, done);
  socket.on("error", done);
  socket.on("close", () => resolve());
  socket.on("connect", () => socket.end(JSON.stringify(message)));
  return promise;
}

// One connection per event, in order: a fast PreToolUse must not overtake its UserPromptSubmit.
let queue = Promise.resolve();

export default function (pi) {
  // OMP marks shells it spawns with OMPCODE=1; an agent started there isn't the pane's own session.
  if (process.env.OMPCODE === "1") return;

  let root = false;
  let sessionId: string | undefined;
  let cwd = process.cwd();
  let prompt: string | undefined;
  let active = false;
  let lastError: string | undefined;
  let lastCtx;
  let stopWatchingName: (() => void) | undefined;
  // Tool args by call id: approval events carry only the id, the args arrive earlier.
  const inputs = new Map<string, Record<string, unknown>>();

  const env = Object.fromEntries(FORWARDED_ENV.flatMap((key) => (process.env[key] ? [[key, process.env[key]]] : [])));

  function sessionInfo(): Record<string, unknown> {
    const info: Record<string, unknown> = {};
    try {
      const title = lastCtx?.sessionManager?.getSessionName?.();
      if (typeof title === "string" && title) info.session_title = title;
    } catch {}
    try {
      const model = lastCtx?.model;
      const name = model?.name || model?.id;
      if (typeof name === "string" && name) info.model = name;
    } catch {}
    return info;
  }

  function send(event: string, fields: Record<string, unknown> = {}, id = sessionId) {
    if (!id) return;
    const payload = { hook_event_name: event, session_id: id, cwd, ...sessionInfo(), ...fields };
    const message = { agent: AGENT, env, payload };
    queue = queue.then(() => sendNow(message));
  }

  function track(ctx): boolean {
    if (!root) return false;
    lastCtx = ctx ?? lastCtx;
    if (typeof ctx?.cwd === "string") cwd = ctx.cwd;
    return true;
  }

  // omp auto-titles a session after its first turn and on /rename; keep the row title current.
  function watchName(ctx) {
    stopWatchingName?.();
    try {
      stopWatchingName = ctx?.sessionManager?.onSessionNameChanged?.(() => send("SessionInfo"));
    } catch {
      stopWatchingName = undefined;
    }
  }

  function errorOf(messages): string | undefined {
    const last = Array.isArray(messages) ? [...messages].reverse().find((m) => m?.role === "assistant") : undefined;
    return last?.stopReason === "error" ? String(last.errorMessage || "Request failed") : undefined;
  }

  function finish(error: string | undefined) {
    active = false;
    if (error) send("StopFailure", { error });
    else send("Stop");
  }

  // Tools that put a question to the user: omp's built-in `ask` and the rpiv ask_user_question plugin.
  const ASK_TOOLS: Record<string, true> = { ask: true, ask_user_question: true };

  function questionsOf(args) {
    const list = Array.isArray(args?.questions) ? args.questions : [];
    return list.map((q) => ({
      question: String(q?.question ?? ""),
      header: typeof q?.header === "string" ? q.header : undefined,
      multiSelect: q?.multiSelect === true || q?.multi === true,
      recommended: typeof q?.recommended === "number" ? q.recommended : undefined,
      options: (Array.isArray(q?.options) ? q.options : []).map((o) => (typeof o === "string" ? o : String(o?.label ?? ""))),
    }));
  }

  // Mirrors omp's own activity feed: the model's stated intent, else the tool's main argument.
  function activityOf(event): string {
    const args = event?.args ?? {};
    const intent = event?.intent ?? args.i ?? args.intent;
    if (typeof intent === "string" && intent.trim()) return intent.trim();
    const main = ["command", "path", "pattern", "query", "name", "task", "title"].map((k) => args[k]).find((v) => typeof v === "string" && v);
    return main ? `${event.toolName}: ${main}` : String(event?.toolName ?? "tool");
  }

  pi.on("session_start", (_event, ctx) => {
    // Interactive sessions only: print/json/rpc modes and in-process subagents have no pane to return to.
    if (ctx?.mode !== "tui" || ctx?.hasUI === false) return;
    root = true;
    track(ctx);
    let id: string | undefined;
    try {
      id = ctx.sessionManager?.getSessionId?.();
    } catch {}
    if (sessionId && id !== sessionId) send("SessionEnd"); // /new, /resume, /fork in pi
    sessionId = id;
    active = ctx?.isIdle?.() === false;
    watchName(ctx);
    send("SessionStart");
  });

  // omp reports switches separately; pi re-runs session_start.
  pi.on("session_switch", (_event, ctx) => {
    if (!track(ctx)) return;
    const id = ctx.sessionManager?.getSessionId?.();
    if (id && id !== sessionId) {
      send("SessionEnd");
      sessionId = id;
      active = false;
      watchName(ctx);
      send("SessionStart");
    }
  });

  pi.on("before_agent_start", (event, ctx) => {
    if (!track(ctx)) return;
    prompt = typeof event?.prompt === "string" ? event.prompt : undefined;
  });

  pi.on("agent_start", (_event, ctx) => {
    if (!track(ctx) || active) return; // omp re-emits agent_start for automatic continuations
    active = true;
    lastError = undefined;
    send("UserPromptSubmit", { prompt });
  });

  pi.on("tool_call", (event, ctx) => {
    if (!track(ctx) || !event?.toolCallId) return;
    if (event.input && typeof event.input === "object") inputs.set(event.toolCallId, event.input);
  });

  // omp only: approval prompts. The terminal dialog stays the place to answer; we show what it asks.
  pi.on("tool_approval_requested", (event, ctx) => {
    if (!track(ctx)) return;
    const input = { ...(inputs.get(event?.toolCallId) ?? {}) };
    if (event?.reason && !input.description) input.description = event.reason;
    send("PermissionRequest", { tool_name: event?.toolName || "Tool", tool_input: input });
  });

  pi.on("tool_approval_resolved", (event, ctx) => {
    if (!track(ctx)) return;
    send("PostToolUse", { tool_name: event?.toolName });
  });

  pi.on("tool_execution_start", (event, ctx) => {
    if (!track(ctx)) return;
    if (event?.toolCallId && event.args && typeof event.args === "object" && !inputs.has(event.toolCallId)) {
      inputs.set(event.toolCallId, event.args);
    }
    if (ASK_TOOLS[event?.toolName]) {
      send("PreToolUse", { tool_name: "AskUserQuestion", tool_input: { questions: questionsOf(event.args) } });
    } else {
      send("ToolStart", { tool_name: event?.toolName, activity: activityOf(event) });
    }
  });

  pi.on("tool_execution_end", (event, ctx) => {
    if (event?.toolCallId) inputs.delete(event.toolCallId);
    if (!ASK_TOOLS[event?.toolName] || !track(ctx)) return;
    send("PostToolUse", { tool_name: "AskUserQuestion" });
  });

  pi.on("agent_end", (event, ctx) => {
    if (!track(ctx) || !active) return;
    if (AGENT === "pi") {
      // pi's agent_end can be followed by retries/compaction; agent_settled is the real end.
      lastError = errorOf(event?.messages);
      return;
    }
    if (event?.willContinue === true) return;
    finish(errorOf(event?.messages));
  });

  pi.on("agent_settled", (_event, ctx) => {
    if (!track(ctx) || !active) return;
    finish(lastError);
  });

  pi.on("session_shutdown", () => {
    if (root) send("SessionEnd");
  });
}
