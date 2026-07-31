# Discrepancy log

Everything found that contradicts the pre-registration draft, the handoff, or the
existing analysis scripts. Each entry gives the evidence and the action.

Verified 2026-07-31 against radlab commit `98b2dca`. No participant outcome data
was inspected: all evidence below is source code, phase labels, timestamps,
file names, and column headers.

---

## A. Retractions

### A1. QUEST parameters: the pre-registration was right

An earlier pass flagged the QUEST parameters as inconsistent with the software.
That comparison was made against `reference/legacy_app_ts/constants.ts`, which
turns out to be a **different and superseded codebase** (`.ts`/`.tsx`; the live
experiment is `.jsx`/`.js` in radlab). Checked against the real source, every
QUEST value in the pre-registration is correct:

| Parameter | Pre-registration | `radlab BreathBelt/constants.js` |
|---|---|---|
| Prior mean | log10(0.5 s) | `QUEST_PRIOR_MEAN_LOG = Math.log10(0.5)` |
| Prior SD | 0.25 log units | `QUEST_PRIOR_SD = 0.25` |
| Levels | 46, log-spaced, 0.1 to 2.0 s | `QUEST_N_STEPS = 46`, `log10(0.1)` to `log10(2.0)` |
| Convergence | posterior SD < 0.10 | `QUEST_CONVERGENCE_SD = 0.10` |
| Minimum trials each | 10 | `QUEST_MIN_TRIALS_EACH = 10` |
| Hard cap | 60 Phase 3 trials | `QUEST_MAX_PHASE3_TRIALS = 60` |
| Weibull slope / lapse / guess | 3.5 / 0.02 / 1/3 | `3.5` / `0.02` / `1/3` |

No action. The pre-registration stands.

### A2. Trigger code 11 really was removed

`TRIGGERS.md` lists code 11 (condition onset) in its vocabulary table, which
appeared to contradict the pre-registration's claim that it was removed. The code
disagrees with its own documentation: `useTrialRunner.js` emits `sendTrigger('10')`
at trial start and `sendTrigger('12')` at trial end, and **never emits 11**.

The pre-registration is correct. Condition onset is computed, not measured.
`TRIGGERS.md` is stale on this row. Trigger-count checks in Task 3 must expect
**two** codes per trial, not three.

---

## B. Blocking: preprocessing correctness

### B1. The calibration fit window is 3.1 s longer than the calibration

`CALIB_CYCLES = 3` is exported from `constants.js` but **never read anywhere**.
The actual pacing loop in `CalibrationScreen.jsx` is a hard-coded
`for (let i = 0; i < 4; i++)`, so calibration is genuinely 4 cycles at 4000 ms,
i.e. 16,000 ms. The pre-registration is correct; the constant is dead and
misleading.

But the measured `calib_breathe` span for 14542 is **19,101 ms**, an overrun of
3,101 ms. That is not packet granularity: the `baseline` block, nominally
120,000 ms, measures 120,401 ms, an overrun of only 401 ms.

The gap is the `FITTING` state. There is no `calib_fitting` phase label, so
samples collected while `fitBestModel()` runs stay tagged `calib_breathe`. The
last ~3.1 s of that window is unpaced breathing.

**Action.** Fitting calibration weights on the whole `calib_breathe` window would
regress ~16% unpaced data against a pacer that is not there, degrading the fit
and biasing it in a participant-specific way. Task 1 must anchor on the **first**
`calib_breathe` sample and take exactly `4 x breath_period_ms`, discarding the
remainder. Verify per participant that the block is at least that long.

### B2. Trigger encoding differs between the two rigs

> **Superseded by B10.** The conclusion holds, the mechanism stated below does
> not. The rigs use different physical WIRES, not a numeric multiplier, and an
> idle nibble floats high so codes never appear as bare 10 or 160. Decode by
> nibble mask. Kept for the reasoning trail.

`constants.js` defines the rigs with different parallel-port encodings:

