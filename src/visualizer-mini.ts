/**
 * Minimal wave visualizer for the status bar — a TS port of visualizer.py's
 * noise + state machine + cascade transition logic.
 *
 * What's preserved from visualizer.py:
 *   - Exact noise functions (n1, n2, rawNoise) and gamma-curve mapping.
 *   - Full state palette (idle / listening / thinking / working /
 *     responding).
 *   - Cascade transition: when setMode() is called, each column snapshots
 *     its current effective state and blends toward the new target with a
 *     per-column delay (left→right sweep) and cubic ease-in-out. This makes
 *     state changes feel like a wave rolling across the visualizer instead
 *     of an abrupt cut.
 *
 * What's intentionally simpler:
 *   - No FPS loop / sleep — pull-mode render(); cli-renderer calls it on
 *     every paint tick (33 ms = 30 FPS).
 *   - idle has low but non-zero energy so the wave keeps "breathing" — this
 *     matches the user's request to always have a visible animation at the
 *     right edge of the status bar.
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

/**
 * Mode personalities. Each mode gets a visually distinct signature so the
 * agent's emotional state reads at a glance:
 *   - idle:       essentially silent — a thin static baseline, no motion.
 *   - listening:  fast micro-ripples (low energy, high speed) — alert.
 *   - thinking:   deep slow swells (mid energy, low speed) — contemplative.
 *   - working:    busy chunky waves (high energy + density + chaos) — active.
 *   - responding: full smooth flow (max energy, zero chaos) — confident.
 */
const STATES: Record<VisualizerMode, VisualizerState> = {
  // Idle energy is essentially zero — the render path short-circuits
  // below FLAT_THRESHOLD to a static baseline glyph with no time-based
  // computation, so the visualizer reads as "present but silent" without
  // any waves or frame-to-frame variation.
  idle:       { energy: 0.02, density: 1.0, chaos: 0.00, spdFactor: 0.0  },
  listening:  { energy: 0.32, density: 2.2, chaos: 0.00, spdFactor: 12.0 },
  thinking:   { energy: 0.58, density: 3.0, chaos: 0.04, spdFactor: 5.5  },
  working:    { energy: 0.72, density: 4.0, chaos: 0.08, spdFactor: 11.0 },
  responding: { energy: 0.95, density: 4.8, chaos: 0.01, spdFactor: 8.5  }
};

/**
 * Below this effective energy, a column is drawn as a static `▁` baseline
 * with no time-based noise calculation. Picked so the settled-idle state
 * (energy 0.02) falls below it, but mid-cascade columns transitioning to/
 * from active modes still render the wave.
 */
const FLAT_THRESHOLD = 0.05;
const FLAT_GLYPH = '▁';

/**
 * Seconds for the cascade wave to sweep the entire visualizer width when a
 * state changes. With CASCADE=1.0 and a 20-col wave, the right-most column
 * starts its transition 1.0s after the left-most.
 */
const CASCADE_SEC = 1.0;
/**
 * Seconds each individual column takes to complete its transition (blend
 * from old snapshot to new target via smootherstep). Longer EASE_SEC gives
 * the wave more time to melt between emotional states — the change reads
 * as a gradient instead of a step.
 */
const EASE_SEC = 0.85;

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

/**
 * Smootherstep (Ken Perlin) — `6t^5 − 15t^4 + 10t^3`. Both the first and
 * second derivatives are zero at t=0 and t=1, so the transition starts and
 * ends with no perceptible acceleration kick. Cubic ease-in-out (the prior
 * choice) is C1 but not C2, which produced a faint snap at the endpoints
 * that read as the wave "popping" between modes instead of melting.
 */
function easeSmooth(p: number): number {
  const t = Math.max(0, Math.min(1, p));
  return t * t * t * (t * (t * 6 - 15) + 10);
}

function lerpState(a: VisualizerState, b: VisualizerState, t: number): VisualizerState {
  return {
    energy:    a.energy    * (1 - t) + b.energy    * t,
    density:   a.density   * (1 - t) + b.density   * t,
    chaos:     a.chaos     * (1 - t) + b.chaos     * t,
    spdFactor: a.spdFactor * (1 - t) + b.spdFactor * t
  };
}

export class MiniVisualizer {
  private width: number;
  /** The "display" mode — what setMode() was last called with. */
  private mode: VisualizerMode = 'idle';
  /** Target state being transitioned TO. */
  private targetState: VisualizerState = STATES.idle;
  /**
   * Per-column snapshot of the effective state at the moment of the LAST
   * transition. Each column blends from snap[i] toward targetState across
   * EASE_SEC, with start delay = (i / (width-1)) * CASCADE_SEC.
   */
  private snap: VisualizerState[] = [];
  private transitionStartMs: number;
  private startTimeMs: number;

  constructor(width: number = 20) {
    this.width = Math.max(4, Math.floor(width));
    this.startTimeMs = Date.now();
    // Pretend the initial "transition into idle" finished long ago so the
    // first paint already shows the target (no startup flicker).
    this.transitionStartMs = this.startTimeMs - (CASCADE_SEC + EASE_SEC) * 1000;
    this.snap = new Array(this.width).fill(0).map(() => ({ ...STATES.idle }));
  }

