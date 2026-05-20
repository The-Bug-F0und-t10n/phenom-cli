/**
 * Minimal wave visualizer for the status bar — a TS port of visualizer.py's
 * core noise + state logic, sized down for a single-row status prefix
 * (default 10 columns).
 *
 * Why a port and not the Python script: spawning + piping Python from a Node
 * CLI was the previous approach and produced a broken integration (process
 * lifecycle, stdout collision, syntax errors). This is inline, deterministic,
 * and zero-dependency.
 *
 * What's intentionally simpler than the full visualizer.py:
 *   - No cascade transitions between states (would need per-column snapshot
 *     buffers; expensive in time + memory for a 10-col display).
 *   - No FPS loop / sleep — the renderer is "pull-mode": cli-renderer calls
 *     render() whenever it paints the status line.
 *   - State change is instant, not eased.
 *
 * What's preserved:
 *   - The exact noise functions (n1, n2, rawNoise) and gamma-curve mapping.
 *   - The same state palette (idle / listening / thinking / working /
 *     responding) so visual feel matches the standalone visualizer.
 */

const BLOCKS = ' ▁▂▃▄▅▆▇█';
const NOISE_NORM = 0.8110;

interface VisualizerState {
  energy: number;
  density: number;
  chaos: number;
  spdFactor: number;
}

export type VisualizerMode =
  | 'idle'
  | 'listening'
  | 'thinking'
  | 'working'
  | 'responding';

const STATES: Record<VisualizerMode, VisualizerState> = {
  idle:       { energy: 0.00, density: 0.0, chaos: 0.00, spdFactor: 0.0 },
  listening:  { energy: 0.22, density: 1.6, chaos: 0.00, spdFactor: 10.0 },
  thinking:   { energy: 0.52, density: 2.6, chaos: 0.03, spdFactor: 8.0 },
  working:    { energy: 0.63, density: 3.0, chaos: 0.04, spdFactor: 9.0 },
  responding: { energy: 0.90, density: 4.2, chaos: 0.02, spdFactor: 7.0 }
};

function n1(x: number): number {
  return Math.sin(x * 0.35) * 0.60
       + Math.sin(x * 0.90) * 0.25
       + Math.sin(x * 1.70) * 0.15;
}

function n2(x: number): number {
  return Math.sin(x * 0.55) * 0.50
       + Math.sin(x * 1.30) * 0.35
       + Math.sin(x * 2.10) * 0.15;
}

function rawNoise(nx1: number, nx2: number): number {
  return Math.min(
    (Math.abs(n1(nx1)) * 0.65 + Math.abs(n2(nx2)) * 0.35) / NOISE_NORM,
    1.0
  );
}

export class MiniVisualizer {
  /**
   * Default 10 columns is the smallest reliable size — narrower than 6 makes
   * the wave look static (not enough columns to express phase); wider than 20
   * eats too much status-line real estate. 10 is a good balance.
   */
  private width: number;
  private mode: VisualizerMode = 'idle';
  private startTimeMs: number;

  constructor(width: number = 10) {
    this.width = Math.max(4, Math.floor(width));
    this.startTimeMs = Date.now();
  }

  setMode(mode: VisualizerMode): void {
    if (STATES[mode]) this.mode = mode;
  }

  getMode(): VisualizerMode {
    return this.mode;
  }

  setWidth(w: number): void {
    this.width = Math.max(4, Math.floor(w));
  }

  /**
   * Render the current frame as a width-char string of block glyphs. Idle
   * state returns all-spaces (so the visualizer "disappears" when nothing
   * is happening, freeing status-line width for prose).
   */
  render(): string {
    const tAnim = (Date.now() - this.startTimeMs) / 1000;
    const state = STATES[this.mode];
    if (state.energy < 1e-6) {
      return ' '.repeat(this.width);
    }

    const chars: string[] = [];
    for (let x = 0; x < this.width; x++) {
      const spd = 0.4 + state.energy * state.spdFactor;
      const nx1 = x * 0.07 * state.density + tAnim * spd;
      const nx2 = x * 0.12 * state.density + tAnim * spd * 1.2;

      const raw = rawNoise(nx1, nx2);
      const gamma = 0.25 + 4.5 * Math.pow(1.0 - state.energy, 2);
      const jitter = (Math.random() - 0.5) * state.chaos;
      const value = Math.max(0, Math.min(1, Math.pow(raw, gamma) + jitter));

      chars.push(BLOCKS[Math.floor(value * (BLOCKS.length - 1))]);
    }
    return chars.join('');
  }

  /**
   * Convenience: map an agent op-label string into a visualizer mode.
   * Used by cli-renderer to keep the visualizer in sync with what the agent
   * is doing without a separate state machine.
   */
  static modeFromOpLabel(label: string): VisualizerMode {
    const l = String(label || '').toLowerCase();
    if (!l) return 'idle';
    if (l.includes('thinking') || l.includes('think')) return 'thinking';
    if (l.includes('writing') || l.includes('patching') || l.includes('editing')) return 'working';
    if (l.includes('reading') || l.includes('searching') || l.includes('exploring')) return 'listening';
    if (l.includes('running') || l.includes('testing') || l.includes('validating')) return 'working';
    return 'responding';
  }
}