```js
{ value: 'Biopac_Left',  address: 0xDFF8, shift: 16 },  // code on the high nibble
{ value: 'Biopac_Right', address: 0xD030, shift: 1  },  // code as-is
```

So trial start (code 10) appears as **10** on the right rig and **160** on the
left rig. A decoder written and tested on 14542 (right rig) will find no triggers
at all on 17734 and 17896 (left rig), or will misread them.

`TRIGGERS.md` still describes both Biopac branches as "stub only", which is stale:
the `address`/`shift` fields and `BIOPAC_SERVER_URL` show the parallel-port path
was implemented afterwards, and 14542 aligned successfully.

**Action.** Task 3's trigger decoder must branch on
`belt_sessions.trigger_device`. The handoff's note that the channel idles at 240
(`0xF0`) was established on a right-rig participant and must be re-checked per
rig rather than assumed.

### B3. Seat conflict for participant 14425

| | ACQ filename | `trigger_device` |
|---|---|---|
| 14425 | `L14425.R0000.acq` → left | `Biopac_Right` |
| 17734 | `L17734.R14701.acq` → left | `Biopac_Left` |
| 17896 | `L17896.R13738.acq` → left | `Biopac_Left` |

`R0000` states the right seat was empty, so 14425 was physically on the left
while the software was left on its `Biopac_Right` default. If so the trigger went
to port `0xD030` unshifted while respiration was recorded on the left channel.

**Resolved, Norm 2026-07-31.** No run sheet is available, but the trigger codes
are authoritative and the two rigs are completely orthogonal. B10 establishes the
mechanism: they write to different physical wires, right on the low nibble and
left on the high nibble, which is what lets two simultaneously running
participants share a recording and still be separated.

**Action.** In Task 3, decode each session's trigger channel and derive the rig
from the observed code set rather than trusting `trigger_device`. Reconcile
against the ACQ filename seat and fail loudly on any participant where the three
sources do not agree. For 14425 specifically, the rig that emitted the triggers
and the seat that carried the respiration signal may genuinely differ, so resolve
them independently rather than assuming one implies the other.

### B4. Two ACQ files contain two study participants each

`L17734.R14701.acq` and `L17896.R13738.acq` each hold two enrolled participants.
Both respiration channels carry real breathing, so the handoff's rule "select the
active breath channel by variance" is **ambiguous for these files** and will pick
the wrong person roughly half the time.

**Action.** Select the channel by seat, from the ACQ filename, cross-checked
against `trigger_device`. Variance selection remains correct for choosing between
an occupied and an empty slot, not between two occupied seats.

### B5. The ACQ lookup fails for every left-seat participant

`R/prep_physio.R` currently matches with:

```r
pattern = paste0(".", PID, "\\.acq$")
```

This anchors the ID at the **end** of the filename, so it matches right-seat
participants only. `14425`, `17734`, and `17896` will all fail with "No ACQ file
found". A comment in the same file claims the convention is
`L<leftID>_<rightID>.acq` with an underscore separator, which is also wrong: the
separator is a dot.

One filename is malformed: `L16549.14542.acq` is missing the `R` prefix on the
right-seat ID, so a strict `L\d+\.R\d+\.acq` pattern breaks on it.

**Action.** Build an explicit participant-to-seat-to-file map in `R/seatmap.R`
rather than pattern-matching, and fail loudly on any participant that does not
resolve to exactly one file and one seat.

### B6. BioPac decimation has no anti-alias filter

`R/prep_physio.R` decimates by stride:

```r
.downsample <- function(x, factor) x[seq(1L, length(x), by = as.integer(factor))]
breath_ds <- .downsample(breath_raw, raw_hz / RESP_HZ)
```

Taking every 80th sample from 2000 Hz gives exactly 25.0 Hz, so the **rate is
correct**. But there is no low-pass before the stride, so any content above
12.5 Hz folds back into the retained band. Study 5 avoids this by using
`signal::decimate`, whose internal Chebyshev anti-alias filter is why its
`breath_pipeline.R` notes "no separate LP pass is needed before decimation".