  /**
   * Trigger a transition to a new mode. Snapshots the current effective
   * per-column state so the blend toward the new target reads as a wave
   * rolling across the visualizer (matches the cascade behaviour in the
   * standalone visualizer.py).
   */
  setMode(mode: VisualizerMode): void {
    if (!STATES[mode] || mode === this.mode) return;
    // Freeze each column's current effective state so the blend toward the
    // new target starts from "wherever we actually are right now", not from
    // the old target. This is what gives the transition a continuous feel
    // even when you change mode mid-transition.
    for (let i = 0; i < this.width; i++) {
      this.snap[i] = this.effectiveStateFor(i);
    }
    this.mode = mode;
    this.targetState = STATES[mode];
    this.transitionStartMs = Date.now();
  }

  getMode(): VisualizerMode {
    return this.mode;
  }

  setWidth(w: number): void {
    const next = Math.max(4, Math.floor(w));
    if (next === this.width) return;
    if (next > this.width) {
      // Growing: new columns enter already at the current target, so they
      // don't flash a stale state on resize.
      const seed: VisualizerState = { ...this.targetState };
      for (let i = this.width; i < next; i++) this.snap.push({ ...seed });
    } else {
      this.snap.length = next;
    }
    this.width = next;
  }

  /**
   * Compute the effective state of column `i` at the current moment —
   * blending snap[i] toward targetState with a per-column delay so that the
   * transition reads as a left→right cascade wave.
   */
  private effectiveStateFor(i: number): VisualizerState {
    const denom = Math.max(this.width - 1, 1);
    const delay = (i / denom) * CASCADE_SEC;
    const elapsed = (Date.now() - this.transitionStartMs) / 1000;
    const blend = easeSmooth((elapsed - delay) / EASE_SEC);
    return lerpState(this.snap[i] || STATES.idle, this.targetState, blend);
  }

  /**
   * Render the current frame as a width-char string of block glyphs.
   * Columns whose effective energy is essentially zero render as spaces
   * (no wave). With idle.energy > 0, the wave is always at least breathing.
   */
  render(): string {
    const tAnim = (Date.now() - this.startTimeMs) / 1000;
    const chars: string[] = [];

    for (let x = 0; x < this.width; x++) {
      const state = this.effectiveStateFor(x);

      // Below the flat threshold (settled idle): emit a static baseline
      // glyph with NO time-based math. This is the "minimum possible,
      // no waves" idle look — the visualizer is visible but otherwise
      // inert, so keystrokes triggering single repaints don't cause any
      // perceptible shift.
      if (state.energy < FLAT_THRESHOLD) {
        chars.push(state.energy < 1e-6 ? ' ' : FLAT_GLYPH);
        continue;
      }

      const spd = 0.4 + state.energy * state.spdFactor;
      const nx1 = x * 0.07 * state.density + tAnim * spd;
      const nx2 = x * 0.12 * state.density + tAnim * spd * 1.2;

      const raw = rawNoise(nx1, nx2);
      const gamma = 0.25 + 4.5 * Math.pow(1.0 - state.energy, 2);
      // Continuous jitter: per-column sine flutter instead of Math.random().
      // The previous random jitter changed every frame at 30 FPS, which
      // showed as digital flicker. Two beating sines give the same chaos
      // budget but evolve smoothly between frames, so the perceived
      // animation is fluid instead of buzzy. State.chaos still controls
      // amplitude — chaos=0 means perfectly clean wave (idle/responding).
      const jitter = state.chaos === 0
        ? 0
        : (Math.sin(tAnim * 7.3 + x * 1.7) +
           Math.sin(tAnim * 4.1 + x * 2.9)) * 0.25 * state.chaos;
      const value = Math.max(0, Math.min(1, Math.pow(raw, gamma) + jitter));

      chars.push(BLOCKS[Math.floor(value * (BLOCKS.length - 1))]);
    }
    return chars.join('');
  }

  /**
   * Map an agent op-label string into a visualizer mode (called from
   * THINK_START / PROGRESS_UPDATE handlers).
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

  /**
   * Map a tool name into a visualizer mode. Called from the TOOL_START
   * handler so the wave responds to what the agent is *actually doing*
   * (writing vs reading vs running) instead of stuck on the generic
   * "thinking" derived from the agent's progress messages.
   */
  static modeFromToolName(toolName: string): VisualizerMode {
    const n = String(toolName || '').toLowerCase();
    if (!n) return 'thinking';
    if (n === 'write_file' || n === 'create_file' || n === 'apply_patch' ||
        n === 'patch_file' || n === 'delete_file' || n === 'delete_dir' ||
        n === 'run_code' || n === 'run_tests' || n === 'validate_syntax' ||
        n === 'set_plan' || n === 'complete_step' || n === 'update_memory' ||
        n === 'record_skill' || n === 'set_news_preferences') {
      return 'working';
    }
    if (n === 'read_file' || n === 'grep_file' || n === 'find_function' ||
        n === 'path_exists' || n === 'list_dir' || n === 'list_session_files' ||
        n === 'list_pending_tasks' ||
        n === 'glob' || n === 'extract_block' || n === 'search_code' ||
        n === 'web_search' || n === 'get_civic_briefing' || n === 'get_news_preferences' ||
        n.startsWith('git_')) {
      return 'listening';
    }
    return 'working';
  }
}
