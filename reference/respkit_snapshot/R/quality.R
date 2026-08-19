# =====================================================================
#  quality.R — signal quality assessment
#
#  IMPROVEMENTS OVER THE ORIGINAL assess_belt_quality()
#  ----------------------------------------------------
#  1. Welch's method instead of one raw periodogram. The original took a
#     single FFT of the whole recording with no window function. That gives
#     a spectral estimate whose variance does not fall as the recording gets
#     longer, and rectangular windowing leaks power from the strong
#     respiratory peak across the whole band, which biases any band-power
#     ratio computed from it. Averaging windowed segments fixes both.
#
#  2. Flatline detection on the raw signal. The original ran its run-length
#     test on the band-pass filtered signal, so a stuck sensor first had its
#     constant value smeared by a zero-phase filter with a multi-second
#     impulse response before anyone looked for constant values. A stuck
#     analogue-to-digital converter emits literally identical samples; test
#     for that where it happens.
#
#  3. Saturation detection. Neither the original nor its downstream code
#     noticed a belt pinned at the rail of its range, which produces a
#     plausible IQR and a plausible dominant frequency while clipping every
#     amplitude measurement.
#
#  4. Segment-wise reporting. A single verdict for a fifty-minute recording
#     throws away a good forty minutes when the participant adjusted the belt
#     once. resp_quality(by_segment = TRUE) locates the bad stretches so they
#     can be excluded rather than the participant.
#
#  5. Thresholds are arguments, not constants, and the metrics are returned
#     regardless of the verdict. The published defaults below were tuned on
#     one dataset of 206 adults wearing one model of belt; treat them as a
#     starting point and re-inspect the distribution before adopting them.
# =====================================================================

# Internal: threshold comparisons in which NA means "this test is disabled".
#
# The documented way to adopt this screen on a new transducer is to run it with
# the amplitude thresholds switched off, inspect the distribution across the
# cohort, and choose a cut. That requires NA to mean "skip". Comparing against
# a raw NA instead yields NA, and `if (NA)` is an error -- so the documented
# workflow used to abort.
below_thr <- function(x, thr) isTRUE(is.finite(x) && !is.na(thr) && x < thr)
above_thr <- function(x, thr) isTRUE(is.finite(x) && !is.na(thr) && x > thr)

# Internal: the one place an "unusable, nothing measurable" verdict is built,
# so every early return carries the same fields in the same order as the
# normal path. A missing element makes a cohort rbind() recycle silently,
# writing one column's values into another.
quality_unusable_row <- function(id, duration_s, fs, note, by_segment = FALSE) {
  out <- list(id = id, quality = "unusable",
              filtered_iqr = NA_real_, band_ratio = NA_real_,
              dominant_freq_hz = NA_real_, dominant_rate_bpm = NA_real_,
              flatline_pct = NA_real_, saturation_pct = NA_real_,
              na_pct = 100, duration_s = duration_s, usable_duration_s = 0,
              fs = if (is.null(fs)) NA_real_ else fs,
              flags = note, note = note)
  if (by_segment) out["segments"] <- list(NULL)
  out
}