**Updated 2026-07-31.** There is no RSP100C. The system is a **BN-RSPEC
BioNomadix Respiration and ECG wireless system**, which has no operator-settable
gain or filter: bandwidth is fixed in hardware and its value is not yet
documented. The AcqKnowledge template was checked and imposes nothing: all 17
channels are raw at 2000 Hz, and the template governs display and derived
channels only.

So the only anti-alias protection ahead of decimation is a fixed hardware
bandwidth of unknown value. That does not make aliasing likely, since respiration
transducers are inherently low-bandwidth, but it does mean the safety of stride
decimation cannot currently be asserted from documentation.

**Action.** Switch to `signal::decimate`, which removes the question regardless
of the amplifier setting, and assert that `raw_hz %% RESP_HZ == 0` rather than
letting `as.integer()` silently truncate a non-integer factor.

Note that Study 5 ran at **25.641 Hz**, not 25.0, because it decimated 2000 Hz by
78. BreathBelt uses 80 and is genuinely at 25.0 Hz. Any constant or threshold
ported from Study 5 that is expressed in samples rather than seconds must be
rescaled by 25.641/25.

### B7. The PCA calibration models can never be selected

`fitBestModel` calls:

```js
const wp = solveLS3(pc1, pc1, pc1, tgt)
```

passing the **same column three times**. The design matrix is rank 2 of 4, so
`solve4x4` hits its own `Math.abs(M[col][col]) < 1e-14` singularity guard and
returns null, and the PCA branch is skipped. Verified by replicating `solveLS3`
in R: returns NULL, rank 2 of 4.

Consequences:

- `pca-wide` and `pca-tight` have never been selected for any participant. The
  "six candidate calibration models" of Section 4.5 and EH3 are in practice
  **four**.
- Even had it solved, only `wp[1]` is taken as the scalar coefficient while the
  intended value is spread across three identical columns, so the scale would
  have been wrong.

`R/calibration.R` implements the PCA branch as intended and evaluates all six.
**The offline selected model may therefore differ from
`belt_sessions.calib_model_label`.** The offline label is the one EH3 and
`selected_model_freq` should use.

**For Norm.** Fixing this in radlab is a protocol change, not a bug fix, because
participants collected after the fix would run under a different model-selection
procedure from the 18 already collected. Since the offline refit is authoritative
and the live weights only drive the on-screen preview, the cheapest correct move
is to leave the software alone and let the offline pipeline decide. Flagged
rather than actioned.

### B8. Filtering the calibration window requires explicit edge padding

Calibration is 16 s. A 0.05 Hz high-pass corner has a 20 s period, **longer than
the data being filtered**, so a cold zero-state start distorts essentially the
whole window.

The software handles this with `oddExtend` and a 3000-sample pad, roughly 15 s at
the 203 Hz accelerometer rate, citing a settling time of about five time
constants. **R's `signal::filtfilt` does no such padding.**

Measured on the synthetic fixture, filtering unpadded:

| | unpadded | odd-extended |
|---|---|---|
| recovered lag (true 320 ms) | 160 ms | 360 ms |
| reconstruction vs true breath | fails | 0.99 |

`R/calibration.R` odd-extends explicitly. Any other script that band-passes a
short window needs the same treatment; this is a standing hazard, not a one-off.

### B9. The preregistered negative-lag check is vacuous on the live values

`estimateLagMs` searches `for (shift = 0; shift <= maxShift)`, i.e. non-negative
shifts only, to a maximum of 1500 ms. `belt_sessions.calib_lag_ms` is therefore
non-negative **by construction**, and bounded at 1500 rather than 2000.

Section 5.1 preregisters "flag any participant whose estimated lag is negative,
or exceeds 1000 ms" and a search over plus or minus 2000 ms. Against the live
values the negative half of that check can never fire. It only becomes meaningful
against the offline refit, which searches symmetrically over the preregistered
range. `R/calibration.R` does.

