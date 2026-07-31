# Project Context — Controlled Breathing Study App
_Last updated: 2026-03-11_

## Overview

A psychophysics experiment measuring perceptual thresholds for detecting changes in breathing rate. Participants breathe in sync with a pacing circle while wearing a **Polar H10** chest belt. The app uses Bayesian adaptive staircases (QUEST) to estimate detection thresholds for faster and slower rate changes.

**Stack:** React + TypeScript + Vite/esbuild  
**Hardware:** Polar H10 via Web Bluetooth API; lab trigger hardware via Web Serial API  
**Data storage:** File System Access API (local CSV); Firebase auth (with demo-mode bypass)  
**Repo structure:** `./webapp/src/` contains `App.tsx`, `components.tsx`; shared files `functions.ts` and `constants.ts` live two levels up (`../../`)

---

## File Map

```
functions.ts      — All logic: BLE, signal processing, calibration, QUEST, file I/O
constants.ts      — Single source of truth for all numeric parameters
webapp/src/
  App.tsx         — All state, refs, and event handlers; renders via renderUI() switch
  components.tsx  — Pure display components (no business logic)
  assets/
    full_logo-2.png
    arrows.png         (loading spinner)
    snail.svg          (SLOWER response icon)
    equals.svg         (SAME response icon)
    runner.svg         (FASTER response icon)
    arousal_1–6.svg    (6-point arousal scale icons)
    confidence_1–6.svg (6-point confidence scale icons)
```

---

## App State Machine

```
AUTH
  → WAIT_FOR_BLUETOOTH → CONNECTING_BT
  → WAIT_FOR_COM       → CONNECTING_COM
  → SETUP_FILES
  → CALIB_READY → CALIB_FIXATION → CALIB_BREATHE → CALIB_FITTING → CALIB_REVIEW
  → NATURAL_BREATHING → NATURAL_BREATH_RESULT
  → PHASE1_READY → PHASE1_TRIAL_RUNNING → (loop) → PHASE1_REVIEW
  → QUEST_READY → QUEST_TRIAL_RUNNING → QUEST_RATING → (loop) → QUEST_COMPLETE
  → END | ERROR
```

---

## Experimental Pipeline

### Calibration
- Participant breathes through **4 cycles** (`CALIB_CYCLES`) with pacing circle
- Belt accel packets collected in `calibSamplesRef`; **collection starts exactly when the pacing circle appears** (critical — collecting during instructions introduces timing errors)
- 6 belt model variants evaluated by Pearson R² against pacer signal; best selected automatically

| Model label      | Bandpass    | Post-smooth LP |
|------------------|-------------|----------------|
| `mlr-wide`       | 0.1–1.0 Hz  | No             |
| `mlr-tight`      | 0.1–0.4 Hz  | No             |
| `mlr-wide-lp`    | 0.1–1.0 Hz  | 0.6 Hz         |
| `mlr-tight-lp`   | 0.1–0.4 Hz  | 0.6 Hz         |
| `pca-wide`       | 0.1–1.0 Hz  | No (PCA axes)  |
| `pca-tight`      | 0.1–0.4 Hz  | No (PCA axes)  |

Calibration quality shown in `CalibReviewPanel`: Pearson R, lag (ms), and median peak timing error. Participant/experimenter can redo. Fit R < 0.4 blocks continuation.

Sync thresholds: Good ≥ 0.70, Fair ≥ 0.40 (constants `SYNC_GOOD`, `SYNC_FAIR`).

### Natural Breathing
- 10–20 s free recording (`NATURAL_BREATH_MIN_MS` / `NATURAL_BREATH_MAX_MS`)
- Peak detection on filtered belt signal → median inter-peak interval → `basePeriodMsRef`
- Participant can accept detected rate, use default (4 s), or retry
- Estimated lag from calibration stored in `beltLagMsRef`