#' Power spectral density by Welch's method
#'
#' @param x A `resp_recording` or numeric vector.
#' @param fs Sampling rate; required for bare numeric input.
#' @param segment_s Length of each averaged segment, in seconds. Longer
#'   segments give finer frequency resolution and a noisier estimate. The
#'   default of 120 s resolves 0.008 Hz, ample for respiration.
#' @param overlap Fractional overlap between segments. 0.5 is conventional.
#'
#' @return A data frame with `freq` (Hz) and `power`.
#' @export
resp_psd <- function(x, fs = NULL, segment_s = 120, overlap = 0.5) {
  rec <- as_resp_recording(x, fs = fs)
  sig <- fill_gaps(rec$signal)$signal
  fs  <- rec$fs
  n   <- length(sig)

  seg <- min(n, max(64L, round(segment_s * fs)))
  if (seg %% 2L == 1L) seg <- seg - 1L
  step <- max(1L, round(seg * (1 - overlap)))

  starts <- seq(1L, max(1L, n - seg + 1L), by = step)
  if (!length(starts)) starts <- 1L

  # Hann window, with the coherent gain correction so power stays comparable.
  w  <- 0.5 - 0.5 * cos(2 * pi * (seq_len(seg) - 1L) / (seg - 1L))
  u  <- mean(w^2)

  nf    <- seg %/% 2L
  accum <- numeric(nf)
  used  <- 0L
  # At least one segment always fits, so `used` cannot end at zero: `seg` is
  # capped at `n`, and `starts` always contains 1, so the first iteration
  # satisfies `1 + seg - 1 <= n`. There was a whole-signal fallback here for
  # the `used == 0` case; it was unreachable for every input from n = 1
  # upwards, and unreachable code in this package is worse than absent code
  # because the mutation checker cannot tell the two apart.
  for (s in starts) {
    if (s + seg - 1L > n) next
    v <- sig[s:(s + seg - 1L)]
    v <- v - mean(v)
    f <- stats::fft(v * w)
    accum <- accum + (Mod(f[seq_len(nf)])^2)
    used  <- used + 1L
  }

  # One-sided PSD: the factor of 2 folds the negative-frequency half onto the
  # positive one, so that integrating `power` over `freq` recovers the signal
  # variance (Parseval). Without it every absolute power is half the truth;
  # ratios such as band_ratio are unaffected either way.
  data.frame(
    freq  = (seq_len(nf) - 1L) * fs / seg,
    power = 2 * accum / (used * seg * fs * u)
  )
}

#' Detect flatline runs in a raw signal
#'
#' @param x A `resp_recording` or numeric vector. Pass the *raw* signal, not
#'   a filtered one.
#' @param fs Sampling rate; required for bare numeric input.
#' @param min_run_s Shortest run of identical values counted as a flatline.
#' @param digits Rounding applied before the run-length test, to tolerate
#'   dither in the least significant bit. `NULL` tests for exact equality.
#'
#' @return A list with `pct` (percentage of samples inside flatline runs),
#'   `n_runs`, and `runs`, a data frame of `start`, `end` and `duration_s`.
#' @export
resp_flatline <- function(x, fs = NULL, min_run_s = 1, digits = 6) {
  # A window with no finite samples is a dropout, which is exactly what this
  # function is for locating. Report it rather than refusing to look at it.
  if (is.numeric(x) && !any(is.finite(x)))
    return(list(pct = NA_real_, n_runs = 0L,
                runs = data.frame(start = integer(0), end = integer(0),
                                  duration_s = numeric(0))))
  rec <- as_resp_recording(x, fs = if (is.null(fs) && is.numeric(x)) 1 else fs)
  sig <- rec$signal
  fs  <- rec$fs

  v <- if (is.null(digits)) sig else round(sig, digits)
  r <- rle(v)
  min_run <- max(2L, round(min_run_s * fs))

  ends   <- cumsum(r$lengths)
  starts <- ends - r$lengths + 1L
  hit    <- which(r$lengths >= min_run & is.finite(r$values))

  runs <- data.frame(
    start      = starts[hit],
    end        = ends[hit],
    duration_s = r$lengths[hit] / fs
  )

  list(pct    = 100 * sum(r$lengths[hit]) / length(sig),
       n_runs = length(hit),
       runs   = runs)
}

#' Detect saturation against the extremes of the recorded range
#'
#' Reports how much of the signal sits exactly at its own minimum or maximum.
#' A transducer driven past the end of its range, or an amplifier at its rail,
#' produces long stretches pinned at a single value; every amplitude measured
#' there is a lower bound rather than a measurement.
#'
#' @param x A `resp_recording` or numeric vector. Pass the raw signal.
#' @param fs Sampling rate; required for bare numeric input.
#' @param tol Fraction of the total range within which a sample counts as
#'   being at the rail. Default 0.001.
#'
#' @return A list with `pct_at_min`, `pct_at_max`, `pct_saturated`, and the
#'   `min` and `max` observed.
#' @export
resp_saturation <- function(x, fs = NULL, tol = 0.001) {
  # Saturation is a property of the amplitude distribution alone, so the
  # sampling rate is irrelevant here and is not required from the caller.
  rec <- as_resp_recording(x, fs = if (is.null(fs) && is.numeric(x)) 1 else fs)
  s   <- rec$signal[is.finite(rec$signal)]
  if (!length(s))
    return(list(pct_at_min = NA_real_, pct_at_max = NA_real_,
                pct_saturated = NA_real_, min = NA_real_, max = NA_real_))

  lo <- min(s); hi <- max(s)
  rng <- hi - lo
  band <- if (rng > 0) tol * rng else 0

  at_min <- s <= lo + band
  at_max <- s >= hi - band

  list(pct_at_min = 100 * sum(at_min) / length(s),
       pct_at_max = 100 * sum(at_max) / length(s),
       # Counted as a union, not a sum. On a perfectly flat signal every
       # sample is simultaneously at the minimum and at the maximum, and
       # adding the two counts reports 200% saturated.
       pct_saturated = 100 * sum(at_min | at_max) / length(s),
       min = lo, max = hi)
}