---

## C. Statistical

### C1. The key variance parameter is estimated with upward bias

`scripts/02_estimate_variance_components.R` estimates
`duration_bias_between_sd_ms` as `sd()` of the per-participant mean differences.
That estimates

```
Var(observed participant means) = sigma^2_between + sigma^2_within / k
```

not `sigma^2_between`, where `k` is the paired breaths per participant (roughly
56, from two 120 s free-breathing blocks). Since required N scales with the
variance, the inflation is squared in the sample size.

The script already extracts `duration_diff_within_sd_ms`, so the correction is
available at no additional disclosure:

```
sigma^2_between = max(0, s^2_observed - mean(s^2_within) / k)
```

Both terms are whitelisted, so the corrected combination is still a nuisance
variance. **Approved by Norm 2026-07-31.**

### C2. H1's matching rule is unspecified

Section 5.3 gives H1's unit as "individual breath, matched between devices" but
never says how breaths are matched. Only Section 5.4 (H2) defines a matching
procedure, with a 150 ms tolerance.

Meanwhile the extraction script pairs breaths by **rank position**
(`.pair_by_position`), deliberately avoiding temporal matching because that is
H2's test procedure. But rank pairing slips permanently after the first
detection discrepancy, so every subsequent difference is noise.

The consequence is that the extracted variance component may describe a different
statistic from the one H1 will actually compute, which would make the power
calculation wrong in an unknown direction.

**Action.** Specify H1's matching rule in the pre-registration before Task 4.
This is the same class of problem as Task 2's onset-detector reconciliation and
should be settled with it.

### C3. Kappa threshold and prevalence

Decision rule for H7 test 1 is set at **kappa lower 95% bound above 0.60**, with
0.80 described as the target in prose but not as a rule. Kappa is
prevalence-sensitive and the direction-correct base rate differs between Phase 2
(suprathreshold) and Phase 3 (near threshold), so raw percent agreement and
Gwet's AC1 are preregistered as companion descriptives to make a prevalence
artefact diagnosable rather than fatal.

The base rate feeding the Task 6 margin derivation must be **assumed**, not taken
from the pilot, per Section 5.12 note 5. Source is Study 5, now vendored at
`reference/study5_snapshot/`.

### C4. H7's usable trial count is smaller than it looks, and its dropouts are informative

From `Intero2025_BehaviourLedBreathAnalysis.R` around line 918, the ported
definition is exactly as Section 4.3 describes:

```r
dur_12 <- mean(c(dur_b1, dur_b2), na.rm = TRUE)
dur_34 <- mean(c(dur_b3, dur_b4), na.rm = TRUE)
direction_correct <- sign(dur_34 - dur_12) == sign(delta)
```

Two consequences the power simulation must honour:

**Catch trials are excluded.** The guard is `if (!is.na(delta) && delta != 0)`,
so no-change trials never get a `direction_correct` value. Trials arrive in
blocks of five with one catch trial, so H7's kappa rests on roughly **four fifths**
of Phase 3 trials, not all of them. Simulating 25 trials per participant
overstates H7's information by about 20%.

**Device-specific dropout is the most important failure mode and is currently
invisible.** `direction_correct` is NA when the breaths it needs were not
detected. In a two-device comparison the accelerometer may fail to detect a
breath where the stretch belt succeeds, producing a value on one device and NA on
the other. Cohen's kappa needs complete pairs, so those trials silently drop out
of the very analysis that is supposed to detect them. A device that yields no
answer is not equivalent to one that yields the right answer.

**Action.** Add to H7: report the rate of device-specific NA alongside kappa, and
preregister it as part of the decision rather than as a footnote. Note also that
`na.rm = TRUE` lets a pair mean be computed from a single detected breath, so
partial detection degrades quietly rather than becoming NA.

### C5. Calibration fit and device lag are not independent

A perfect calibration model still scores only `cos(2*pi*lag/period)` when
correlated against an unshifted pacer:

