# Architecture context

Carries technical context across sessions. Facts here are empirically verified or
read from source. Trust these over assumptions in older code or in
`reference/legacy_app_ts/`.

_Last updated 2026-07-31. Software facts verified against radlab `98b2dca`._

---

## What runs the experiment

The live experiment is `src/games/BreathBelt/` in `github.com/Normega/radlab`,
written in JSX. Shared signal code is `src/games/shared/breath/`. The files that
determine the experiment numerically are mirrored read-only into
`reference/radlab_snapshot/` with the commit SHA in `PROVENANCE.txt`.

`reference/legacy_app_ts/` is a **superseded** TypeScript app. Not a
specification. See `docs/discrepancies.md` D1.

## Session structure

Five blocks in one session, roughly 40 to 60 minutes.

| Block | Accel phase label | Duration | Notes |
|---|---|---|---|
| Block 1, fixation | `calib_fixation` | 800 ms | `FIXATION_DELAY_MS` |
| Block 1, calibration | `calib_breathe` | 16,000 ms paced, plus ~3.1 s of model fitting | 4 cycles at 4000 ms, hard-coded loop |
| Block 2, free breathing 1 | `baseline` | 120,000 ms | no pacer |
| Block 3, fixed rates | `phase2` | 9 trials | 3 conditions x 3 reps, 3000/4000/5000 ms |
| Block 4, staircase | `phase3` | 20 to 60 trials | dual QUEST, participant-initiated |
| Block 5, free breathing 2 | `post_baseline` | 120,000 ms | no pacer |

**Blocks 3 and 4 are off by one from their data labels** `phase2` and `phase3`,
and from `belt_trials.phase` values 2 and 3. This is permanent; do not "fix" it.

`inter_trial` and `idle` also appear as phase labels and belong to no block.
Every trial in Blocks 3 and 4 is 4 breaths: 2 at the 4000 ms baseline, then 2 at
the condition period.

The `calib_breathe` label overruns the actual pacing by about 3.1 s because
`fitBestModel()` runs inside it. Trim to `4 x period` from the first sample.

## Accelerometer

- Exactly 36 samples per packet, no exceptions
- Packet interval: mean 177 ms, median 195 ms. Not 1000 ms. Intervals cluster on
  multiples of 50 ms, which is browser timestamp granularity, not missing data
- True rate 203.4 Hz. Per-sample interval **4.916 ms, not 5.000 ms**. The 5.000
  assumption costs 2.9 ms at each packet start
- Packet timestamps mark the **last** sample. Back-assign
- Coverage is continuous: 9 packets of 6,867 show a real gap, 3.7 s of 1,215 s
- Timestamp jitter: 35 ms SD, 74 ms at the 95th percentile, 319 ms max. Slow
  clock wander of 373 ms across a session
- Consequence: an onset-timing tolerance tighter than about 75 ms is not
  supportable. H2 proposes 150 ms
- `pacer_radius` is a column in every accel CSV and is **empty in every row**

## BioPac

- **BN-RSPEC BioNomadix Respiration and ECG wireless system**, not an RSP100C.
  There is no operator-configurable gain or filter stage; bandwidth is fixed in
  hardware. **[NEEDS INPUT]** the datasheet bandwidth
- 2000 Hz raw, decimated to 25 Hz for analysis. Decimate with an anti-alias
  filter (`signal::decimate`), not by stride: the fixed hardware bandwidth is the
  only protection ahead of it and its value is not yet documented
- AcqKnowledge template defines **17 channels**, all at 2000 Hz:

  | # | Channel | Notes |
  |---|---|---|
  | 0, 1 | `Breath 1`, `Breath 2` | Volts. **1 = RIGHT seat, 2 = LEFT seat** |
  | 2, 3 | `Heart 1`, `Heart 2` | mV, same seat ordering |
  | 4 to 11 | `Digital (STP Input 0..7)` | 0 or 5 V, the eight trigger lines |
  | 12 | `Experiment Triggers` | derived sum of the eight digital lines |
  | 13, 14 | `Human Heart Rate` | BPM, calculation channels |
  | 15, 16 | `Respiration Rate` | BPM, calculation channels |

  The template governs display and derived channels only. Respiration is stored
  raw in Volts and is not filtered by it