#' Assess respiratory signal quality
#'
#' @param x A `resp_recording` or numeric vector, **raw**: the function does
#'   its own filtering, and flatline and saturation tests are only meaningful
#'   before filtering.
#' @param fs Sampling rate; required for bare numeric input.
#' @param trim_s Seconds excluded from each end before computing metrics, to
#'   skip belt fitting at the start and removal at the end. If the recording
#'   is too short the trim shrinks automatically and a note is added.
#' @param target_fs Rate to decimate to before analysis, purely for speed.
#'   `NULL` skips it.
#' @param low,high Band-pass cutoffs applied before the amplitude and spectral
#'   metrics.
#' @param resp_band Upper edge of the "core respiratory" band, in Hz, used for
#'   the band-power ratio and for locating the dominant frequency.
#' @param dom_lo Lower edge of the search window for the dominant frequency,
#'   in Hz. Kept above `low` so that residual drift just above the high-pass
#'   corner cannot win the search.
#'
#' @section How much to trust dominant_freq_hz:
#' Less than it looks. Compared against the rate derived from detected breaths
#' across 198 belt recordings, the spectral peak landed within 20% of it for
#' only 45% of participants when searched from 0.05 Hz, and 55% when searched
#' from 0.12 Hz. A respiratory belt carries strong power at frequencies below
#' the breath rate -- residual drift, postural change, and in task designs the
#' trial envelope -- and any of those can take the argmax. Treat this metric as
#' a coarse plausibility check on whether *something* respiratory-looking is
#' present, and take the actual rate from
#' `summarise_breaths()$rate_from_mean_duration` instead.
#' @param thresholds Named list of decision thresholds. See Details.
#' @param by_segment If `TRUE`, also return a per-segment verdict.
#' @param segment_s Segment length in seconds when `by_segment = TRUE`.
#'
#' @return A list of metrics plus `quality` (`"good"`, `"degraded"` or
#'   `"unusable"`), `flags` and `note`. When `by_segment = TRUE`, also
#'   `segments`, a data frame with one row per segment.
#'
#' @section Thresholds:
#' \describe{
#'   \item{`iqr_unusable`}{Filtered interquartile range below this means no
#'     respiratory oscillation was recorded at all.}
#'   \item{`iqr_degraded`}{A weaker amplitude floor.}
#'   \item{`freq_lo`, `freq_hi`}{Plausible range for the dominant respiratory
#'     frequency, in Hz. The defaults of 0.10-0.60 Hz correspond to 6-36
#'     breaths per minute. Across 198 adult belt recordings the rate derived
#'     from detected breaths spanned 12.7-25.6/min, and 20 of them breathed
#'     faster than 21/min, so a ceiling at 0.35 Hz has no physiological
#'     justification; applied to `dominant_freq_hz` it would have flagged 8
#'     recordings, 6 of them otherwise graded good. Lower `freq_lo` for slow
#'     paced-breathing protocols, which run at 6/min and sometimes slower, and
#'     raise `freq_hi` for children.}
#'   \item{`flatline_pct`, `saturation_pct`}{Percentage limits.}
#'   \item{`na_degraded`, `na_unusable`}{Percentage of missing or non-finite
#'     samples above which the recording is flagged, then rejected. Every
#'     other metric here tolerates gaps silently, so without an explicit test
#'     a recording that is half absent scores as a clean one.}
#'   \item{`band_ratio_min`}{Minimum fraction of in-band power falling in the
#'     core respiratory band. This is the only test that separates a genuine
#'     respiratory signal from a disconnected sensor picking up noise: band-pass
#'     filtered white noise wanders slowly enough to look like breathing, passes
#'     the amplitude and frequency checks, and yields a plausible breath count.
#'     Measured across 198 belt recordings, the lowest band ratio among those
#'     graded `good` was 0.956 and the 5th percentile across all recordings was
#'     0.963, while band-passed white noise sits at 0.68. The default of 0.80
#'     therefore flagged none of the 158 good recordings while still rejecting
#'     noise. Set to `NA` to disable.}
#' }
#'
#' @section Interpreting the amplitude thresholds:
#' `filtered_iqr` is in the units of the input signal. The defaults were set
#' for a BIOPAC respiratory belt recorded in volts, and they are meaningless
#' for a signal recorded on any other scale. If your transducer differs, run
#' the screen across your whole sample with the thresholds disabled, plot the
#' distribution of `filtered_iqr`, and choose a cut where the distribution is
#' bimodal. The frequency, flatline and saturation tests are scale-free and
#' transfer directly.
#' @export
resp_quality <- function(x, fs = NULL,
                         trim_s     = 120,
                         target_fs  = 25,
                         low        = 0.05,
                         high       = 1.0,
                         resp_band  = 0.6,
                         dom_lo     = 0.10,
                         thresholds = list(),
                         by_segment = FALSE,
                         segment_s  = 120) {

  defaults <- list(
    iqr_unusable   = 0.05,
    iqr_degraded   = 0.20,
    freq_lo        = 0.10,
    freq_hi        = 0.60,
    flatline_pct   = 10,
    saturation_pct = 5,
    na_degraded    = 1,
    na_unusable    = 20,
    band_ratio_min = 0.80
  )
  th <- utils::modifyList(defaults, thresholds)

  if (!is.na(dom_lo) && dom_lo >= resp_band)
    stop("`dom_lo` (", dom_lo, " Hz) must be below `resp_band` (", resp_band,
         " Hz), or the dominant-frequency search window is empty.", call. = FALSE)

  # A recording with no finite samples at all is a total dropout, which is the
  # most extreme case this screen exists to grade. Constructing a recording
  # from it errors, so a batch loop would die on its single worst file rather
  # than labelling it.
  if (is.numeric(x) && !any(is.finite(x)))
    return(quality_unusable_row(id = NA_character_,
                                duration_s = length(x) / (fs %||% NA_real_),
                                fs = fs, note = "no finite samples",
                                by_segment = by_segment))

  rec <- as_resp_recording(x, fs = fs)
  if (!any(is.finite(rec$signal)))
    return(quality_unusable_row(id = rec$id, duration_s = resp_duration(rec),
                                fs = rec$fs, note = "no finite samples",
                                by_segment = by_segment))

  notes <- character(0)

  duration_s <- resp_duration(rec)

  # --- trim ------------------------------------------------------------
  min_usable_s <- 30
  eff_trim <- trim_s
  if (duration_s - 2 * trim_s < min_usable_s) {
    eff_trim <- max(0, (duration_s - min_usable_s) / 2)
    notes <- c(notes, sprintf(
      "Recording is %.1f s; trimmed %.1f s per end instead of %.1f s.",
      duration_s, eff_trim, trim_s))
  }
  trimmed <- if (eff_trim > 0)
    resp_slice(rec, from = rec$t0 + eff_trim, to = rec$t0 + duration_s - eff_trim)
  else rec

  # The finiteness check above looked at the WHOLE recording, but everything
  # below runs on the trimmed span. A belt that disconnects early leaves finite
  # samples only in the trimmed-off head, and resp_filter() then died on an
  # all-missing vector -- killing a batch loop on the single worst file, which
  # is precisely the case `na_unusable` exists to grade.
  if (!any(is.finite(trimmed$signal)))
    return(quality_unusable_row(
      id = rec$id, duration_s = duration_s, fs = rec$fs,
      note = sprintf(paste0("no finite samples in the analysed span (%.0f s ",
                            "trimmed from each end; the recording has data ",
                            "only outside it)"), eff_trim),
      by_segment = by_segment))

  # --- raw-domain tests, before any filtering --------------------------
  # Missing data has to be counted explicitly. Every other metric here is
  # NA-tolerant by construction -- IQR skips them, the filter interpolates and
  # restores them, the flatline test excludes non-finite runs -- so without
  # this a recording that is mostly absent scores as a clean one.
  na_pct <- 100 * sum(!is.finite(trimmed$signal)) / length(trimmed$signal)

  flat <- resp_flatline(trimmed, min_run_s = 1)
  sat  <- resp_saturation(trimmed)

  # --- downsample and filter -------------------------------------------
  work <- trimmed
  if (!is.null(target_fs) && target_fs < work$fs)
    work <- suppressMessages(resp_downsample(work, target_fs = target_fs))
  filt <- resp_filter(work, low = low, high = high)

  filtered_iqr <- stats::IQR(filt$signal, na.rm = TRUE)

  # --- spectrum ---------------------------------------------------------
  psd <- resp_psd(filt, segment_s = min(segment_s, resp_duration(filt) / 2))
  in_resp  <- psd$freq >= low & psd$freq <= resp_band
  in_total <- psd$freq >= low & psd$freq <= min(high, max(psd$freq))

  resp_power  <- if (any(in_resp))  sum(psd$power[in_resp])  else 0
  total_power <- if (any(in_total)) sum(psd$power[in_total]) else 0
  band_ratio  <- if (total_power > 0) resp_power / total_power else NA_real_

  # The dominant-frequency search starts above the band-pass corner, not at
  # it. A 2nd-order high-pass at 0.05 Hz leaves a substantial shoulder of
  # residual drift just above its cutoff, and on real belt data that shoulder
  # wins the argmax often enough to matter: searching from 0.05 Hz put 26 of
  # 198 recordings below 0.08 Hz, none of whom were breathing that slowly.
  in_dom <- psd$freq >= dom_lo & psd$freq <= resp_band
  dominant_freq_hz <- if (any(in_dom) && sum(psd$power[in_dom]) > 0)
    psd$freq[in_dom][which.max(psd$power[in_dom])] else NA_real_

  # --- verdict ----------------------------------------------------------
  # Every failing test is reported, whichever one decides the verdict. An
  # earlier version stopped at the first disqualifying test, so an "unusable"
  # recording reported only its missing-data percentage while its flatline and
  # saturation figures -- computed, returned, and equally damning -- were left
  # out of the human-readable note.
  flags <- character(0)

  if (above_thr(na_pct, th$na_degraded))
    flags <- c(flags, sprintf("%.1f%% of samples missing or non-finite", na_pct))
  if (below_thr(filtered_iqr, th$iqr_degraded))
    flags <- c(flags, sprintf("filtered_iqr = %.4f below %.3f",
                              filtered_iqr, th$iqr_degraded))
  if (below_thr(dominant_freq_hz, th$freq_lo) || above_thr(dominant_freq_hz, th$freq_hi))
    flags <- c(flags, sprintf("dominant frequency %.3f Hz (%.1f/min) outside [%s, %s] Hz",
                              dominant_freq_hz, dominant_freq_hz * 60,
                              format(th$freq_lo), format(th$freq_hi)))
  if (above_thr(flat$pct, th$flatline_pct))
    flags <- c(flags, sprintf("flatline %.1f%% of samples", flat$pct))
  if (above_thr(sat$pct_saturated, th$saturation_pct))
    flags <- c(flags, sprintf("saturated %.1f%% of samples", sat$pct_saturated))
  if (below_thr(band_ratio, th$band_ratio_min))
    flags <- c(flags, sprintf("band ratio %.3f below %.3f",
                              band_ratio, th$band_ratio_min))

  # Each disqualifying test records its own reason. Relying on the matching
  # `*_degraded` test to have already logged one leaves an "unusable" verdict
  # with an empty note whenever that threshold is disabled -- which is exactly
  # what the documented calibration workflow does.
  quality <- if (above_thr(na_pct, th$na_unusable) ||
                 below_thr(filtered_iqr, th$iqr_unusable)) {
    if (above_thr(na_pct, th$na_unusable) && !above_thr(na_pct, th$na_degraded))
      flags <- c(flags, sprintf("%.1f%% of samples missing, above the unusable threshold %s%%",
                                na_pct, format(th$na_unusable)))
    if (below_thr(filtered_iqr, th$iqr_unusable))
      flags <- c(flags, sprintf("filtered_iqr = %.4f below unusable threshold %.3f",
                                filtered_iqr, th$iqr_unusable))
    "unusable"
  } else if (length(flags)) "degraded" else "good"

  out <- list(
    id                = rec$id,
    quality           = quality,
    filtered_iqr      = filtered_iqr,
    band_ratio        = band_ratio,
    dominant_freq_hz  = dominant_freq_hz,
    dominant_rate_bpm = dominant_freq_hz * 60,
    flatline_pct      = flat$pct,
    saturation_pct    = sat$pct_saturated,
    na_pct            = na_pct,
    duration_s        = duration_s,
    usable_duration_s = resp_duration(trimmed),
    fs                = filt$fs,
    flags             = flags,
    note              = paste(c(notes, flags), collapse = " | ")
  )

  if (by_segment) out$segments <- quality_by_segment(
    rec, segment_s = segment_s, low = low, high = high,
    resp_band = resp_band, dom_lo = dom_lo, target_fs = target_fs, th = th)

  out
}