| device lag | ceiling on calibration r |
|---|---|
| 200 ms | 0.951 |
| 320 ms | 0.876 |
| 500 ms | 0.707 |
| 700 ms | 0.454 |

At a 500 ms lag the ceiling sits exactly on the software's `SYNC_GOOD` threshold
of 0.70, so a participant with a sound belt and an unremarkable lag is graded
"Fair" on model quality they do not lack.

This matters because **`calibration_fit` and `device_lag_ms` are both whitelisted
inputs to the power simulation** (Section 1.7). Treating them as independent
parameters double-counts one underlying quantity and will misstate the simulated
spread of calibration quality.

`R/calibration.R` now returns both `mlr_r_calib` (uncorrected, comparable to the
live gate participants were actually held to) and `mlr_r_calib_lagcorr` (the
model quality after removing the estimated lag). The extraction script should
carry both, and the simulation should draw lag first and derive the fit ceiling
from it rather than sampling the two independently.

### B10. Trigger codes are a nibble split, not a numeric offset

Verified against the AcqKnowledge template and three recordings (2026-07-31).

The trigger reaches the MP160 as **eight separate physical lines**,
`Digital (STP Input 0..7)`, which AcqKnowledge also sums into a derived
`Experiment Triggers` channel. The two rigs use different **wires**, not merely
different numbers:

| rig | port | shift | nibble | bits |
|---|---|---|---|---|
| `Biopac_Right` | `0xD030` | 1 | low | 0 to 3 |
| `Biopac_Left` | `0xDFF8` | 16 | high | 4 to 7 |

Every event code fits in 4 bits, which is what makes the split work.

**An idle nibble floats high.** On a right-rig recording the untouched high
nibble reads `0xF0`, so `Experiment Triggers` idles at 240 and trial start
appears as **250**, not 10. Confirmed on 14542: the channel takes values 240 plus
0 to 13, and the per-line counts match codes 10 and 12 exactly, with STP3 highest
because bit 3 is set by both.

Decoding must therefore **mask the rig's nibble**. Dividing by the shift is wrong,
and subtracting a global idle is wrong too, because dual-occupancy files have no
single idle level. `R/seatmap.R` masks.

Verification on a dual file, `L17734.R14701.acq`:

| nibble | rig | participant | trial starts | trial ends | code 11 |
|---|---|---|---|---|---|
| low | right | 14701 | 34 | 34 | 0 |
| high | left | 17734 | 33 | 33 | 0 |

Two complete independent sessions in one recording, each with block codes 1 to 9
and 13 exactly once. On the single-occupancy `L0000.R3997.acq` the high nibble is
idle, as expected.

Two further facts:

- **Code 11 does appear in recordings**, but only from `sendTestCascade`, which
  fires all 13 codes at setup. After dropping everything before session start its
  count is zero in every session checked. This confirms A2 rather than
  contradicting it.
- **Block codes can repeat.** 3997 emitted code 7 (Block 4 end) twice. The
  trigger-count check in Task 3 must tolerate this rather than failing.

### C6. EH3 may be testing an arbitrary label

The three accelerometer axes are three projections of one chest movement, so
they are strongly collinear. Under collinearity many weight vectors reconstruct
the breathing equally well, which has two consequences:

- **The weights are not identified**, even when the reconstruction is excellent.
  On the synthetic fixture the recovered weight direction bears no resemblance to
  the true one while the reconstruction still correlates at 0.99. Nothing should
  be interpreted from the coefficients themselves.
- **The six models score within noise of each other.** On that same fixture all
  six land within 0.014. When the spread is that small the "selected model" is
  close to a coin flip.

EH3 asks whether the selected model predicts subsequent agreement. If selection
is arbitrary tie-breaking, EH3 is testing a near-random label and will find
nothing regardless of whether the underlying idea is right.

`fit_calibration` now returns `model_margin`, the gap between the winner and the
runner-up. **Recommendation:** report the margin distribution alongside
`selected_model_freq`, and preregister that EH3 is interpreted only where the
margin is large enough for selection to be meaningful. Whether real data shows
larger margins than the synthetic case is unknown and must not be checked before
the extraction runs.

