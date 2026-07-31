# BreathBelt: Pre-registration and Power Analysis — Handoff

For continuing this work in Claude Code with direct data and repo access.

---

## STOP. Read this before opening any data file.

Seventeen completed participants are being used as an **internal pilot** for variance estimation. They remain in the confirmatory sample. That is only legitimate if nothing beyond a fixed whitelist is ever observed.

**An agent with file access is the main threat to this.** The natural debugging reflex — open the RDS, print a summary, plot the signal, check whether agreement looks reasonable — destroys the protection permanently. It cannot be undone by deciding to ignore what was seen.

### Hard rules

1. **Never print, plot, summarise, or otherwise inspect participant outcome data.** Not to debug. Not to sanity-check. Not "just the first few rows."
2. **Never compute** a mean bias, correlation, agreement coefficient, match rate, timing difference, or any error relative to the pacer, outside the sanctioned script.
3. **The only permitted route to pilot data is `estimate_variance_components.R`.** Run it. Read its report file. Nothing else.
4. **To test code, use participant 14542 alone or synthetic data.** 14542 is already processed and its variance contribution is negligible; it is the designated debugging participant. Even there, do not inspect agreement quantities.
5. **If a script fails on real data**, debug from the error and the code, not by inspecting the data that caused it. If that proves impossible, stop and ask Norm.
6. **Do not add anything to `WHITELIST`** in the extraction script without explicit approval from Norm.

The full extract and block lists are in Section 1.7 of the pre-registration draft, with each blocked quantity keyed to the hypothesis it protects.

---

## 1. What this project is

BreathBelt asks whether a Polar H10 accelerometer chest strap and a BioPac stretch respiration belt measure breathing closely enough to be treated as interchangeable. Participants wear both simultaneously through calibration, free breathing, fixed-rate paced breathing, and an adaptive staircase, in one lab session. A visual pacer provides independently known ground truth during paced blocks.

Broader context is behavioural interoception. The experiment software is part of the RADlab platform.

**Current stage.** Data collection is paused at 17 complete participants. Nothing has been analysed. The immediate goal is to finish the pre-registration, run a power simulation, and justify a sample size before looking at outcomes.

---

## 2. Files

### Produced so far

| File | Purpose |
|---|---|
| `breathbelt_prereg_draft.md` | Five-section pre-registration draft. The controlling document. |
| `estimate_variance_components.R` | Whitelisted variance extraction. Will not run yet, see Task 1. |
| `prep_physio_14542.R` | Existing per-participant preprocessing. Needs correcting and generalising. |
| `diag_physio_14542.R` | Diagnostics for the above. |

### Paths

```
Repo:      github.com/Normega/radlab   (public)
Drive:     I:/Shared drives/Behavioral Interoception/Summer2026_CompareBelts/
  Data/acq_physio     BioPac .acq files
  Data/bt_physio      Bluetooth accelerometer and HR CSVs
  Data/tables         Exported tabular data
  Analysis/output     Per-participant RDS
  Analysis/pilot_variance   Variance extraction output (created by the script)
```

Experiment source lives at `src/games/BreathBelt/` with shared signal code at `src/games/shared/breath/`.

---

## 3. Task queue

In order. Later tasks depend on earlier ones.

### Task 1: Correct the preprocessing pipeline

`estimate_variance_components.R` deliberately refuses to run until this is done.

The existing pipeline fits accelerometer weights by regressing the three band-passed axes onto the **BioPac breath signal**, then measures agreement against BioPac. That is circular: it fits a model to predict device B, then reports how well it predicts device B. It also absorbs participant-specific variance, which would understate the between-participant standard deviation and yield an optimistically small sample size.

**Fix.** Fit weights against the **reconstructed pacer**, on the **Phase 1 calibration window only**.

- The pacer is not in the data. `pacer_radius` is present as a column but is empty for every row. Reconstruct it analytically: a sine at the commanded period, anchored to the block or trial onset. The software's function is pure; mirror it.
- Calibration is 4 breath cycles at 4000 ms, roughly 19 s and 3,900 samples, in the `calib_breathe` phase.
- Fit on calibration only. Do not extend to paced trials: that would compromise H4, which tests prediction of the pacer.
- Retain the BioPac-target fit as a sensitivity analysis, labelled an upper bound.

**New fields the RDS must carry**, or the extraction script will fail:

| Field | Contents |
|---|---|
| `belt$calib_target` | `"pacer"` or `"biopac"` |
| `belt$calib_lag_ms` | Estimated device lag |
| `belt$calib_model_label` | Which of the six models won |
| `belt$mlr_r_calib` | Calibration fit |
| `alignment$residual_sd_ms` | Alignment residual spread |

