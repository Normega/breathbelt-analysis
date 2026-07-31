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
| Fixation | `calib_fixation` | 800 ms | `FIXATION_DELAY_MS` |
| Calibration | `calib_breathe` | 16,000 ms paced, plus ~3.1 s of model fitting | 4 cycles at 4000 ms, hard-coded loop |
| Free breathing, pre | `baseline` | 120,000 ms | no pacer |
| Phase 2, fixed rates | `phase2` | 9 trials | 3 conditions x 3 reps, 3000/4000/5000 ms |
| Phase 3, staircase | `phase3` | 20 to 60 trials | dual QUEST, participant-initiated |
| Free breathing, post | `post_baseline` | 120,000 ms | no pacer |

`inter_trial` and `idle` also appear as phase labels. Every trial in Phases 2 and
3 is 4 breaths: 2 at the 4000 ms baseline, then 2 at the condition period.

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

- 2000 Hz raw, decimated to 25 Hz for analysis
- One `.acq` file per session, holding **both seats**. Filename encodes them as
  `L<leftID>.R<rightID>.acq`, with `0000` for an empty seat
- Two files hold two enrolled participants each, so channel selection must be by
  seat, not by variance. See `docs/discrepancies.md` B4
- Trigger encoding differs by rig: `Biopac_Right` sends codes as-is at port
  `0xD030`; `Biopac_Left` sends `code * 16` at port `0xDFF8`. Decoders must
  branch on `belt_sessions.trigger_device`
- The setup verification cascade writes trial codes before session start. Drop
  everything before the session-start code (1)
- No absolute clock. Aligned by matching trial-start triggers to software trial
  onsets in order, with linear drift correction
- Drift is roughly 384 ms per session, close to the 373 ms of browser clock
  wander, so the correction is largely absorbing browser timing rather than
  acquisition hardware error
- **[NEEDS INPUT]** RSP100C gain and filter settings

## Trigger vocabulary

Codes 1 session start, 2/3 pre-baseline start/end, 4/5 phase 2 start/end, 6/7
phase 3 start/end, 8/9 post-baseline start/end, 10 trial start, 12 trial end, 13
session end.

**Code 11 (condition onset) is defined but never emitted.** Removed because it
disrupted pacer animation timing. Expect two codes per trial, not three. Condition
onset is reconstructed as trial start plus two baseline breaths.

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
- Combine by calibrated weights, then low-pass at 0.6 Hz
- 4th-order Butterworth, applied forwards and backwards, zero phase
- Everything on a common 25 Hz grid
- Calibration weights fitted against the **reconstructed pacer** on the Phase 1
  window only, never against the BioPac signal. The BioPac-target fit is retained
  as a sensitivity analysis and labelled an upper bound
- Device lag searched over plus or minus 2000 ms. Flag negative lag or lag above
  1000 ms
- Lag correction applied uniformly. The software computes some trial-level
  agreement measures with correction and others without; recompute everything
  consistently

Six candidate calibration models exist (`mirrorCalibration.js`), and the winner
varies by participant. That is why EH3 exists.

## Design facts

- Phase 2 is 3 conditions x 3 repetitions, randomised. Not nine distinct rates
- Condition onset is computed, not measured: trial start plus 8000 ms
- Phase 3 ratings are confidence (6-point) and alertness (6-point, worded as
  activation in the software)
- QUEST: Weibull, slope 3.5, guess 1/3, lapse 0.02. Prior mean log10(0.5 s),
  SD 0.25 log units. 46 log-spaced levels from 0.1 to 2.0 s
- Stopping: both posterior SDs below 0.10 log units with at least 10 updating
  trials each, or 60 Phase 3 trials
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