### Phase 1 — Fixed-Level Practice
- 9 trials: 3× SAME + 3× FASTER + 3× SLOWER (shuffled), `PHASE1_TRIALS_PER_COND = 3`
- Fixed delta ratio = 0.25 (25% change, `PHASE1_DELTA_RATIO`) — comfortably suprathreshold
- Trial structure: **2 breaths at base rate, then 2 breaths at changed rate** (`TRIAL_BASE_BREATHS = 2`, `TRIAL_CHANGE_BREATHS = 2`)
- After each trial, app shows a live mini graph (pacer + belt) in bottom-left corner
- After all 9 trials, `Phase1ReviewPanel` shows a 3×3 grid of signal graphs with peak-timing error scores
- Can redo or continue to QUEST

### Phase 2 — QUEST Adaptive Staircase
- Dual independent staircases: FASTER and SLOWER
- Block structure: each block = 2× FASTER + 2× SLOWER + 1× SAME (shuffled, `buildQuestBlock`)
- SAME trials are uninformative (no-change catch); only FASTER/SLOWER trials update their respective staircase
- Trial structure identical to Phase 1 (2+2 breaths)
- Stopping rule: both posterior SDs < 0.10 log units AND minimum 6 trials each (`QUEST_MIN_TRIALS_EACH`, `QUEST_SD_STOP`)
- Hard cap: 25 trials per staircase (`QUEST_MAX_TRIALS_EACH`)

**Empirical priors** (derived from n=197 participants, High-salience, sessions 1+2):

| Staircase | Prior mean (log₁₀) | Prior SD (log₁₀) | ~% threshold |
|-----------|--------------------|------------------|--------------|
| Faster    | −1.0106            | 0.1314           | ~9.8%        |
| Slower    | −0.9439            | 0.2690           | ~11.4%       |

QUEST grid: 120 points, log₁₀ range [−2.2, 0.3].  
Weibull: β = 3.5, lapse = 0.02, guess = 1/3 (3AFC).

---

## Ratings (QUEST_RATING state)

After each QUEST trial, participant rates three things using SVG icon buttons in `QuestRating`:

| Rating       | Type  | Icons              | Values | Colors       |
|--------------|-------|--------------------|--------|--------------|
| Speed change | 3AFC  | snail/equals/runner| SLOWER / SAME / FASTER | purple / grey / blue |
| Confidence   | 6-pt  | confidence_1–6.svg | 1–6    | blue (#3498db) |
| Arousal      | 6-pt  | arousal_1–6.svg    | 1–6    | green (#27ae60) |

Icon sizes: speed = 72px, confidence/arousal = 48px.  
Endpoint labels: Confidence = "Not at all" / "Completely"; Arousal = "Very drowsy" / "Very alert".  
All three must be selected before the Confirm button enables.

`onSubmit(response: TrialCondition, confidence: number, arousal: number)` — signature unchanged from previous text-button version. Confidence/arousal are now 1–6 (previously 1–3).

---

## Data Logging (File System Access API)

Four CSV files created at session start, named `{participantId}_{timestamp}_{type}.csv`:

| File          | Key columns                                                                 |
|---------------|-----------------------------------------------------------------------------|
| `_accel.csv`  | phase, trial, packet_ts, sample_idx, x, y, z, pacer_radius                |
| `_hr.csv`     | phase, trial, timestamp, heart_rate                                         |
| `_trials.csv` | phase, trial, condition, base_period_s, change_period_s, start_ms, end_ms, peak_error_ms |
| `_quest.csv`  | trial, direction, delta_ratio, response, correct, confidence, arousal, posterior_mean_log, posterior_sd |

Rows flushed to disk after each trial via `flushPending()`. `pacer_radius` is NaN when no pacer running.

---

## Hardware

### Polar H10 (Bluetooth)
- Service UUID: `fb005c80-02e7-f387-1cad-8acd2d8df0c8`
- Accel characteristic: `fb005c82-...` (200 Hz, 16-bit signed, scale /100)
- HR characteristic: standard `heart_rate_measurement`
- Activation payload: `[0x02,0x02,0x00,0x01,0xC8,0x00,0x01,0x01,0x10,0x00,0x02,0x01,0x08,0x00]`

### Web Serial (lab trigger hardware)
- 115200 baud, TextEncoderStream writer
- **Must be connected before Bluetooth** to preserve user-gesture context for Web Serial API

---

## Signal Processing

All filters are 2nd-order Butterworth SOS, designed at fs=200 Hz (scipy.signal.butter). Implemented as direct-form II transposed biquads with persistent state in `filterState3Ref`.

- **Wide bandpass [0.1–1.0 Hz]:** passes breathing harmonics → can produce secondary spectral peaks at 2× breathing frequency
- **Tight bandpass [0.1–0.4 Hz]:** suppresses harmonics above ~2× fundamental
- **Lowpass [0.6 Hz]:** optional post-smooth on MLR output (the `-lp` model variants)

**Do not integrate accelerometer** — double integration causes unbounded drift. Use bandpass-filtered acceleration directly as the respiratory proxy signal.

Calibration statistics use the **median value from the most stable portion** of each breathing phase (not overall min/max) to suppress outlier sensitivity.

---

## Key Design Decisions & Hard-Won Lessons

- **No real-time biofeedback:** The animated "orange circle" driven by belt signal was removed. The belt signal is used only for calibration quality assessment and data logging.
- **`Math.pow()` throughout `functions.ts`:** The `**` exponentiation operator causes silent runtime errors under Vite/esbuild. All exponentiation uses `Math.pow()`.
- **Calibration timing:** Packet collection must start the moment the pacing circle appears — collecting during instruction screens introduces timing errors that corrupt the calibration regression.
- **Harmonic contamination:** Wide bandpass (0.1–1.0 Hz) passes 2nd harmonics; the multi-model selection approach selects the best-fitting variant per participant automatically.
- **Prior derivation:** Individual QUEST posteriors were reconstructed trial-by-trial from a prior dataset. Stability filter applied: posterior SD ≤ 0.35 AND last-2-trial swing ≤ 0.15 log₁₀ units. Group means taken from filtered participants (n varied by condition).
- **Staircase efficiency sweet spot:** ~20 change trials per staircase balances efficiency and stability. Tight empirical priors substantially reduce trials needed to converge.

---

## Constants Quick Reference

```typescript
DEFAULT_BASE_PERIOD_S    = 4        // fallback breath period if natural breathing step skipped
CALIB_CYCLES             = 4        // calibration breath cycles
NATURAL_BREATH_MIN_MS    = 10_000
NATURAL_BREATH_MAX_MS    = 20_000
READY_DELAY_MS           = 600      // pre-animation pause

PHASE1_DELTA_RATIO       = 0.25
PHASE1_TRIALS_PER_COND   = 3        // → 9 trials total
TRIAL_BASE_BREATHS       = 2
TRIAL_CHANGE_BREATHS     = 2

QUEST_FASTER_PRIOR_MEAN  = -1.0106
QUEST_FASTER_PRIOR_SD    =  0.1314
QUEST_SLOWER_PRIOR_MEAN  = -0.9439
QUEST_SLOWER_PRIOR_SD    =  0.2690
QUEST_BETA               = 3.5
QUEST_LAPSE              = 0.02
QUEST_GUESS              = 1/3      // 3AFC
QUEST_MIN_TRIALS_EACH    = 6
QUEST_SD_STOP            = 0.10     // log units
QUEST_MAX_TRIALS_EACH    = 25

SYNC_GOOD                = 0.70     // Pearson r
SYNC_FAIR                = 0.40
MAX_BASE_RADIUS          = 400      // px
MIN_BASE_RADIUS          = 190      // px
```

---

## Open Items / Next Steps

- Verify that SVG icon imports resolve correctly from `./assets/` in the Vite build (check `vite.config.ts` if SVGs are not rendering)
- Confirm 1–6 confidence/arousal values downstream in any analysis scripts (previously 1–3)
- Consider whether Phase 1 should also collect confidence/arousal ratings (currently ratings are QUEST-only)
- Ongoing: evaluate whether tight vs wide bandpass model selection is consistent across participant body types