---

## D. Housekeeping

### D1. `reference/legacy_app_ts/` is a different codebase

`App.tsx`, `components.tsx`, `functions.ts`, `constants.ts` and the `CONTEXT.md`
that describes them are a superseded TypeScript app, not the live experiment.

Provenance confirmed: they come from `github.com/Normega/breathbelt` ("Wireless
respiration change detection"), a separate private repo created 2026-03-05 and
last pushed 2026-03-12, which matches the legacy `CONTEXT.md` date of 2026-03-11.
That repo is untouched. This project pushes to
`github.com/Normega/breathbelt-analysis`.
Its `CONTEXT.md` describes a single 10 to 20 s "natural breathing" block and no
post block, which would have gutted H5 and H6 had it been believed. The live
software has two 120 s blocks (`BASELINE_DURATION_MS = POST_BASELINE_DURATION_MS
= 120_000`), confirmed by measurement: 120.4 s and 120.5 s for 14542.

Kept for provenance only. Do not treat as a specification.

### D2. Diverged duplicate script

`prep_physio_14542.R` existed in two places, differing by 206 lines. The
`Analysis/` copy was newer and had correct path handling; it is now
`R/prep_physio.R`. The `code/` copy is `archive/prep_physio_14542.diverged_copy.R`.

### D3. Pilot sample is 18, not 17

Eighteen participants have an accel CSV, an ACQ file, phase 2 and phase 3 trial
records, and a recorded `phase3_end_ms`:

```
3997  9082  9085  13738 14425 14542 14677 14701 16117
16753 16807 17446 17704 17734 17755 17758 17788 17896
```

`998877` is a test account (`trigger_device = AD_BBT`, no ACQ file) and is excluded.

Six IDs appear in ACQ filenames with no accelerometer file (`17926`, `5965`,
`14776`, `16549`, `16711`, `9967`). Treated as adjacent-seat occupants with
missing or other-study belt data. If recovered they join the **confirmatory**
sample, not this pilot, since Section 1.7 forbids extending the pilot list after
output is seen. They would contribute at the interim re-estimation in step 6.

### D4. Minor inconsistencies

- `FIXATION_DELAY_MS = 800` in `CalibrationScreen.jsx` carries the comment
  "matches READY_DELAY_MS", but `READY_DELAY_MS = 1000`. The 800 ms value is what
  runs. Measured `calib_fixation` for 14542 is 0.9 s.
- Phase coding differs by source: the accelerometer CSV uses strings
  (`calib_fixation`, `calib_breathe`, `baseline`, `phase2`, `inter_trial`,
  `phase3`, `post_baseline`, `idle`) while `belt_trials.csv` uses integers `2`
  and `3`. The extraction script's `trial_table$phase == 3` must be checked
  against whichever the RDS actually carries.
- `pacer_radius` is empty in every row of every accelerometer CSV, confirming the
  pre-registration's statement that it must be reconstructed analytically.
- Confidence and alertness anchor wordings differ between the pre-registration
  and the software. Cosmetic, but the pre-registration should quote the software.

---

## E. Pacer reconstruction reference

For Task 1. From `breathUtils.js`:

```js
getPacerRadius(t, startMs, periodMs)
  = (1 - Math.cos(2 * Math.PI * (t - startMs) / periodMs)) / 2
```

Normalised 0 to 1. Equals 0 at `t = startMs` (fully exhaled) and 1 at
`startMs + periodMs/2` (peak inhale). Since `(1 - cos)/2 = 0.5 - 0.5*cos`, the
signal is a DC offset plus a single cosine at exactly `1/periodMs`, so after
band-passing it is a pure sinusoid at the commanded period, as the
pre-registration states.

The phase anchor matters: `startMs` is a **trough**, which is also how breath
onset is defined. Reconstruct as `-cos`, not `sin`.
