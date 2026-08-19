# respkit

Reusable R tools for respiratory belt signal processing: ingest, clean,
detect breaths, and extract per-breath morphology.

Extracted and rebuilt from the Study 5 respiration pipeline
(`breath_pipeline.R` + `Intero2025_RespirationFunctions.R`), with the
paradigm-specific logic stripped out so the same code transfers to other
datasets. Nothing here knows about trials, conditions, pacers or session
structure.

---

## Status

Validated against 198 archived recordings (BIOPAC belt, 2000 Hz native,
~60 min each): **0 failures, 0.28 s per recording**. On the 158 recordings
graded `good`, the median breath rate is 16.2/min and the median duty cycle
(Ti/Ttot) is 0.432 — the textbook value for quiet spontaneous breathing, and
a quantity the original pipeline did not compute.

Test suite: `Rscript tests/test-respkit.R` — 427 assertions, no dependencies
beyond `signal`, including a property-based sweep over randomised recordings.
`R CMD build` then `R CMD check` passes with one WARNING (no `man/` pages; the
roxygen comments are written, `devtools::document()` generates them).
It has been through six adversarial review passes, five of which
mutation-tested the suite itself; see
[Defects found in respkit itself](#defects-found-in-respkit-itself).

The `.acq` reader has been run against the raw BIOPAC archive (175 files,
72 GB). Its trigger detection produces **edge-for-edge identical results to
the original pipeline** across 30 recordings. Reading a participant from
`.acq` and from the legacy `.rds` typically agrees to a median of 0.05
breaths/min and 0.001 duty cycle, though the worst pair seen differs by 1.3
breaths/min — the two paths carry different decimation histories, so treat
close agreement as the expectation rather than a guarantee.

The suite itself runs a 40-pipeline randomised sweep. Separately, and not part
of the suite, each review round also ran 180 randomised end-to-end pipelines,
a battery of degenerate and hostile inputs, and the full 198-recording archive
sweep.

Tested on R 4.5.0, 4.5.2 and 4.6.0: 427 assertions pass under each, and an
end-to-end fingerprint (sampling rate, breath count, summed duration, duty
cycle, amplitude, RVT, quality metrics, epoch coverage, spectral peak, trigger
edges) is **identical to ten decimal places across all three**. The `R >= 4.1`
floor is conservative and honest — no native pipe, no lambda shorthand, no
post-4.1 base function, and `%||%` is defined locally rather than relying on
the version base gained it in.

**Summary convention.** Every population figure quoted below is a *median of
per-participant medians*, and rate means `60 / median(duration)` — not
`summarise_breaths()`'s `rate_from_mean_duration` (14.97/min on this archive)
nor its `rate_bpm_mean` (16.76/min). The three differ, and every number here
depends on the choice.

### Checking that the tests can fail

```sh
Rscript inst/tools/mutation-check.R          # all 76 mutations
Rscript inst/tools/mutation-check.R <name>   # one
```

This breaks each behaviour the suite claims to protect, one at a time on a
throwaway copy, and reports whether the suite noticed. A mutation that
**SURVIVES** is a hole, and so is a **SKIP** — a mutation whose anchor text
has drifted guards nothing. Both fail the run. All 76 currently apply and are
caught.

Run it after adding a regression test: an audit of this package found 23
assertions that still passed with the code they guarded broken, including the
one supposedly covering the prominence definition that this README devotes a
section to. Asserting that a test would fail is not the same as checking.

The harness verifies an unmutated copy passes, and counts the assertions that
ran, before trusting any result — the first version of it resolved the package
root from the working directory, so the suite never loaded the mutated code,
aborted instantly, and every mutation was scored "killed". A harness that
reports perfect coverage while testing nothing is the exact failure it exists
to catch.

---

## Install

```sh
R CMD INSTALL respkit          # only hard dependency is `signal`
```

Or work from source without installing:

```r
for (f in list.files("R", "[.]R$", full.names = TRUE)) source(f)
library(signal)
```

Function documentation is written as roxygen comments but `man/` is not
committed. Run `devtools::document()` once if you want `?resp_analyse` to
work; `NAMESPACE` is hand-maintained and will be overwritten by that call, so
check it afterwards.

## Quick start

```r
library(respkit)

rec <- resp_read_rds("data/rds/10018.rds")   # legacy files are converted automatically
res <- resp_analyse(rec)

head(res$breaths)     # one row per respiratory cycle
res$features          # one-row summary
res$quality$quality   # "good" / "degraded" / "unusable"

plot_resp(res$measure, detection = res$detection, from = 100, to = 160)
plot_breaths(res$breaths)
```

With task windows:

```r
eps <- resp_epochs(onset = trials$start, offset = trials$stop,
                   lag   = 0.2,               # belt transduction latency
                   trial = trials$number, condition = trials$condition)

res <- resp_analyse(rec, epochs = eps)
res$features    # one row per window, with coverage_frac and n_breaths_partial
```

Starting from a raw BIOPAC file:

```r
resp_acq_channels("P01.acq")                  # see what is in there
rec <- resp_read_acq("P01.acq", channel = 1, id = "P01",
                     trigger_channel = 13, trigger_values = c(1, 16))
resp_write_rds(resp_downsample(rec, 25), "data/rds/P01.rds")
```

If that returns no events, read the message: on much of the BIOPAC archive the
trigger line idles at 240 rather than 0 and delivers codes 1–8 as 241–248. The
message names the idle value; pass it, and do **not** raise `trigger_max`,
which would report the idle stretches themselves as triggers.

```r
rec <- resp_read_acq("P01.acq", channel = 1, id = "P01",
                     trigger_channel = 13, trigger_idle = 240)
```

The archive is mixed — some recordings idle at 0 and some at 240 — so for a
batch loop use `trigger_idle = "auto"`, which takes the level from each file
and records the number it resolved to in `resp_provenance()`:

```r
rec <- resp_read_acq(f, channel = 1, trigger_channel = 13, trigger_idle = "auto")
```

---

## Architecture: acquisition is separate from analysis

Everything the package knows about file formats, channel numbering and
trigger codes lives in one file, `R/io.R`. Nothing in the signal-processing
path calls into it. Verified by extracting the call graph:

```
  recording.R  <- the container everything else speaks
       |
  resample.R  filter.R  clean.R          preprocessing
       |
  detect.R  ->  breaths.R  ->  features.R  ->  epoch.R    analysis
       |
  quality.R    plot.R                          assessment
       |
  pipeline.R   <- resp_analyse(), the one-call orchestrator

  io.R  ------> recording.R   (one direction only)
```

`io.R` depends on `recording.R`. The reverse never happens: **delete `io.R`
entirely and the analysis path still runs** — checked, not assumed. The one
exception is a convenience, not a dependency of the analysis: `resp_analyse()`
accepts a file path and calls `resp_read_rds()` for it, so that input mode
alone needs `io.R`. Passing a `resp_recording` does not. Trigger
and channel vocabulary appears 81 times in `io.R` and essentially nowhere
else.

### Using it with another acquisition system

The whole contract is one object:

```r
resp_recording(signal, fs, id, units, fs_native, t0, events, meta)
```

Write a function that returns one and the entire package works — no
subclassing, no configuration, no edits. `inst/examples/adapters.R` has
runnable adapters for a plain CSV, a file with its own timestamp column
(deriving the true rate from it, and resampling if the interval jitters), and
an arbitrary digital trigger channel via the exported `trigger_edges()`.
All three produce byte-identical analysis output from the same data.

Triggers are just an `events` data frame with a numeric `time` column in
seconds. respkit never interprets the codes; you decide what they mean and
build windows from them with `resp_epochs()`.

The one rule that matters: **`fs` must be the rate the samples are actually
at**, never a nominal figure from an unverified header. That is the defect
this package was written to fix, and it is silent.

Three defaults are calibrated to a chest belt and need checking on other
transducers: `polarity` (a nasal thermistor falls on inhalation — see
`resp_polarity()`), the `iqr_*` amplitude thresholds in `resp_quality()`
(in your signal's units, so meaningless on another scale — the frequency,
flatline and saturation tests are scale-free), and the rate ceiling implied
by `detect_band` and `min_distance_s` (36 and 40 breaths/min respectively).

## What is in the box

| File | Provides |
|---|---|
| `recording.R` | `resp_recording` container, `resp_time`, `resp_slice`, provenance |
| `io.R` | `resp_read_rds` / `resp_write_rds`, `.acq` reader, legacy converter |
| `resample.R` | `decimation_stages`, `resp_decimate`, `resp_downsample` |
| `filter.R` | `resp_filter` — zero-phase, reflection-padded, NA-tolerant |
| `clean.R` | `resp_despike`, `resp_clip`, `resp_detrend`, `resp_normalise`, `resp_preprocess` |
| `detect.R` | `find_extrema_prominence`, `find_extrema_zerocross`, `peak_prominence`, `enforce_alternation`, `resp_detect` |
| `breaths.R` | `breath_table`, `resp_polarity`, `flag_breaths` |
| `features.R` | `summarise_breaths`, `resp_variability`, `resp_rate_series` |
| `epoch.R` | `resp_epochs`, `epoch_breaths`, `epoch_features` |
| `quality.R` | `resp_quality`, `resp_flatline`, `resp_saturation`, `resp_psd` |
| `pipeline.R` | `resp_analyse` — the one-call entry point |
| `plot.R` | `plot_resp`, `plot_breaths` |
| `utils.R` | generic plumbing with no domain meaning |

Development tooling lives in `inst/tools/` (the mutation harness) and worked
examples in `inst/examples/` (`adapters.R`, `study5_migration.R`).

### The breath table

One row per trough → peak → trough cycle:

```
breath  i_start i_peak i_end   t_start t_peak t_end
duration inhale_dur exhale_dur duty_cycle ie_ratio rate_bpm
amp_inhale amp_exhale amplitude baseline rvt flow_in flow_out
has_peak implausible
[bad_amplitude low_amplitude duration_outlier keep]  <- flag_breaths()
```

`duration` and `rate_bpm` reproduce what the original computed. Everything
else is new.

---

## Defects found in the original pipeline

Each of these was reproduced and measured, not inferred from reading.

### 1. Decimation silently returned the wrong sampling rate

`safe_decimate()` staged decimation through factors of at most 13, updating
the remaining factor with integer division:

```r
remaining <- remaining %/% step     # discards the remainder
```

The achieved factor is therefore almost never the requested one:

| requested | achieved | rate claimed | true rate |
|---|---|---|---|
| **80** (this study) | **78** | 25.0 Hz | **25.641 Hz** |
| 20 | 13 | 100.0 Hz | 153.8 Hz |
| 50 | 39 | 40.0 Hz | 51.3 Hz |
| 100 | 91 | 20.0 Hz | 22.0 Hz |

The rate written into every `.rds` was the requested 25 Hz, so every time
derived from a sample index was 2.5% too long. Three downstream scripts each
rediscovered this and patched it differently: `Intero2025_BehaviourLedBreathAnalysis.R`
and `Intero2025_CreateCardiacRDS.R` each defined a private `compute_actual_q()`
that re-derived the true factor; `Intero2025_BreathingAdherence.R` called that
function without defining it; and `Intero2025_TrimContaminatedPhysio.R` did not
correct at all and wrote session-start indices computed at the wrong ratio.

**Fixed by** `decimation_stages()`, which factors `q` into primes and
recombines them so the product is exactly `q` (80 → 10 × 8). `resp_downsample()`
reports the rate it actually achieved and never claims the target.
`resp_read_legacy_rds()` reconstructs the true rate of existing files and
warns.

### 2. Filtering left a large edge transient

R's `signal::filtfilt` does not pad. On a signal with a realistic DC offset,
a 0.05–1 Hz band-pass leaves an error of up to **9.7 units against an
oscillation amplitude of 1** across the first 15 seconds — enough to swamp
peak detection entirely. The original masked this by discarding 120 s from
each end during quality screening, which works for hour-long recordings and
destroys short ones.

**Fixed by** reflecting the signal about its endpoints before filtering.
Same signal, same filter: maximum error over the first 15 s falls from 9.734
to 0.00002.

### 3. A tight low-pass biases peak timing and erases waveform asymmetry

The pipeline detected and measured on the same signal, band-passed to
0.05–0.4 Hz. That cutoff sits barely above the respiratory fundamental, so it
symmetrises every breath. On synthetic breaths with a known inspiratory
fraction:

| true duty cycle | measured at 0.4 Hz | measured with refinement |
|---|---|---|
| 0.25 | **0.403** | 0.274 |
| 0.40 | **0.456** | 0.406 |

The peak arrives systematically late — about 190 ms at a duty cycle of 0.4,
about 475 ms at 0.25 — and the bias scales with asymmetry, so it is largest
exactly where the shape carries the most information. Nothing in the filtered
signal reveals it.

**Fixed by** carrying two filtered copies. `resp_analyse()` detects on a
narrow band (`detect_band`, default 0.05–0.6 Hz) and then snaps each
extremum onto a wide-band copy (`measure_band`, default 0.05–2 Hz) before
measuring anything. Verified unfiltered, the detector recovers peak times
exactly (error 0.0000 s), so any residual error is attributable to the
filter rather than the detector.

### 4. Prominence — a correction to an earlier version of this document

**This entry previously claimed the original `compute_prominence()` was wrong.
It was not, on this data, and the explanation given was incorrect.** It is
left here rather than deleted because the correction is the useful part.

The original bounded each search at the nearest higher *detected local
maximum* rather than the nearest higher *sample*. That sounds like it would
widen the search window and inflate prominence, but it does not: any sample
higher than the peak must belong to a run whose own maximum is a local
maximum at least as high, so the two bounds coincide. Measured against a
brute-force implementation of the standard definition:

| data | peaks compared | disagreements |
|---|---|---|
| continuous, no tied values | 300 signals | **0** |
| rounded to 1 dp (many ties) | 300 signals | 202 |
| **the 198-recording archive, at the detection stage** | **155,861 peaks** | **0** |

On the archive the two rules give bit-identical prominences (maximum
difference 0, zero tied peak heights) and the same breath count at
`min_prominence = 0.4`. **No published Study 5
result is affected by this.**

The rules do genuinely diverge when peak heights are exactly equal, because
the original stopped at a peak of *equal* height while the standard definition
walks past it. That is reachable on quantised or heavily rounded data, not on
a filtered floating-point respiratory signal.

`peak_prominence()` is still worth having: it matches MATLAB `findpeaks` and
`scipy.signal.peak_prominences` exactly, it is tie-robust, and it runs in
`O(n)` rather than `O(n²)`. But those are the honest claims, not a correctness
bug in the original.

### 5. The zero-crossing detector depended on how the caller normalised

`find_extrema()` defines a breath cycle entirely by zero crossings, so it is
only correct when zero sits at the signal's centre — but it never centred the
signal itself. Robust (median) normalisation puts the median at zero, and for
asymmetric breathing the median sits well below the mean because the signal
spends longer near the bottom of each cycle. On 40 synthetic breaths with a
duty cycle of 0.4, a zero line displaced by 0.2 units left the crossings
intact but made the half-cycles unequal enough that the amplitude filter
**discarded 26 of the 40 breaths**.

**Fixed by** centring inside `find_extrema_zerocross()` (`centre = "mean"` by
default, matching Khodadad and NeuroKit2). 40/40 detected either way.

### 6. Flatline detection ran on the filtered signal

`assess_belt_quality()` tested for runs of identical values *after* a
zero-phase band-pass with a multi-second impulse response. A stuck ADC emits
literally identical samples; filtering smears them first.

**Fixed by** `resp_flatline()`, which runs on the raw signal and returns the
located runs, not just a percentage. `resp_saturation()` adds a rail check the
original had no equivalent of — a belt pinned at the end of its range produces
a plausible IQR and a plausible dominant frequency while clipping every
amplitude.

### 7. Spectral metrics came from a single unwindowed periodogram

One raw `fft()` of the whole recording. The variance of that estimate does not
fall as the recording lengthens, and rectangular windowing leaks power from
the strong respiratory peak across the whole band, biasing any band-power
ratio computed from it.

**Fixed by** `resp_psd()`, Welch's method with Hann windows and 50% overlap.

### 8. Synthetic troughs were inserted at trial boundaries

When a window contained fewer troughs than the paradigm expected,
`analyze_respiration()` inserted one at the window edge and treated the
interval from it as a measured breath duration. It is not one: its length is
set by where the experimenter placed the window. Because insertion was
triggered by a shortfall against the expected count, it fired precisely on the
trials where detection was worst and filled the gap with a number that looks
like data.

**Not reimplemented.** `epoch_features()` instead reports `n_breaths_partial`
and `coverage_frac` — the fraction of the window actually spanned by complete
cycles. A window at 0.4 coverage is not really measured, whatever its feature
values say, and now you can see that.

### 9. Smaller items

- `enforce_alternation()`'s documentation said it kept the most extreme event
  in a run; the code kept the one nearest the next opposite event. Both rules
  are now available and named, with `"extreme"` the default because if two
  peaks share a cycle, the cycle's peak is the higher one.
- `remove_baseline_median()` computed `median()` in a loop over every sample,
  `O(n·w)`. `resp_detrend(method = "median")` uses `stats::runmed`,
  `O(n log w)`.
- A single `NA` propagated across the entire output of `filtfilt`.
  `resp_filter()` interpolates gaps, filters, and restores them.
- `resp_clip()` is retained for compatibility, but clamping replaces an
  excursion with a flat plateau that a prominence detector may still accept.
  `resp_despike()` interpolates across artefacts instead, and runs before
  decimation, since the anti-alias filter smears a one-sample transient across
  many.

---

## Defects found in respkit itself

The first draft of this package was reviewed adversarially, with every
candidate defect reproduced in R before being accepted. Twelve were real and
are fixed; each has a regression test. They are listed because the same
mistakes are easy to make again, and because two of them would have produced
plausible-looking wrong numbers rather than errors.

**Silently wrong results**

- `epoch_breaths()` located rows by the value of the `breath` column instead
  of by position. `breath` numbers cycles within one recording, so it stops
  matching row position the moment a table is filtered, sorted, or row-bound
  across participants. Filtering first raised a confusing error; row-binding
  two participants assigned **half the breaths to the wrong windows with no
  warning at all**.
- `find_extrema_zerocross()` tested `x > 0` and `x < 0` separately, leaving a
  sample at exactly zero in neither class, so a crossing landing on it was
  invisible. On a quantised signal centred on its median — and the median of
  quantised data is itself a quantisation level, so this is common — the
  breath count **halved and the reported rate was off by a factor of two**,
  with every bogus breath passing QC. Extrema are now labelled by which
  half-cycle produced them rather than by the sign of their value.
- `refine_extrema()` used `which.max()`, which returns the first index of a
  tie, so every extremum snapped to the **left edge** of a plateau, undoing
  the centre convention `local_maxima()` establishes. On a clamped or
  saturating belt at the default window this read a true duty cycle of 0.40
  as 0.33.
- `resp_despike()` thresholded the first difference. An isolated spike
  produces two large differences, one in and one out, so this identifies the
  *transitions* and cannot say which side was the artefact. Flagging both
  sides meant a 40-unit spike at sample 1 left a **20-unit artefact at sample
  2** — the provenance line then reported the signal as cleaned. It is now a
  Hampel filter against a running median, which flags the offending samples
  themselves.
- `resp_rate_series(method = "constant")` stepped at cycle midpoints, so every
  value was carried half a breath late.
- `resp_psd()` omitted the factor of two that makes a one-sided spectrum
  integrate to the signal variance, halving every absolute power. Ratios such
  as `band_ratio` were unaffected.
- `resp_quality()` had no missing-data metric. Every other measure there
  tolerates gaps by construction, so a recording that was **56% absent graded
  `good`** with no flag. There is now an `na_pct` metric with thresholds.
- `resp_saturation()` summed the two rail counts, so a perfectly flat signal
  reported 200% saturated.
- `breath_table()` checked the upper index bound but not the lower. `sig[0]`
  returns a zero-length vector in R rather than erroring, so a stray zero
  index silently recycled a column and corrupted the times of *unaffected*
  breaths too.

**Crashes**

- `resp_decimate()` returned an all-`NaN` signal for a large prime factor.
  `signal::decimate` degrades before it fails — q=90 gives 33% amplitude
  error and q=100 gives 65%, both finite — so a finiteness check alone is not
  enough and the factor itself is now refused, with a smoothly factorable
  alternative named. `resp_downsample()` routes around such factors on its own.
- `resp_filter()` fell through to `signal::butter` with an empty cutoff
  vector when the only cutoff supplied was at or above Nyquist, dying with an
  internal error immediately after announcing the situation was handled.
- `resp_quality(by_segment = TRUE)` aborted outright on a segment with no
  finite samples — precisely the local dropout it exists to locate.

**Made visible rather than fixed**

- A cycle with no detected peak keeps a valid duration but is `NA` for every
  peak-derived column, so `duty_cycle_mean` had a smaller denominator than
  `n_breaths`. The cycle is still kept, but `has_peak` and
  `n_breaths_no_peak` now expose the difference.
- Refinement can snap two extrema onto the same sample, merging two cycles
  into one, and can select a sample as both a peak and a trough where the
  signal is flat. Both now warn, and the contradictory sample is discarded.

Two hypotheses that were investigated and turned out to be **fine**:
`peak_prominence()` matched a brute-force reference on 400 random tie-heavy
signals with zero mismatches, and `reflect_pad()` is a correct odd reflection
that introduces no discontinuity at the join.

### Second review pass

A second round audited the code written to fix the first, the four files never
previously examined, and — most usefully — the test suite itself by mutation
testing: deliberately breaking each behaviour the suite claims to protect and
checking that it actually fails. It found **23 mutants that survived**, i.e.
assertions that could not fail. Those have been replaced; the suite is now 249
assertions.

Worth singling out, because they are the mistakes that recur:

- **The flagship fix had no effective test.** Reverting `peak_prominence()` to
  the wrong definition — the one the README devotes a section to — did not
  fail a single assertion. The textbook example `c(0,5,0,3,0)` gives the same
  answer under both rules, because its two valley floors are equal. There is
  now an asymmetric case plus a brute-force cross-check over 150 signals.
- **Four assertions were tautologies.** One restated the implementation
  (`nrow(bt) == length(troughs) - 1`, which the constructor guarantees), one
  compared a quantity against itself (`Ti + Te` versus `Ttot`, identical by
  construction, and missing an `abs()` so a negative error passed), and one
  re-derived the very expression the function used to set the flag it was
  checking.
- **`resp_epochs(lag =)` was never tested with a non-zero lag**, despite the
  quick-start promoting `lag = 0.2`. A version that ignored the argument
  entirely passed the whole suite.
- **Two documented numbers were wrong.** A `freq_hi` of 0.35 Hz would have
  flagged 8 recordings, not the 19 claimed — 19 was the count breathing faster
  than 21/min, which is a different quantity from the one the threshold is
  applied to. And the duty-cycle inflation table quoted figures from a
  configuration that was never stated; the reproducible numbers, with the
  configuration now given, are 0.403 and 0.456 rather than 0.450 and 0.480.

Defects fixed in this round, beyond the test suite:

| | |
|---|---|
| `breath_table()` read `detection$fs` and discarded it | measuring a detection against a recording at a different rate scaled every duration by the ratio, silently — and the range check could not catch it, because the mismatched recording is *longer* |
| `resp_read_legacy_rds()` hard-coded `t0 = 0` | the 9 trimmed archive files were returned on a different clock from the other 189 with nothing to distinguish them, an offset of 119–4108 s |
| `resp_recording()` coerced a factor `time` column with `as.numeric()` | trigger times of 120.5, 300.25, 600 s became 1, 2, 3 — still plausible-looking seconds |
| `dom_lo` never reached `quality_by_segment()` | the per-segment path still searched from 0.05 Hz and condemned ~17% of all segments, contradicting the whole-recording verdict from the same call |
| `resp_despike()` scaled against `mad(resid)` | a running median returns an actual sample value, so the residual is exactly zero wherever the signal is monotone — 84% of samples on a real trace. The scale collapsed and the flagged fraction swung 0–15% with no stable relation to `threshold`. Now scaled against `mad(diff)` |
| mirror padding in `resp_despike()` | made the first and last sample the largest residuals in the recording; both were rewritten on 25 of 25 real traces. Now a robust linear extrapolation |
| `resp_downsample()` rerouted on `max_factor` | traded an exact rate for an inexact one to dodge a stage it already considered safe; every one of 19 measured substitutions made the achieved rate worse |
| `decimation_stages()` length guard used `max(stages)` | a signal could pass and then starve a later stage, giving finite output 79% wrong |
| `resp_quality()` thresholds could not be set to `NA` | the documented calibration workflow — disable the amplitude tests, inspect the distribution, choose a cut — crashed |
| `resp_rds_is_legacy()` used `obj$schema` | `$` partial-matches, so a legacy file with any field starting `schema` skipped the sampling-rate correction |
| `resp_slice()` kept NA-time events as all-NA rows | the event was neither kept nor dropped, and its other columns were wiped |
| `as_resp_recording()` silently ignored a contradictory `fs` | now an error |
| `enforce_alternation()` deleted a whole run when its values were all NA | from the function whose job is to guarantee alternation |
| `peak_prominence()`, `refine_extrema()` crashed on NA | with messages naming neither the argument nor the cause |
| unknown fields dropped on read | `side`, `abcode` and similar are now routed into `meta` |
| `empty_breath_table()` referenced undefined variables | introduced by the previous round's fix; broke every empty-table path |

Found by property-based fuzzing rather than review: band-passed white noise
was graded `good` with 43 breaths (fixed by enabling `band_ratio_min`), and a
signal constant to machine precision produced a breath with **negative
amplitude**, because high-passing a constant leaves floating-point error and
normalising divides by a scale of the same order. Both are now caught.

### Third review pass

An independent review with no prior context found one real defect in the
analysis path and a large number of gaps in the test suite.

**`coverage_frac` overstated coverage.** It summed whole cycle durations, but
under the default `rule = "start"` a breath is assigned by its opening trough
alone, so a cycle beginning just before the window closed contributed its
entire length. A window holding one 5 s cycle that overlapped it by 0.1 s
reported 0.83 coverage instead of 0.017. Across 10 s windows on 4 s breaths
this overstated coverage by 0.095 on average and reported a full 1.0 for 98 of
200 random offsets — in the one metric whose entire purpose is to say when a
window is *not* really measured. Cycles are now clipped to the window bounds.

`resp_read_acq()` also could not match a channel name case-insensitively:
`grep()` silently discards `ignore.case` when `fixed = TRUE`.

The larger finding was in the tests. A second mutation round covering 38
behaviours found 23 that no assertion protected, including several this
document credits to earlier rounds: the zero-crossing detector's mean-centring
(only ever exercised on an already-centred signal), the Hann window and
overlap in `resp_psd`, the `na_degraded` threshold, and the distinction
between the three `epoch_breaths` rules. `rmssd` and `cv` could both be
replaced by `sd()` and nothing failed. A dozen documented arguments —
`pad_s`, `min_breaths`, `prefix`, `tol`, `digits`, `trim_s`, `target_fs`,
`despike`, `min_prominence` — were inert as far as the suite could tell. All
are now covered, and the mutation harness has grown to 55 mutations.

Two of the tests written for those gaps were themselves too weak on first
attempt: a spectral-leakage test placed its tone on an exact FFT bin, where a
rectangular window leaks nothing either, and a clipping test used data whose
outliers sat exactly at the percentile bounds. Both were caught by the harness
before being trusted, which is the argument for having it.

### Running against the raw .acq archive

`resp_read_acq()` was the last module never executed — reviewed twice by
reading, never run. Executing it against the 175-file BIOPAC archive found a
defect that no amount of reading had:

**The trigger detector missed real session starts.** An earlier round had
rewritten it to fire only on a transition from *idle* to a valid code, to stop
a parallel port settling through intermediate values from producing three
events. On real hardware that is wrong. One recording's trigger line idles at
code **3** for its first 205 seconds and then steps straight to code **1** —
the genuine session onset, and the anchor the entire alignment rests on. A
zero-to-valid rule misses it silently.

An edge is now the first sample of any run holding a different valid code,
which is what the original did. Verified across 30 recordings: **every edge
identical to the original**, session starts included. The settle-artefact
concern is real but belongs in a separate `min_pulse_s` filter, off by default
— on the one busy trigger line in the archive, genuine pulses last about
1000 ms while settle artefacts last 5 to 80 ms.

The same exercise found a denormal float (2.05e-289) sitting in one
recording's trigger channel, which passed a bare non-zero test and was
reported as a trigger. Codes are now required to be at least 1, as the
original also required.

The edge logic now lives in `trigger_edges()`, split out so it can be tested
without a `.acq` file or a Python toolchain; the suite exercises it on
synthetic vectors reproducing the patterns actually observed in the archive.

### Fourth review pass

The debounce was keeping the wrong member of a cluster. A parallel port
settles through intermediate values *before* it reaches the code the
experiment sent, so the first edge of a cluster is systematically the
artefact — and "collapse to the first" is exactly what it did. On a 100 ms
code-1 pulse preceded by 1 ms settle runs of codes 3 and 4, **it kept code 3**:
wrong code, wrong time. Across 30 archive recordings the old rule discarded
346 of 5311 edges, 197 of which were held *longer* than the edge that
suppressed them. Compounding it, the 1 s default sat inside the real event
distribution — genuine inter-event gaps on this archive go down to 0.778 s.

Debouncing now keeps the **longest** pulse in a cluster, greedily, the same
way `enforce_min_distance()` resolves peaks; and it is **off by default**,
because silently dropping a real trigger is worse than reporting an extra one.
Verified: 22 of 22 recordings still edge-for-edge identical to the original,
where the old default would have dropped 41 real edges.

Also fixed in this round: a lone non-finite sample *inside* a pulse split the
run in two, deleting the true onset when `min_pulse_s` was set (values are now
filled forward, not zeroed); `resp_read_acq()` returned no events and said
nothing when every code failed the filters, which happens on 15 of 30 archive
files whose trigger word carries a stuck upper nibble (240–248), so it now
reports what it saw and why; `epoch_features()` silently shadowed a computed
feature when a window column of the same name was carried through
`resp_epochs()`, and returned `NULL` rather than a zero-row frame for empty
`epochs`; `window_coverage_s` was the *unclipped* duration sum sitting one
column from the clipped `coverage_frac` and contradicting it; an "unusable"
verdict could carry an empty note when `na_degraded` was disabled; and
`plot_resp()` still collided on `type`.

The test findings were larger than the code ones. A second mutation round
covering 58 subtle *numerical* changes — rather than whole-feature deletions —
found **45 survivors**, four of which let a visibly destroyed function pass the
assertion bearing its name. Reversing `pmin`/`pmax` in `resp_clip()` collapses
the output to a single constant, and the test compared it against the *input's*
maximum, so total destruction passed. `resp_saturation`'s guard was one-sided
(`<= 100`), written against the historic 200% bug and blind to a rail test that
reports 0%. `enforce_min_distance` was never tested at the boundary, where an
inclusive/exclusive slip halves the breath count. And three assertions were
outright tautologies, including one whose stated claim was false for the signal
it ran on. All are now covered, and the harness has grown to 64 mutations.

### Fifth review pass

**The mutation harness was itself unfalsifiable.** Five of its mutations no
longer matched the source — their anchor text had drifted when the code was
rewritten — and the harness counted only `SURVIVED`, never `SKIP`. It reported
*"No survivors: every mutation was caught"* while silently testing nothing in
the two regions most recently changed, which are precisely the regions most in
need of guarding. `SKIP` now fails the run, and all five are re-anchored. This
is the second time this tool has produced a confident, meaningless pass; both
failures were in the harness rather than the package.

The worst code defect was in `flag_breaths()`. The duration-outlier test was
guarded with `mad > 0`, but durations are differences of floating-point sample
times, so on regular breathing the MAD is not zero — it is a residue near
1e-15. The guard passed, the rejection threshold became a few femtoseconds, and
**about half of all breaths were flagged as outliers.** `duration_sd`,
`duration_cv` and `duration_rmssd` collapsed to ~1e-15, destroying the
variability measures on exactly the recordings where regularity is the finding
— a paced-breathing protocol would report zero variability by construction —
and dragging `coverage_frac` down with them. The guard is now a relative
epsilon, the idiom `cv()` already used. It reached 0 of 198 whole archive
recordings, but 1 in 10,493 real 60-second windows, so per-trial analysis was
exposed.

Also fixed: `resp_quality()` tested the *whole* recording for finite samples
then worked on the *trimmed* span, so a belt disconnecting early killed the
filter — and any batch loop with it — on precisely the dropout it exists to
grade; `min_pulse_s` was silently inert whenever `fs` was omitted, since the
placeholder rate of 1 Hz rounds any sub-second threshold to zero; and filling
non-finite samples forward stretched a run's measured length across the filled
region, letting a 3-sample artefact pass a 50-sample floor and outrank genuine
pulses in the debounce weighting.

A third mutation round of 89 subtle changes found 49 more confirmed gaps,
almost all at boundaries: **no threshold in the package was tested at exact
equality anywhere**, and the reported columns `n_breaths_partial`,
`window_coverage_s`, `na_pct` and `usable_duration_s` were asserted only for
existence. Both are now covered by value. The `Ti + Te == Ttot` assertion was
still an algebraic identity that holds for arbitrary numbers — it is now
checked against the synthesised inspiratory fraction instead.

Verified clean this round, after direct attack: `debounce_edges()` over 5,000
randomised cases (no gap violations, no reordering, no non-determinism, and
every dropped edge suppressed by one at least as long); forward-filling
identical to a drop-the-NAs reference over 3,000 vectors and on a real 6.09
million-sample trigger channel; and `epoch_features()` matching an independent
brute-force reference over 400 randomised tables with zero mismatches.

### Sixth review pass

Run against the raw `.acq` archive and the legacy `.rds` archive together,
rather than against synthetic signals alone.

**`resp_despike()`'s threshold was not sampling-rate invariant, and the default
pipeline despikes at the native rate.** The residual was compared against
`mad(diff(v))` — the spread of *one-sample* differences, which shrinks as
roughly 1/fs because neighbouring samples lie closer together the faster you
sample — while the residual itself was measured against a median window fixed
in *seconds*, which does not shrink at all. So `threshold = 10` was a far
stricter test at a high rate than a low one. One recording, decimated to a
range of rates and despiked at each:

| fs (Hz) | 2000 | 1000 | 400 | 200 | 100 | 25 |
|---|---|---|---|---|---|---|
| flagged | 7.234% | 3.847% | 0.554% | 0.100% | 0.018% | 0.004% |

An 1800-fold swing driven by nothing but the sampling rate. That was not
academic, because `resp_preprocess()` and `resp_analyse()` both despike at the
**native** rate deliberately — decimation's anti-alias filter smears a
one-sample transient and makes it unrecoverable afterwards — so the shipped
default path was the 2000 Hz one. Across 24 archived `.acq` recordings it
rewrote a **median of 6.0% of samples, worst 10.3%**, while the documentation
promised 0.009% on a recording graded `good`. The effect on reported features
was small (median duration moved by under 0.4%), so this was not producing
wrong answers — but it silently rewrote a twentieth of every raw recording, and
it made a user-facing parameter mean different things at different rates, which
is the exact defect class this package exists to eliminate.

The scale is now measured at a lag of half the median window, so both terms
span the same duration. That alone costs sensitivity, so the default
`threshold` was recalibrated against it; the two were chosen together:

| rule | min spike @25 Hz | false pos @25 Hz | min spike @2000 Hz | false pos @2000 Hz |
|---|---|---|---|---|
| lag-1, `threshold = 10` (old) | 1.25 SD | 0.000% | 0.75 SD | 1.76% |
| lag-h, `threshold = 10` | 3.50 SD | 0.000% | 3.25 SD | 0.000% |
| **lag-h, `threshold = 3`** (new) | **1.25 SD** | **0.000%** | **1.00 SD** | **0.000%** |

The new default matches the old sensitivity at both rates, removes the rate
dependence, and stops destroying the 1.76% of a clean 2000 Hz trace the old
rule took. On the 198-recording legacy archive the flagged fraction still
tracks the quality grade — median 0.005% on `good`, 0.137% on `degraded`, 4.9%
on `unusable` — and `resp_despike()` now **warns** above `warn_frac` (1% by
default), which fires on 20 of 198 recordings, 19 of them independently graded
`degraded` or `unusable`. The old advice to "inspect it rather than raising
`threshold`" previously had nothing to trigger it.

If you have an analysis pinned to `threshold = 10`, it no longer means what it
did: pass `threshold = 3` to reproduce the old behaviour at any rate.

A side effect worth knowing: the upper bound on `window_s` is gone. The scale
now widens with the window, so a clean trace survives every window from 0.2 s
to 4 s (0.000% flagged at each); under the lag-1 scale a 2 s window took 7.0%
of it. The lower bound is unchanged and is what sets the 0.3 s default.

**`.acq` trigger reading failed on most of this archive, and the message
recommended a fix that makes it worse.** The trigger channel idles at **240**,
not 0, on two of the first three files — 94% of the recording — with codes
arriving as 241–248. The default `trigger_max = 200` therefore returned zero
events. The message suggested raising `trigger_max` or subtracting the offset;
raising it is actively wrong, because the idle stretches then satisfy
`code >= 1` and are reported as triggers, turning 179 real edges into 359. And
there was no way to subtract the offset, since `resp_read_acq()` reads the
channel internally. There is now a `trigger_idle` argument, the message names
the modal value to pass and says explicitly not to raise `trigger_max`, and
the offset is recorded in provenance.

The archive is mixed — some files do idle at 0 — so the default is unchanged
and `trigger_idle = "auto"` takes the level from each file, which is what a
batch loop wants: one hard-coded value silently loses every trigger in
whichever half of the archive it guessed wrong. Auto takes the modal sample
value, since a trigger line spends nearly all its time idle, and declines with
a warning when the commonest value covers less than half the channel rather
than inventing an offset from noise. Across eight recordings it recovers 202,
202, 202, 104 and 0 events where the previous code returned 0 on every file
that idled high.

**`resp_analyse()` never checked polarity.** `resp_polarity()` was written,
exported, and called by nothing. An inverted transducer produces a complete and
entirely plausible breath table in which Ti and Te are swapped, duty cycle is
its own complement, and `flow_in`/`flow_out` exchange meanings. Three of 24
`.acq` recordings and one legacy participant came back with a median duty cycle
above 0.5, the signature of exactly that. `resp_analyse()` now returns the
verdict as `$polarity` and warns when it confidently contradicts the argument,
computed from the breath table it has already built rather than by building a
second one.

**Duty cycle carries a bias that grows with breathing rate.** Refining onto a
wider measurement copy — the fix from the third review pass — removed most of
the low-pass symmetrisation but not all of it, and the remainder is not a
constant offset. At a fixed true duty of 0.30, varying only the rate:

| rate (/min) | 7.5 | 10 | 12 | 15 | 20 | 24 | 30 |
|---|---|---|---|---|---|---|---|
| measured | 0.310 | 0.314 | 0.316 | 0.320 | 0.327 | 0.336 | 0.340 |

Any manipulation that also changes breathing rate therefore produces a
duty-cycle change of the same sign for free. It is not an artefact of the
synthetic waveform's apex: a smooth phase-warped sine with no derivative corner
still shows +0.030 at a true duty of 0.25. It shrinks as `measure_band`'s upper
edge rises (+0.046 at 2 Hz, +0.030 at 3 Hz, +0.022 at 5 Hz, +0.014 at 15 Hz),
but the default stays at 2 Hz because widening is not free: with cardiac ripple
at 20% of the respiratory amplitude, widening makes duty *worse* (0.320 at 2 Hz
against 0.379 at 5 Hz) as the heartbeat starts displacing the peak. This is now
documented under `?resp_analyse` with the trade-off, and the suite has a
tripwire on the bias magnitude and on its growth with rate.

**The property sweep tested structure, not accuracy.** It generated known
durations, duty cycles and amplitudes for 40 randomised recordings and then
never compared the recovered values against any of them — only invariants
(cycles tile, duty lies in (0, 1), peaks fall inside their own cycle). All of
those hold perfectly well for a pipeline that is systematically wrong, which is
how the duty-cycle bias survived the entire suite. The sweep now checks
recovered duration against ground truth, and there is a separate deterministic
accuracy block: a constant scale error — the decimation defect this package
exists to prevent — would previously have been caught nowhere in the suite.

Also removed: an unreachable fallback branch in `resp_psd()` (verified
unreachable for every input from n = 1 up; unreachable code is worse than
absent code here, because the mutation checker cannot distinguish the two), a
dead local in `resp_detrend()`, a no-op `fs_native` assignment in
`resp_preprocess()`, a no-op `units` assignment in `resp_filter()`, and four
`importFrom` entries for functions the package never calls. The `.acq` trigger
logic is now a testable internal, `acq_trigger_events()`, so `trigger_idle` is
checked for effect rather than for existing — the mutation harness caught that
gap immediately, and then caught the stale anchor the refactor created.

The harness has grown to 76 mutations, all applied and all killed. Two of its
existing anchors drifted when this pass edited the code they pointed at; the
SKIP check added in the fifth pass caught both immediately.

## Features the original did not compute

The original detected both peaks and troughs but derived every feature from
trough times alone. Peaks were used only to locate trial onsets. New:

- **Inspiratory and expiratory duration** (Ti, Te) and **duty cycle** Ti/Ttot,
  the classic index of respiratory drive timing
- **Amplitude** — peak-to-trough excursion, separately for the inspiratory and
  expiratory limbs
- **RVT** (respiratory volume per time), the standard regressor in the
  physiological-noise-correction literature
- **Mean inspiratory and expiratory flow** (`flow_in`, `flow_out`)
- **Baseline** — end-expiratory level per breath, and its drift across a
  window, which is how belt slippage and posture change announce themselves
- **Variability**: CV and RMSSD of duration and amplitude, alongside the
  slope the original computed
- **Continuous rate and RVT series** (`resp_rate_series`) for correlating
  against another continuous measure

Two notes on quantities that were computed:

- The original's `mean_bpm` was `60 / mean(duration)`. Averaging the
  instantaneous rates instead gives a different, always larger, number when
  durations vary. `summarise_breaths()` returns both
  (`rate_from_mean_duration` and `rate_bpm_mean`) so the choice is explicit
  and old results stay comparable.
- The original's `ibi_slope` regressed duration on ordinal breath position.
  `duration_slope_per_breath` reproduces it; `duration_slope_per_s` regresses
  on elapsed time. They diverge exactly when it matters: if breaths lengthen,
  more time passes per breath, so a constant per-breath drift is a
  decelerating per-second drift.

---

## Migrating existing Study 5 data

`resp_read_rds()` detects the old list format and converts it, correcting the
sampling rate and warning that it did so:

```r
rec <- resp_read_rds("Results/rds/10018.rds")
resp_provenance(rec)
#> [1] "imported from legacy RDS"
#> [2] "legacy fs correction: 25 Hz -> 25.641 Hz (requested q=80, achieved q=78)"
```

Pass `correct_fs = FALSE` to reproduce an old analysis exactly, bugs included.

Two legacy fields need care:

- **`start_indices`** was stored in native-rate samples in untrimmed files but
  in downsampled samples in files a later script had trimmed, with the presence
  of `trim_offset_s` as the only discriminator. The converter reads them under
  whichever rule the discriminator implies and stores seconds in `events`.
  Check them against a plot before trusting them. Note that
  `Intero2025_TrimContaminatedPhysio.R` wrote those indices using the *nominal*
  ratio, so for trimmed files they carry an error of roughly 2.5% of the
  elapsed time — around 140 s at a session starting 5600 s in.
- **`fs`** is corrected as described above. Any timing you have already
  published from these files is 2.5% short unless it went through
  `compute_actual_q()`.

---

## Choosing parameters

The defaults were tuned against synthetic signals with known ground truth and
against the 198-recording archive. The measurements below are worth knowing
before you change anything.

**`measure_band` upper cutoff.** Measured on 60 synthetic breaths of 4 s with
a true duty cycle of 0.35, at 50 Hz with noise 0.05, decimated to 25 Hz,
detected on 0.05–0.6 Hz, averaged over six seeds:

| upper cutoff | duty-cycle bias | sd | peak timing bias |
|---|---|---|---|
| 0.4 Hz | +0.120 | 0.000 | +278 ms |
| 0.6 Hz | +0.060 | 0.000 | +127 ms |
| 1.0 Hz | +0.034 | 0.004 | +64 ms |
| 1.5 Hz | +0.022 | 0.005 | +57 ms |
| **2.0 Hz** | **+0.019** | **0.007** | **+57 ms** |
| 3.0 Hz | +0.018 | 0.006 | +65 ms |
| 5.0 Hz | +0.017 | 0.010 | +62 ms |

Bias falls steeply to about 2 Hz. Past that it keeps improving, but only by
0.0014 in duty cycle between 2 Hz and 5 Hz, while the spread across seeds
grows from 0.007 to 0.010. The 2 Hz default sits at that knee. Going below
1 Hz is where the real damage is.

**`min_prominence`.** Across the first ten archive recordings, moving it from
0.2 to 0.8 changes the total breath count by 16% (8236 to 6904) but leaves the
median duty cycle at 0.450–0.453 and the median rate within 2.0/min. The
morphology features are robust to this; the count is not. Pick it by looking
at what gets rejected, not by its effect on the summary statistics.

**`resp_despike(window_s)`.** The running-median window is bounded from below
by the widest artefact a median over it can still reject: at 0.2 s a 3-sample
spike survives, and 0.3 s is the default because it removes one (0.22 s is the
smallest that does). It flags **0.000%** of clean synthetic signals across
noise levels from 0 to 0.10; the margin is deliberate.

Since the sixth review pass there is no matching upper bound. The spread the
residual is compared against is measured at a lag of half the window, so it
widens as the window does and the two stay in proportion — a clean trace
survives every window from 0.2 s to 4 s. Under the earlier one-sample lag the
window had a real ceiling, because the residual grew with it while the scale
did not.

**`resp_despike(threshold)`.** Default 3, not 10. The scale changed in the
sixth review pass and the number in front of it was recalibrated to match;
see that section for the equivalence table. On the 198 archive recordings the
flagged fraction tracks the quality grade, which is what an artefact detector
should do: median 0.005% on recordings graded `good` (worst 1.89%), 0.137% on
`degraded`, 4.9% on `unusable`. Above `warn_frac` — 1% by default — it warns
rather than leaving the figure in a provenance string.

**`resp_analyse(polarity)`.** Set it from the transducer, but check the
`$polarity` element of the result, which reports what the data say. A belt
rises on inhalation (`"up"`); an uninverted nasal thermistor falls
(`"down"`). Getting it wrong yields a complete, plausible table with Ti and Te
swapped — `resp_analyse()` warns when the two disagree confidently, and is
silent under paced breathing where the diagnostic is genuinely uninformative.

One systematic artefact it removes is worth knowing about: **almost every
legacy `.rds` has a corrupted first sample.** Across 40 files the ratio of
sample 1 to sample 2 has a median of 0.475 and an interquartile range of
0.474–0.476 — the startup transient of the original decimation chain, not
anything the participant did. Eight of the 198 do not show it (ratio
0.985–1.046).

**`resp_quality()` frequency thresholds.** These were retuned after measuring
them. The original 0.08–0.35 Hz window flagged 26 of 198 recordings for a
dominant frequency that was too *low* — none of whom were breathing slowly;
the peak was landing on the residual drift shoulder just above the 0.05 Hz
high-pass corner. Searching from 0.10 Hz instead removes all 26. The 0.35 Hz
ceiling is separately indefensible: 20 of the 198 breathe faster than 21/min,
and applied to `dominant_freq_hz` that ceiling would flag 8 recordings, 6 of
them otherwise good. With the search floor at 0.10 Hz and the window widened
to 0.10–0.60 Hz, **23 recordings move from `degraded` to `good`**, and those
still flagged are flagged on substantive grounds: low amplitude (13),
flatline (15), saturation (4).

**`band_ratio_min`.** Enabled at 0.80, which on this archive changes nothing
and buys real protection. It is the only metric that separates a genuine
respiratory signal from a disconnected sensor: band-passed white noise wanders
slowly enough to pass the amplitude and frequency checks and yields a
plausible breath count, but its band ratio is 0.72, whereas the lowest among
158 good recordings is 0.956.

**`filtered_iqr` thresholds.** On this archive the distribution is *not* the
clean bimodal split the original pipeline's comments describe: 14 recordings
fall below 0.05, 171 above 0.20, and 13 sit in between. Treat the middle band
as genuinely ambiguous and inspect it rather than assuming a cut exists.

## Design decisions worth knowing about

**Sampling rate is never claimed, only reported.** There is no `nominal_fs`
field. `resp_downsample(x, target_fs = 25)` on a 2000 Hz signal gives exactly
25 Hz; on a 2048 Hz signal it tells you it gave 25.6 Hz. Defect 1 above is
what happens when a container is allowed to hold an aspiration.

**Every recording carries its own provenance.** `resp_provenance()` returns
the ordered list of transformations applied, including the numbers used. This
is what makes a serialised recording self-describing rather than something
that has to be paired with the script that produced it.

**`t0` rather than trim offsets.** `resp_slice()` sets the new start time on
the recording clock, so event times computed before the slice remain valid and
nothing downstream has to remember how much was removed.

**Nothing is silently dropped.** `flag_breaths()` adds columns rather than
removing rows; `epoch_features()` returns one row per window even when the
window is empty; `resp_quality()` returns its metrics regardless of the
verdict. Rejection rates are always recoverable from the output.

**Thresholds are arguments.** The defaults in `resp_quality()` were tuned on
one dataset of 206 adults wearing one model of belt, and `filtered_iqr` in
particular is in the units of the input signal and meaningless on another
scale. Run the screen across your sample with the amplitude thresholds
disabled, plot the distribution, and choose a cut where it is bimodal. The
frequency, flatline and saturation tests are scale-free and transfer directly.

---

## Deliberately not included

Task-specific logic from the original, which belongs in a study repository
rather than a signal-processing package:

- `getExpectedSignal()` / `alignSignals()` / `compareDurations()` — these model
  a specific 4-breath paced trial with a geometric duration ramp
- Session-onset recovery by template alignment
- Trigger-code conventions, condition labels, participant exception tables
- Contamination detection between consecutive `.acq` recordings

The generic parts of those — cross-correlation alignment of one trace inside
another, trigger extraction with debouncing — are available:
`resp_read_acq()` handles triggers with a debounce the original lacked, and
`resp_epochs()` takes onsets from wherever you computed them.
