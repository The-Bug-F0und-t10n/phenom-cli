import { spawn, ChildProcess } from 'child_process';
import { promises as fs } from 'fs';
import path from 'path';
import os from 'os';

/**
 * Speaks text via the remote Piper HTTP service. Single concern: take text,
 * produce audible output on the local machine. Errors are non-fatal — the
 * agent flow must NOT block on TTS misbehaviour.
 *
 * Lifecycle: one player process at a time. If a new speak request arrives
 * while the previous is playing, the previous is killed and the new one
 * starts. This mirrors how a human conversation works — the latest
 * utterance is what matters.
 */
export interface TtsPlayerOptions {
  /** Full URL to the Piper HTTP `/speak` endpoint. */
  endpoint: string;
  /** Player binary. Defaults to a probe across paplay/aplay/ffplay. */
  player?: string;
  /** Max ms to wait for the synth HTTP request. */
  requestTimeoutMs?: number;
}

export class TtsPlayer {
  private endpoint: string;
  private player: string | null;
  private requestTimeoutMs: number;
  private current: ChildProcess | null = null;
  private tmpFiles: Set<string> = new Set();
  private detectedPlayer: string | null = null;

  constructor(opts: TtsPlayerOptions) {
    this.endpoint = opts.endpoint;
    this.player = opts.player || null;
    this.requestTimeoutMs = opts.requestTimeoutMs ?? 60_000;
  }

  /**
   * Request synthesis + play. Returns a promise that resolves once playback
   * has STARTED (not finished) — so the caller's flow isn't blocked on
   * audible duration. Rejection is reserved for unrecoverable wiring
   * errors; transient (network, codec) failures resolve and log silently.
   */
  async speak(text: string): Promise<void> {
    const trimmed = text.trim();
    if (!trimmed) return;

    const player = await this.resolvePlayer();
    if (!player) {
      // No audio backend on this host — nothing to do, NOT an error.
      return;
    }

    const wav = await this.synth(trimmed);
    if (!wav || wav.length < 64) return;

    // Stop any prior playback BEFORE writing the new file so the previous
    // tmp can be cleaned up without racing on its file handle.
    this.stop();

    const tmp = path.join(
      os.tmpdir(),
      `phenom-tts-${Date.now()}-${Math.random().toString(36).slice(2, 8)}.wav`
    );
    await fs.writeFile(tmp, wav);
    this.tmpFiles.add(tmp);

    this.current = spawn(player, [tmp], { stdio: 'ignore', detached: false });
    this.current.on('exit', () => {
      // Clean the tmp once playback ends. Errors here are non-fatal.
      this.tmpFiles.delete(tmp);
      fs.unlink(tmp).catch(() => {});
      this.current = null;
    });
    this.current.on('error', () => {
      this.tmpFiles.delete(tmp);
      fs.unlink(tmp).catch(() => {});
      this.current = null;
    });
  }

  /**
   * Stop any ongoing playback immediately. Safe to call when nothing is
   * playing. Used by the CLI when the user cancels or starts typing a new
   * prompt — interrupting the agent should also interrupt its voice.
   */
  stop(): void {
    if (this.current && !this.current.killed) {
      try { this.current.kill('SIGTERM'); } catch { /* swallow */ }
    }
    this.current = null;
  }

  /** Best-effort cleanup of stray tmp files (called on process shutdown). */
  async cleanup(): Promise<void> {
    this.stop();
    const files = Array.from(this.tmpFiles);
    this.tmpFiles.clear();
    await Promise.all(files.map(f => fs.unlink(f).catch(() => {})));
  }

  // ── internals ────────────────────────────────────────────────────────

  private async synth(text: string): Promise<Buffer | null> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.requestTimeoutMs);
    try {
      const res = await fetch(this.endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text }),
        signal: controller.signal
      });
      if (!res.ok) return null;
      const buf = Buffer.from(await res.arrayBuffer());
      return buf.length > 0 ? buf : null;
    } catch {
      // Network failure, abort, server down — silent. TTS is best-effort.
      return null;
    } finally {
      clearTimeout(timer);
    }
  }

  private async resolvePlayer(): Promise<string | null> {
    if (this.player) return this.player;
    if (this.detectedPlayer) return this.detectedPlayer;

    // Probe in order of preference. PulseAudio/PipeWire (paplay) is the
    // modern default; ALSA (aplay) is the universal Linux fallback; ffplay
    // works almost anywhere with ffmpeg; afplay covers macOS. First hit
    // wins and is cached for the lifetime of the process.
    const candidates = ['paplay', 'aplay', 'ffplay', 'afplay'];
    for (const cmd of candidates) {
      if (await this.commandExists(cmd)) {
        this.detectedPlayer = cmd;
        return cmd;
      }
    }
    return null;
  }

  private commandExists(cmd: string): Promise<boolean> {
    return new Promise(resolve => {
      const probe = spawn('which', [cmd], { stdio: 'ignore' });
      probe.on('exit', code => resolve(code === 0));
      probe.on('error', () => resolve(false));
    });
  }
}