### Task 2: Reconcile onset detection

`estimate_variance_components.R` contains `.detect_onsets`, a trough detector written for that script. H2 will preregister a specific detector. These must be the same function, or the variance components will not describe the signal the confirmatory analysis sees.

The prior Study 5 script `Intero2025_BehaviourLedBreathAnalysis.R` contains the trough detection used for `direction_correct`. Port that, put it in a shared file, and have both scripts source it.

### Task 3: Generalise and batch-run preprocessing

`prep_physio_14542.R` is participant-specific. Turn it into a function over participant ID and run across the 17. Do not inspect the outputs.

Fixed rules that must survive generalisation:

- Drop every trigger before the session-start trigger. This removes the setup verification cascade, which writes trial-start and trial-end codes into the channel. The existing 100 s cutoff is a fragile stand-in; replace it.
- Verify the trigger count matches the `belt_trials` row count and fail loudly if not.
- Select active breath and heart-rate channels by variance, not by slot index. Slot order does not reliably map to seat.
- Lag search over plus or minus 2000 ms. Flag any participant with negative lag or lag above 1000 ms.
- Apply lag correction uniformly. The software computes some trial-level agreement measures with correction and others without; recompute everything consistently.

### Task 4: Run the extraction

Set `PILOT_IDS`, run `estimate_variance_components.R`, read `variance_components_report.txt`. Nothing else.

### Task 5: Build the simulation machinery

One data-generating function for the whole study, not one script per hypothesis. The hypotheses share parameters, and separate scripts let those drift out of sync.

```
simulate_participant(params)   -> breath, trial, block, participant records
simulate_study(n, params)      -> replicate across participants
analyse_study(data)            -> named pass/fail vector for H1 through H8
power_curve(n_grid, params, n_sims) -> power by N, per hypothesis
```

Deliverable is one figure: power against N, eight curves, with the recruitment ceiling drawn as a vertical line.

Not everything needs simulating. Compute analytically: H1, H4, H6, all paired equivalence tests on a participant-level mean. Simulate: H2, H3, H5, H7, H8, where the sampling distribution is intractable or the model has random slopes.

Two parameters are fixed in advance and must be honoured:

- **Assumed true bias is one quarter of the equivalence margin, not zero.** Equivalence power peaks at zero, so assuming zero gives an optimistic sample size.
- **Phase 3 trial count is a random variable**, governed by the staircase stopping rule and truncated at 60. Draw it; do not fix it at 25.

Packages: `lme4`, `lmerTest`, `TOSTER`, `faux`, `irr`.

### Task 6: Set the equivalence margins

The margins are now the only thing standing between the design and a sample size. Loose margins need 20 participants; tight ones need 100.

Preferred approach for H1: **derive the margin from H7.** Simulate injecting a systematic bias of X ms into one device's breath durations, re-run the direction-correct classification, and find the X at which classification agreement falls below an acceptable level. That X is the margin, and it is defensible in a way that a round number is not.

Also run it as a sensitivity analysis: at a feasible N, what is the smallest margin that can be bounded? Given no pilot effect sizes, that framing is more honest than choosing a margin that happens to produce a convenient N.

---

## 4. Decisions already made

Do not relitigate these without checking with Norm.

| Decision | Rationale |
|---|---|
| Calibration is Phase 1, before free breathing | Matches the software's actual order |
| "Baseline" renamed "free breathing" | Clarity; the blocks are not a baseline for anything |
| Offline filter settings are authoritative | The live settings exist only to drive an on-screen preview |
| Offline: 0.05 to 1.0 Hz band-pass, 0.6 Hz low-pass, 4th-order Butterworth, zero-phase, at 25 Hz | Outperformed raw vector magnitude in prior testing |
| BioPac downsampled 2000 Hz to 25 Hz | Shareable file sizes |
| Weights fitted against the pacer, not BioPac | Removes circularity |
| Participants flagged, not excluded, for poor adherence or calibration | Poor adherence appearing similarly on both devices is informative |
| Exclusion only for incomplete data | Missing signal from either device, or missing trial records |
| MAIA-2 total score by default | Subscales exploratory and uncorrected |
| Interoception replication demoted to exploratory (EH4) | Needs over 200 participants; contrast test reaches only 0.74 power at N=100 |
| Match proportion is blocked from extraction | It is the recall component of H2's test statistic |
| Calibration fit and device lag are extracted | Neither enters a decision rule; both are preprocessing parameters |
| All 17 used as pilot, no holdout | They stay in the confirmatory sample, so a holdout costs precision for nothing |