- One `.acq` file per session, holding **both seats**. Filename encodes them as
  `L<leftID>.R<rightID>.acq`, with `0000` for an empty seat
- Two files hold two enrolled participants each, so channel selection must be by
  seat, not by variance. See `docs/discrepancies.md` B4
- **Trigger encoding is a nibble split, verified 2026-07-31.** The two rigs write
  to different physical wires, not merely different numbers:
  `Biopac_Right` (port `0xD030`, shift 1) uses the **low** nibble, bits 0 to 3;
  `Biopac_Left` (port `0xDFF8`, shift 16) uses the **high** nibble, bits 4 to 7.
  All codes fit in 4 bits, so two participants can share one recording without
  colliding. A dual file decodes to two complete independent sessions
- **An idle nibble floats high.** On a right-rig recording the untouched high
  nibble reads `0xF0`, so `Experiment Triggers` idles at 240 and trial start
  (code 10) appears as **250**. Decode by masking the rig's nibble, never by
  dividing by the shift and never by subtracting a global idle: dual-occupancy
  files have no single idle level
- The setup verification cascade writes trial codes before session start. Drop
  everything before the session-start code (1)
- No absolute clock. Aligned by matching trial-start triggers to software trial
  onsets in order, with linear drift correction
- Drift is roughly 384 ms per session, close to the 373 ms of browser clock
  wander, so the correction is largely absorbing browser timing rather than
  acquisition hardware error

## Trigger vocabulary

Codes 1 session start, 2/3 Block 2 start/end, 4/5 Block 3 start/end, 6/7 Block 4
start/end, 8/9 Block 5 start/end, 10 trial start, 12 trial end, 13 session end.

**Code 11 (condition onset) is never emitted during a session.** Removed because
it disrupted pacer animation timing. Expect two codes per trial, not three.
Condition onset is reconstructed as trial start plus two baseline breaths.

Code 11 does appear in recordings, but only from `sendTestCascade`, the setup
verification sweep that fires all 13 codes before session start. Dropping
everything before the session-start code removes it. Verified: after that drop,
code 11 count is zero in every session checked.

Trial-count checks must tolerate a repeated block code. Participant 3997 emitted
code 7 (Block 4 end) twice.

Code 0 is the line-clear, not a marker.

## Pacer

Deterministic and reconstructed analytically. From `breathUtils.js`:

```js
getPacerRadius(t, startMs, periodMs)
  = (1 - Math.cos(2 * Math.PI * (t - startMs) / periodMs)) / 2
```

`startMs` is a trough (fully exhaled), matching how breath onset is defined.
After band-passing this is a pure sinusoid at `1/periodMs`.

## Offline signal processing

Offline settings are authoritative. The live settings exist only to drive the
participant's on-screen preview.

- Band-pass each acceleration axis 0.05 to 1.0 Hz
- Combine by calibrated weights, then carry **two filtered copies, not one**: a
  detection copy band-passed 0.05 to 0.6 Hz and a measurement copy band-passed
  0.05 to 2.0 Hz. Extrema are located on the detection copy and snapped onto the
  measurement copy before any time or amplitude is read. A single 0.6 Hz copy
  symmetrises the waveform and pushes extrema late: worst synthetic trough error
  293 ms at 0.6 Hz against 199 ms at 2.0 Hz. See prereg Section 5.1 step 7
- 4th-order Butterworth, applied forwards and backwards, zero phase, with
  15 s odd-reflection padding on every pass
- **Onset detection lives in `R/onsets.R` and is shared.** The same function with
  the same parameters runs on both devices and feeds both the internal pilot
  variance estimation and every confirmatory analysis. Per-device tuning is not
  permitted: it would inflate exactly the agreement H2 exists to test. Minimum
  prominence 0.4 normalised, minimum separation 1 s, refined onto the measurement
  copy within 0.5 s. Detected **once on the continuous session**, then assigned to
  blocks by time, because a 16 s trial cannot settle a 0.05 Hz corner
