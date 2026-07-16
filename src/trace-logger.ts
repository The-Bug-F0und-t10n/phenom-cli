// Runtime trace logger — appends one JSON record per event to a file in cwd
// so the user can see what the agent did when it "hangs" or loops infinitely.
//
// Format: JSONL (one JSON object per line). Each record carries:
//   { ts: ISO time, dt: ms-since-session-start, type, payload }
//
// Reading the log:
//   tail -f .phenom-trace.log
//   grep TOOL_ .phenom-trace.log | jq .
//
// Diagnosis recipes:
//   - "model hangs after a tool":   look for the last TOOL_START with no
//     matching TOOL_RESULT/TOOL_ERROR — that's the call that didn't return.
//   - "model loops":                grep TOOL_START and look for the same
//     (tool, args) firing repeatedly — the loop-guard in the agent should
//     have caught this, but the log makes the symptom explicit.
//   - "model stuck on inference":   gap between THINK_START and THINK_END
//     greater than the request timeout is the model not streaming a token.
//
// Disable by setting PHENOM_TRACE=0. Default is ON — the file is cheap, and
// when something goes wrong having the log already is far more useful than
// realising you should have enabled it.

import fs from 'fs';
import path from 'path';
import { eventBus, EventType } from './tui/event-bus.js';

const MAX_FIELD_CHARS = 2000;
const MAX_TOTAL_CHARS = 6000;
const LOG_FILENAME = '.phenom-trace.log';

// Streaming chunks would dominate the log and aren't useful for diagnosis —
// the start/end markers and the final response already tell the story.
const ALWAYS_SKIPPED: ReadonlySet<EventType> = new Set([
  EventType.MESSAGE_CHUNK,
  EventType.REASONING_CHUNK,
  EventType.THINKING_MESSAGE,
  EventType.DELIBERATION_UPDATE,
  EventType.AGENT_NARRATION,
]);

export class TraceLogger {
  private stream: fs.WriteStream | null = null;
  private unsubs: Array<() => void> = [];
  private logPath: string;
  private startedAt: number = 0;
  private lastWriteOk: boolean = true;
  private includeTokenUpdate: boolean = false;

  constructor(cwd: string = process.cwd()) {
    this.logPath = path.join(cwd, LOG_FILENAME);
  }

  get path(): string { return this.logPath; }

  start(): void {
    if (this.stream) return;
    if (process.env.PHENOM_TRACE === '0' || process.env.PHENOM_TRACE === 'false') return;
    this.includeTokenUpdate = this.envEnabled(process.env.PHENOM_TRACE_TOKENS);

    try {
      this.stream = fs.createWriteStream(this.logPath, { flags: 'a' });
    } catch {
      // Filesystem failure (read-only cwd, permission). Skip silently — the
      // tracer is a diagnostic, never block startup.
      this.stream = null;
      return;
    }
    this.stream.on('error', () => { this.lastWriteOk = false; });
    this.startedAt = Date.now();

    this.writeRaw({
      type: 'SESSION_START',
      pid: process.pid,
      cwd: process.cwd(),
      node: process.version,
      argv: process.argv.slice(2)
    });

    // Subscribe to every EventType except the noisy streaming ones.
    for (const t of Object.values(EventType)) {
      if (this.shouldSkipEvent(t as EventType)) continue;
      const off = eventBus.on(t as EventType, (ev) => this.onEvent(ev));
      this.unsubs.push(off);
    }
  }

  stop(): void {
    for (const u of this.unsubs) u();
    this.unsubs = [];
    if (this.stream) {
      this.writeRaw({ type: 'SESSION_END' });
      try { this.stream.end(); } catch {}
      this.stream = null;
    }
  }

  private onEvent(ev: { type: string; payload: any; timestamp: number }): void {
    const payload = this.sanitize(this.preprocessPayload(ev.type, ev.payload));
    this.writeRaw({
      type: ev.type,
      payload,
    }, ev.timestamp);
  }

  private shouldSkipEvent(type: EventType): boolean {
    if (ALWAYS_SKIPPED.has(type)) return true;
    if (type === EventType.TOKEN_UPDATE && !this.includeTokenUpdate) return true;
    return false;
  }

  private preprocessPayload(type: string, payload: any): unknown {
    if (type !== EventType.TOKEN_UPDATE) return payload;
    const p = (payload && typeof payload === 'object') ? payload as Record<string, unknown> : {};
    const tokensPerSecond = Number(p.tokensPerSecond);
    return {
      input: numberOrNull(p.input),
      output: numberOrNull(p.output),
      total: numberOrNull(p.total),
      exact: Boolean(p.exact),
      cached: numberOrNull(p.cached),
      tokensPerSecond: Number.isFinite(tokensPerSecond) ? Math.round(tokensPerSecond * 100) / 100 : null,
    };
  }

  private writeRaw(rec: Record<string, unknown>, when: number = Date.now()): void {
    if (!this.stream || !this.lastWriteOk) return;
    const dt = this.startedAt ? when - this.startedAt : 0;
    const line = JSON.stringify({ ts: new Date(when).toISOString(), dt, ...rec });
    try {
      this.stream.write(line + '\n');
    } catch {
      this.lastWriteOk = false;
    }
  }

  private sanitize(value: unknown, depth: number = 0): unknown {
    if (value == null) return value;
    if (typeof value === 'string') return this.truncate(value);
    if (typeof value === 'number' || typeof value === 'boolean') return value;
    if (depth >= 4) return '[depth-limit]';
    if (Array.isArray(value)) {
      // Cap array length so a giant message list doesn't explode the line.
      const out = value.slice(0, 20).map(v => this.sanitize(v, depth + 1));
      if (value.length > 20) out.push(`…[+${value.length - 20} more]`);
      return out;
    }
    if (typeof value === 'object') {
      const out: Record<string, unknown> = {};
      let total = 0;
      for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
        const sv = this.sanitize(v, depth + 1);
        out[k] = sv;
        total += JSON.stringify(sv).length;
        if (total > MAX_TOTAL_CHARS) { out['__truncated'] = true; break; }
      }
      return out;
    }
    return String(value);
  }

  private truncate(s: string): string {
    if (s.length <= MAX_FIELD_CHARS) return s;
    return s.slice(0, MAX_FIELD_CHARS) + `…[+${s.length - MAX_FIELD_CHARS} chars]`;
  }

  private envEnabled(raw: string | undefined): boolean {
    const v = String(raw || '').trim().toLowerCase();
    return v === '1' || v === 'true' || v === 'yes';
  }
}

function numberOrNull(value: unknown): number | null {
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}