Hypothesis numbering changed once during drafting. Current: H1 duration agreement, H2 cycle-level detection, H3 rate invariance, H4 pacer accuracy, H5 variability, H6 stability, H7 downstream equivalence, H8 alertness. Exploratory: EH1 sensibility and breathing, EH2 morphology, EH3 calibration model as moderator, EH4 interoception pattern.

---

## 5. Technical facts established

Empirically verified. Trust these over assumptions in older code.

### Accelerometer

- Exactly 36 samples per packet, every packet, no exceptions
- Packet interval: mean 177 ms, median 195 ms. **Not 1000 ms.** Intervals cluster on multiples of 50 ms, which is browser timestamp granularity, not missing data
- True rate 203.4 Hz. **Per-sample interval 4.916 ms, not 5.000 ms.** The 5.000 assumption costs 2.9 ms at each packet start
- Packet timestamps mark the **last** sample; back-assign
- Coverage is continuous: 9 packets out of 6,867 show a real gap, 3.7 s out of 1,215 s
- Timestamp jitter: 35 ms SD, 74 ms at the 95th percentile, 319 ms max. Slow clock wander of 373 ms across a session
- **Consequence:** an onset-timing tolerance tighter than about 75 ms is not supportable. H2 proposes 150 ms

### BioPac

- 2000 Hz raw, decimated to 25 Hz
- Trigger channel idles at 240 (0xF0) between pulses, not 0
- The setup verification cascade writes trial codes before session start; drop everything before the session-start trigger
- No absolute clock. Aligned by matching trial-start triggers to software trial onsets in order, with linear drift correction
- Drift is roughly 384 ms per session, close to the 373 ms of browser clock wander. The correction is largely absorbing browser timing, not acquisition hardware error
- **[NEEDS INPUT]** RSP100C gain and filter settings. Omitted from the pre-registration for now

### Design

- Phase 2 is **3 conditions × 3 repetitions = 9 trials**, randomised. Conditions are 3000, 4000, 5000 ms. It is *not* nine distinct rates
- Every trial is 4 breaths: 2 at the 4000 ms baseline, then 2 at the condition period
- Condition onset is **computed, not measured**: trial start plus 8000 ms. Trigger code 11 was removed because emitting it disrupted pacer animation timing
- Phase 3 ratings are **confidence** (6-point, "no idea" to "certain") and **arousal** (6-point, "very tired" to "very alert"). The arousal item is worded as activation in the software and indexes alertness
- QUEST: Weibull, slope 3.5, guess 1/3, lapse 0.02. Prior mean log10(0.5 s), SD 0.25 log units. 46 log-spaced levels from 0.1 to 2.0 s
- Stopping: both staircases posterior SD below 0.10 log units with at least 10 updating trials each, or 60 Phase 3 trials
- Trials arrive in shuffled blocks of 5: 2 on the less certain staircase, 2 on the other, 1 catch trial. Catch trials never update
- Six candidate calibration models; the winner varies by participant. This is why EH3 exists
- Observed for 14542: 9 Phase 2 trials, 25 Phase 3 trials, ~196 breaths, 20.3 minutes of streaming
- Inter-trial time exceeds task time, because trials are participant-initiated. **H6 must use elapsed wall-clock time, not trial index**

---

## 6. Conventions

- Always namespace dplyr explicitly: `dplyr::filter`, `dplyr::mutate`, `dplyr::summarise`, `dplyr::select`, `dplyr::lag`
- Every R script opens with the standard package setup block, with the `packages` vector tailored to that script
- Deploys are `git add . && git commit -m "..." && git push`, staging everything
- `CONTEXT.md` in the repo root carries architecture context across sessions
- Norm prefers brief, point-form responses; plan before coding; check in when uncertain
- No em-dashes in drafted documents

---

## 7. Open items needing Norm, not Claude Code

| Item | Blocks |
|---|---|
| RSP100C gain and filter settings | Methods completeness |
| Pilot participant list, fixed before extraction | Task 4 |
| Realistic recruitment ceiling | Task 5, and whether this is a power or sensitivity analysis |
| Interim re-estimation point and hard cap | Section 1.7 sequence, step 6 |
| Acceptable classification agreement level for the H7-derived margin | Task 6 |

---

## 8. Where to start

1. Read `breathbelt_prereg_draft.md` in full. It is the controlling document and everything else serves it.
2. Confirm the pilot rules above are understood before touching `Analysis/output`.
3. Begin Task 1. Nothing downstream can run until the pacer-target fit exists and the RDS carries the new fields.