- Everything on a common 25 Hz grid
- Calibration weights fitted against the **reconstructed pacer** on the Block 1
  window only, never against the BioPac signal. The BioPac-target fit is retained
  as a sensitivity analysis and labelled an upper bound
- **Belt-to-pacer offset** searched over plus or minus 2000 ms. NOT device lag:
  it also contains participant anticipation of the pacer, which is negative, so
  negative values are expected rather than anomalous. Flag only beyond plus or
  minus 1000 ms. Decomposed per breath in prereg Section 5.1
- Lag correction applied uniformly. The software computes some trial-level
  agreement measures with correction and others without; recompute everything
  consistently

**Three candidate calibration models offline, not six.** `breathUtils.js`
`fitBestModel` defines six (`mlr` and `pca`, each on a wide 0.05 to 1.0 Hz or a
tight 0.10 to 0.4 Hz band, `mlr` also with a 0.6 Hz smooth). **The three
tight-band variants are not used offline.** A 0.4 Hz cutoff sits barely above the
respiratory fundamental, so it symmetrises every breath and biases extremum
timing. Measured on participant 14542, whose winner under the old rule was the
tight variant: median duty cycle pinned at 0.48 to 0.55 in every block regardless
of true morphology, while the stretch belt on the same breaths read 0.43 to 0.47.
Dropping it also makes participants comparable, since a tight-band participant and
a wide-band participant were not running the same measurement. See prereg
Section 5.1 step 5.

The offline candidate set is therefore `mlr`, `mlr` with a 0.6 Hz smooth, and
`pca`, all on 0.05 to 1.0 Hz. `R/calibration.R` keeps the dropped band recorded as
`CALIB_BAND_DROPPED_TIGHT` for the record.

**In the live software only four of its six can ever win**: the PCA branch passes
the same column three times, so it is always singular and always skipped. See
`docs/discrepancies.md` B7. The offline label may therefore differ from
`belt_sessions.calib_model_label`. The offline one is authoritative for EH3 and
`selected_model_freq`.

Under collinear axes the candidates often score within noise of each other, so
`fit_calibration` also returns `model_margin` (winner minus runner-up). On the
internal pilot that margin had a median of 0.013 and 17 of 18 participants
selected the same model, so the selected label is close to arbitrary. EH3 is only
interpretable where that margin is meaningful. See C6.

## Design facts

- Block 3 is 3 conditions x 3 repetitions, shuffled per participant by
  Fisher-Yates. Not nine distinct rates, and **not counterbalanced**: there is no
  rotation across participants. Change is plus or minus 25% of the 4000 ms
  period, which is asymmetric in rate (15 bpm to 20 or 12)
- Condition onset is computed, not measured: trial start plus 8000 ms
- Block 4 ratings are confidence (6-point) and alertness (6-point, worded as
  activation in the software)
- QUEST: Weibull, slope 3.5, guess 1/3, lapse 0.02. Prior mean log10(0.5 s),
  SD 0.25 log units. 46 log-spaced levels from 0.1 to 2.0 s
- Stopping: both posterior SDs below 0.10 log units with at least 10 updating
  trials each, or 60 Block 4 trials
- Trials arrive in shuffled blocks of 5: 2 on the less certain staircase, 2 on
  the other, 1 catch trial. Catch trials never update
- Inter-trial time exceeds task time, because trials are participant-initiated.
  **H6 must use elapsed wall-clock time, not trial index**

## Conventions

- Namespace dplyr explicitly: `dplyr::filter`, `dplyr::mutate`, `dplyr::select`
- Every R script opens with the standard package setup block, `packages` vector
  tailored to that script
- No em-dashes in drafted documents
- Brief, point-form responses. Plan before coding. Check in when uncertain
