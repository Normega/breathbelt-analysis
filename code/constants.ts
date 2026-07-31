// ---------------------------------------------------------------------------
// Visual
// ---------------------------------------------------------------------------
export const MAX_BASE_RADIUS = 400
export const MIN_BASE_RADIUS = 190

// ---------------------------------------------------------------------------
// Timing
// ---------------------------------------------------------------------------
export const DEFAULT_BASE_PERIOD_S   = 4        // seconds/cycle if user skips natural-breath step
export const CALIB_CYCLES            = 4        // breath cycles during calibration
export const NATURAL_BREATH_MIN_MS   = 10_000   // minimum natural-breath recording window
export const NATURAL_BREATH_MAX_MS   = 20_000   // auto-advance after this
export const READY_DELAY_MS          = 600      // pre-animation pause

// ---------------------------------------------------------------------------
// Phase 1 (fixed-level practice)
// ---------------------------------------------------------------------------
export const PHASE1_DELTA_RATIO        = 0.25   // 25 % change — comfortably above threshold
export const PHASE1_TRIALS_PER_COND   = 3       // 3×SAME + 3×FASTER + 3×SLOWER = 9 trials
export const TRIAL_BASE_BREATHS        = 2       // breaths 1–2 at base rate
export const TRIAL_CHANGE_BREATHS      = 2       // breaths 3–4 at changed rate

// ---------------------------------------------------------------------------
// QUEST staircase
// ---------------------------------------------------------------------------
// Priors derived from empirical dataset (n=197, High-salience, session 1 firstBreath + session 2)
// delta_ratio = delta_t_s / base_period_s;  new_cycle = base × (1 ± delta_ratio)
export const QUEST_FASTER_PRIOR_MEAN  = -1.0106  // log10(ratio), ≈ 9.8 % threshold
export const QUEST_FASTER_PRIOR_SD   =  0.1314
export const QUEST_SLOWER_PRIOR_MEAN  = -0.9439  // log10(ratio), ≈ 11.4 % threshold
export const QUEST_SLOWER_PRIOR_SD   =  0.2690

export const QUEST_BETA              = 3.5       // Weibull slope
export const QUEST_LAPSE             = 0.02      // lapse rate
export const QUEST_GUESS             = 1 / 3     // 3AFC chance level
export const QUEST_MIN_TRIALS_EACH   = 6         // minimum per staircase before early-stop check
export const QUEST_SD_STOP           = 0.10      // posterior SD (log units) — stop if both below this
export const QUEST_MAX_TRIALS_EACH   = 25        // hard cap per staircase

// Sync quality thresholds (Pearson r of belt-model vs pacer)
export const SYNC_GOOD   = 0.70
export const SYNC_FAIR   = 0.40