# Internal: run the amplitude and frequency tests on consecutive segments so
# that a locally bad stretch can be excluded instead of the whole recording.
quality_by_segment <- function(rec, segment_s, low, high, resp_band,
                               dom_lo, target_fs, th) {

  work <- rec
  if (!is.null(target_fs) && target_fs < work$fs)
    work <- suppressMessages(resp_downsample(work, target_fs = target_fs))
  filt <- resp_filter(work, low = low, high = high)

  fs <- filt$fs
  n  <- length(filt$signal)
  seg <- max(2L, round(segment_s * fs))
  starts <- seq(1L, n, by = seg)
  tt <- resp_time(filt)

  rows <- lapply(starts, function(s) {
    e <- min(n, s + seg - 1L)
    if (e - s < fs * 10) return(NULL)     # ignore a stub shorter than 10 s
    v <- filt$signal[s:e]
    raw <- rec$signal[
      pmin(length(rec$signal),
           round((tt[s] - rec$t0) * rec$fs) + 1L):
      pmin(length(rec$signal),
           round((tt[e] - rec$t0) * rec$fs) + 1L)]

    # A segment can be entirely missing -- that is precisely the kind of local
    # dropout this function exists to locate -- so it must be reported rather
    # than allowed to abort the whole assessment.
    na_pct_seg <- 100 * sum(!is.finite(v)) / length(v)
    if (!any(is.finite(v)) || !any(is.finite(raw)))
      return(data.frame(start_s = tt[s], end_s = tt[e], filtered_iqr = NA_real_,
                        dominant_freq_hz = NA_real_, flatline_pct = NA_real_,
                        na_pct = na_pct_seg, usable = FALSE,
                        stringsAsFactors = FALSE))

    iqr <- stats::IQR(v, na.rm = TRUE)
    p   <- resp_psd(v, fs = fs, segment_s = (e - s + 1L) / fs / 2)
    # Same search floor as the whole-recording path. Starting from `low`
    # instead let the drift shoulder win the argmax and condemned about 17% of
    # all segments, contradicting the verdict from the same function call.
    ok  <- p$freq >= dom_lo & p$freq <= resp_band
    dom <- if (any(ok)) p$freq[ok][which.max(p$power[ok])] else NA_real_
    fl  <- resp_flatline(raw, fs = rec$fs, min_run_s = 1)$pct

    bad <- below_thr(iqr, th$iqr_degraded) ||
      below_thr(dom, th$freq_lo) || above_thr(dom, th$freq_hi) ||
      above_thr(fl, th$flatline_pct) ||
      above_thr(na_pct_seg, th$na_degraded)

    data.frame(start_s = tt[s], end_s = tt[e], filtered_iqr = iqr,
               dominant_freq_hz = dom, flatline_pct = fl,
               na_pct = na_pct_seg, usable = !bad, stringsAsFactors = FALSE)
  })

  out <- do.call(rbind, rows[!vapply(rows, is.null, logical(1))])
  if (is.null(out)) return(NULL)
  rownames(out) <- NULL
  out
}
