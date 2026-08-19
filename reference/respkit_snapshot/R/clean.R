# =====================================================================
#  clean.R — artefact handling, detrending, normalisation, and the
#            preprocessing orchestrator
# =====================================================================

# Internal: warn when a signal carries no variation worth analysing.
#
# This has to be checked on the raw signal, because the evidence is destroyed
# almost immediately. High-passing a constant leaves values at the level of
# floating-point error, and normalising those divides by a scale of the same
# order -- which amplifies pure rounding noise into something that looks like
# a waveform, complete with detectable peaks and troughs. By the time anything
# downstream sees it, there is no way left to tell it from a real recording
# except that the amplitudes come out negative.
warn_if_constant <- function(sig) {
  s <- sig[is.finite(sig)]
  if (!length(s)) return(invisible(FALSE))
  rng <- diff(range(s))
  if (rng <= .Machine$double.eps * max(1, max(abs(s)))) {
    warning("Signal is constant to within floating-point precision (range ",
            signif(rng, 3), "). Filtering and normalising it will amplify ",
            "rounding error into a waveform that detection will happily find ",
            "breaths in. Every feature derived from this recording is ",
            "meaningless; resp_quality() will grade it unusable.", call. = FALSE)
    return(invisible(TRUE))
  }
  invisible(FALSE)
}

# Internal helper so every cleaning function accepts either form.
with_signal <- function(x, fs, fn, prov_fmt, ...) {
  was_recording <- is_resp_recording(x)
  if (was_recording) {
    fs  <- x$fs
    sig <- x$signal
  } else {
    if (is.null(fs))
      stop("`fs` must be supplied when `x` is not a resp_recording.", call. = FALSE)
    sig <- as.numeric(x)
  }
  res <- fn(sig, fs)
  if (!was_recording) return(res$signal)
  out <- x
  out$signal <- res$signal
  if (!is.null(res$units)) out$units <- res$units
  do.call(add_provenance, c(list(out, prov_fmt), res$prov))
}

#' Clamp extreme values to percentile bounds
#'
#' The approach used by the original pipeline: values beyond the given
#' quantiles are clamped in place.
#'
#' @section When not to use this:
#' Clamping replaces an excursion with a flat plateau. If the excursion was a
#' genuine deep breath rather than an artefact, the plateau removes the local
#' maximum and the detector has no unambiguous peak to find; if it was a
#' movement spike, the plateau is still a broad flat top that prominence-based
#' detection may accept. [resp_despike()] is usually the better tool because
#' it interpolates across the artefact instead of flattening it. Clamping is
#' retained here for backwards compatibility with existing analyses.
#'
#' @param x A `resp_recording` or numeric vector.
#' @param lower,upper Quantiles defining the clamp, in `[0, 1]`.
#' @param fs Sampling rate; required for bare numeric input.
#' @export
resp_clip <- function(x, lower = 0.005, upper = 0.995, fs = NULL) {
  with_signal(x, fs, function(sig, fs) {
    qs <- stats::quantile(sig, c(lower, upper), na.rm = TRUE, names = FALSE)
    out <- pmin(pmax(sig, qs[1]), qs[2])
    n_clamped <- sum(is.finite(sig) & (sig < qs[1] | sig > qs[2]))
    list(signal = out,
         prov   = list(lower, upper, qs[1], qs[2], n_clamped,
                       100 * n_clamped / length(sig)))
  }, "clip(q=[%.4g, %.4g] -> [%.5g, %.5g]): %d samples clamped (%.2f%%)")
}

#' Remove transient spikes by interpolation
#'
#' A Hampel filter. Each sample is compared with a running median of its
#' neighbourhood, and samples whose deviation from it is large relative to the
#' recording's own robust spread are replaced by linear interpolation across
#' the gap. Movement artefacts, belt slippage and electrical transients depart
#' from the local trend far more sharply than any respiratory excursion.
#'
#' @param x A `resp_recording` or numeric vector.
#' @param threshold Multiple of the signal's own robust spread beyond which a
#'   sample is treated as an artefact. Default 10 is deliberately permissive;
#'   lower it only after inspecting what gets removed. The spread is measured
#'   over the same time-scale as the residual, so the same `threshold` means
#'   the same thing at 25 Hz and at 2000 Hz; see the note on the scale estimate
#'   in the source, and the figures below.
#' @param warn_frac Fraction of samples above which interpolating that many is
#'   reported as a warning. Default 0.01 (1%). On the 198-recording archive
#'   that fires on 20 files, 19 of which are independently graded `degraded` or
#'   `unusable`, so it is a usable screen rather than noise. Set to `Inf` to
#'   silence it once you have inspected the recording.
#' @param max_width_s Longest run of consecutive flagged samples that will be
#'   interpolated. Anything longer is left alone, on the grounds that it is
#'   probably signal (or a stretch of unusable recording that
#'   [resp_quality()] should be reporting, not something to paper over).
#' @param window_s Width of the running-median neighbourhood, in seconds. The
#'   window must be wide enough that a median over it still rejects the widest
#'   artefact you care about — more than twice that artefact's duration. At
#'   25 Hz a 3-sample artefact needs 0.3 s and is missed at 0.2 s. That lower
#'   bound is what sets the default.
#'
#'   There is no longer a matching upper bound. The spread the residual is
#'   compared against is now measured at a lag of half this window, so it
#'   widens as the window does and the two stay in proportion: on a clean
#'   noise-free trace the flagged fraction is 0.000% at every window from 0.2 s
#'   to 4 s. Under the earlier lag-1 scale the same trace lost 7.0% of its
#'   samples at a 2 s window, because the residual carried the breath's own
#'   curvature with nothing growing to offset it.
#'
#'   At the 0.3 s default nothing is flagged on clean synthetic signals across
#'   noise levels from 0.005 to 0.10, and injected spikes are caught wherever
#'   they fall — with one exception, unchanged from the lag-1 scale: a
#'   multi-sample spike straddling the very first or very last sample survives,
#'   because the endpoint padding estimates its slope from the samples
#'   immediately inside, which such a spike has contaminated. A single-sample
#'   spike at either endpoint is caught.
#' @param fs Sampling rate; required for bare numeric input.
#'
#' @section What this flags on real data:
#' Across the 198 archived belt recordings at 25.641 Hz the flagged fraction
#' tracks the quality grade, which is what you want from an artefact detector:
#'
#' \tabular{lrrrr}{
#'   grade      \tab n   \tab median  \tab p90     \tab worst   \cr
#'   `good`     \tab 158 \tab 0.0048% \tab 0.049%  \tab 1.89%   \cr
#'   `degraded` \tab  26 \tab 0.137%  \tab 11.2%   \tab 19.0%   \cr
#'   `unusable` \tab  14 \tab 4.92%   \tab 17.8%   \tab 30.1%
#' }
#'
#' If a recording of yours sits near the top of that range, inspect it rather
#' than raising `threshold`; `warn_frac` exists to make sure you are told.
#'
#' @section Why the default threshold is 3 and not 10:
#' The scale the residual is compared against changed, so the number in front
#' of it had to. Both were calibrated together against the behaviour that
#' matters — the smallest single-sample spike reliably caught, and the fraction
#' of a clean trace falsely flagged:
#'
#' \tabular{lrrrr}{
#'   rule                     \tab min spike @25 Hz \tab false pos @25 Hz \tab min spike @2000 Hz \tab false pos @2000 Hz \cr
#'   lag-1, `threshold = 10`  \tab 1.25 SD          \tab 0.000%          \tab 0.75 SD            \tab 1.76%              \cr
#'   lag-h, `threshold = 10`  \tab 3.50 SD          \tab 0.000%          \tab 3.25 SD            \tab 0.000%             \cr
#'   lag-h, `threshold = 3`   \tab 1.25 SD          \tab 0.000%          \tab 1.00 SD            \tab 0.000%
#' }
#'
#' The last row matches the old sensitivity at both rates while removing the
#' rate dependence and the 1.76% of a clean 2000 Hz trace the old rule
#' destroyed. On the legacy archive it also restores the corrupted-first-sample
#' repair described below to 35 of 40 files, exactly what the old rule
#' achieved, where `threshold = 10` under the new scale caught only 24.
#'
#' If you have an existing analysis pinned to `threshold = 10`, note that it
#' does not mean what it did: pass `threshold = 3` to reproduce the old
#' behaviour at any sampling rate.
#'
#' One systematic artefact it removes is worth knowing about. Every `.rds`
#' produced by the pipeline this package replaces has a corrupted first
#' sample: across 40 files the ratio of sample 1 to sample 2 has a median of
#' 0.475 with an interquartile range of 0.474 to 0.476, which is the startup
#' transient of the original decimation chain rather than anything the
#' participant did. Despiking removes it.
#'
#' @section Why not threshold the first difference:
#' An isolated spike produces two large first differences, one going into it
#' and one coming out, so thresholding differences identifies the *transitions*
#' and cannot tell which side of each was the artefact. Flagging both sides
#' marks the two clean samples adjacent to a spike as well as the spike, and a
#' spike at the very first sample takes its clean neighbour with it. Comparing
#' each sample against a local median flags the offending samples themselves.
#' @export
resp_despike <- function(x, threshold = 3, max_width_s = 1, window_s = 0.3,
                         warn_frac = 0.01, fs = NULL) {
  with_signal(x, fs, function(sig, fs) {
    n <- length(sig)
    if (n < 5L) return(list(signal = sig, prov = list(threshold, 0L, 0)))

    k <- max(3L, round(window_s * fs))
    if (k %% 2L == 0L) k <- k + 1L
    k <- min(k, if (n %% 2L == 0L) n - 1L else n)

    gaps <- fill_gaps(sig)
    v    <- gaps$signal
    h    <- (k - 1L) %/% 2L

    # Every sample needs a centred, uncontaminated window. runmed's own end
    # rules are computed from the samples being tested, so a spike at sample 1
    # sets its own reference and drags its clean neighbours out with it.
    #
    # The padding is a robust LINEAR extrapolation, not a mirror. Mirroring
    # duplicates v[2..h+1] around v[1], so on any signal whose end sits on a
    # rising or falling limb the window median lands several samples up the
    # slope and the endpoint is guaranteed a large residual: it made the first
    # or last sample the biggest outlier in the recording, and rewrote one or
    # both on every real trace tested. A linear pad is exact for a locally
    # linear signal, so a clean endpoint gets a residual of zero, while a
    # spiked one still stands out -- and the slope is estimated from v[2..]
    # onwards so a spike at v[1] cannot influence its own reference.
    med <- if (h >= 1L && n >= h + 3L) {
      slope_head <- stats::median(diff(v[2L:(h + 2L)]), na.rm = TRUE)
      slope_tail <- stats::median(diff(v[(n - h - 1L):(n - 1L)]), na.rm = TRUE)
      if (!is.finite(slope_head)) slope_head <- 0
      if (!is.finite(slope_tail)) slope_tail <- 0
      head_pad <- v[2L]     + slope_head * (((1L - h):0L)      - 2L)
      tail_pad <- v[n - 1L] + slope_tail * (((n + 1L):(n + h)) - (n - 1L))
      stats::runmed(c(head_pad, v, tail_pad), k, endrule = "keep")[(h + 1L):(h + n)]
    } else {
      stats::runmed(v, k, endrule = "keep")
    }

    resid <- sig - med

    # Scale the residual against the signal's own variability measured over the
    # SAME time-scale as the residual: the MAD of differences taken at a lag of
    # `h` samples, i.e. half the median window.
    #
    # The lag is what makes `threshold` portable across sampling rates. A lag
    # of one sample -- mad(diff(v)) -- shrinks roughly as 1/fs, because
    # neighbouring samples lie closer together the faster you sample, while the
    # residual against a window fixed in SECONDS does not shrink at all. The
    # same nominal threshold was therefore far stricter at a high rate. One
    # 2000 Hz BIOPAC recording, decimated to a range of rates and despiked at
    # each, flagged 7.234% at 2000 Hz, 3.847% at 1000, 0.554% at 400, 0.018% at
    # 100 and 0.004% at 25: an 1800-fold swing driven by nothing but the rate.
    # That is not academic, because resp_preprocess() and resp_analyse() both
    # despike at the NATIVE rate deliberately -- decimation's anti-alias filter
    # smears a one-sample transient and makes it unrecoverable afterwards -- so
    # the default path was the 2000 Hz one, rewriting a median of 6.0% of
    # samples (worst 10.3%) across 24 archived recordings while the
    # documentation promised 0.009%.
    #
    # Matching the lag to the window removes the dependence, and costs nothing
    # in sensitivity: see the measured figures under "What this flags on real
    # data" below.
    #
    # Scaling against mad(resid) is the other obvious candidate and is
    # degenerate: runmed returns an actual sample value, so wherever the signal
    # is locally monotone the residual is EXACTLY zero -- 84% of samples on a
    # typical belt trace, 94% on a clean sinusoid. mad(resid) is therefore 0 or
    # a float epsilon on nearly every real recording, the threshold collapses,
    # and the flagged fraction swings between 0% and 15% with no stable
    # relationship to the `threshold` argument the user is tuning. Restricting
    # it to the non-zero residuals does not rescue it: that flags 2.3% of a
    # clean synthetic trace at every rate above 100 Hz.
    scale <- stats::mad(diff(v, lag = h), na.rm = TRUE)

    if (is.finite(scale) && scale > 0) {
      flag <- is.finite(resid) & abs(resid) > threshold * scale

    } else {
      # A trace with no short-term variability at all: constant, or stuck.
      # Whatever deviates from its own local median is the artefact, and there
      # is nothing to scale it against. Any spread estimated from so few
      # samples is dominated by the artefact itself, so the spike would set
      # the very threshold meant to catch it -- hence the count test rather
      # than a scale. The 1% ceiling keeps this away from coarsely quantised
      # traces, where many samples legitimately differ from the median.
      nzr <- is.finite(resid) & resid != 0
      if (any(nzr) && sum(nzr) < 0.01 * n) {
        flag <- nzr
      } else {
        d   <- diff(v, lag = h)
        nzd <- d[is.finite(d) & d != 0]
        scale <- if (length(nzd)) stats::median(abs(nzd), na.rm = TRUE) else NA_real_
        if (!is.finite(scale) || scale == 0)
          return(list(signal = sig, prov = list(threshold, 0L, 0)))
        flag <- is.finite(resid) & abs(resid) > threshold * scale
      }
    }

    if (!any(flag))
      return(list(signal = sig, prov = list(threshold, 0L, 0)))

    # Runs too wide to be a transient are left alone.
    r      <- rle(flag)
    max_w  <- max(1L, round(max_width_s * fs))
    ends   <- cumsum(r$lengths)
    starts <- ends - r$lengths + 1L
    for (i in seq_along(r$values))
      if (r$values[i] && r$lengths[i] > max_w)
        flag[starts[i]:ends[i]] <- FALSE

    if (!any(flag) || all(flag))
      return(list(signal = sig, prov = list(threshold, 0L, 0)))

    # A flagged sample is never used as an interpolation source, including at
    # the ends: approx(rule = 2) extends from the nearest clean sample, which
    # is the right answer at a boundary.
    out <- sig
    idx <- seq_along(sig)
    out[flag] <- stats::approx(idx[!flag], sig[!flag], xout = idx[flag], rule = 2)$y

    # The documented advice is to inspect a recording whose flagged fraction is
    # unusually high rather than to raise `threshold`. That advice needs
    # something to fire it: the fraction was previously reported only in a
    # provenance string nobody reads until something has already gone wrong.
    frac <- sum(flag) / n
    if (is.finite(warn_frac) && frac > warn_frac)
      warning(sprintf(
        paste0("despike() interpolated %.2f%% of samples (%d of %d), above the ",
               "%.2f%% expected of an artefact detector. This usually means the ",
               "recording is genuinely poor -- check resp_quality() -- rather ",
               "than that `threshold` is too low. Raising `threshold` hides the ",
               "evidence; set warn_frac = Inf if you have already looked."),
        100 * frac, sum(flag), n, 100 * warn_frac), call. = FALSE)

    list(signal = out,
         prov   = list(threshold, sum(flag), 100 * frac))
  }, "despike(threshold=%g x local MAD): %d samples interpolated (%.3f%%)")
}

#' Remove slow baseline drift
#'
#' @param x A `resp_recording` or numeric vector.
#' @param method `"highpass"` (default) applies a zero-phase Butterworth
#'   high-pass; `"median"` subtracts a running median.
#' @param cutoff_hz High-pass cutoff, used when `method = "highpass"`.
#' @param window_s Running-median window in seconds, used when
#'   `method = "median"`.
#' @param fs Sampling rate; required for bare numeric input.
#'
#' @details
#' The running-median variant uses [stats::runmed()], which is O(n log w).
#' A naive implementation that computes `median()` in a loop over every
#' sample is O(n w) and takes minutes on an hour of data at 25 Hz.
#' @export
resp_detrend <- function(x, method = c("highpass", "median"),
                         cutoff_hz = 0.05, window_s = 60, fs = NULL) {
  method <- match.arg(method)

  if (method == "highpass")
    return(resp_filter(x, low = cutoff_hz, high = NULL, fs = fs))

  with_signal(x, fs, function(sig, fs) {
    k <- max(3L, round(window_s * fs))
    if (k %% 2L == 0L) k <- k + 1L
    if (k >= length(sig))
      stop("Median window (", round(window_s, 2), " s = ", k, " samples) is not ",
           "shorter than the recording (", length(sig), " samples).", call. = FALSE)
    gaps <- fill_gaps(sig)
    base <- stats::runmed(gaps$signal, k, endrule = "median")
    out  <- sig - base
    list(signal = out, prov = list(window_s, k))
  }, "detrend(running median, window=%gs = %d samples)")
}

#' Normalise a signal
#'
#' @param x A `resp_recording` or numeric vector.
#' @param method `"robust"` (default) centres on the median and scales by the
#'   median absolute deviation; `"z"` uses mean and standard deviation;
#'   `"none"` returns the input.
#' @param fs Sampling rate; required for bare numeric input.
#'
#' @details
#' `"robust"` is the default because a handful of movement artefacts inflate
#' the standard deviation enough to shrink every genuine breath towards zero,
#' which then trips amplitude-based rejection in the detector. MAD is scaled
#' by 1.4826 so that for Gaussian data the two methods agree.
#'
#' Normalisation makes detection thresholds transferable across recordings,
#' but it also destroys the interpretability of amplitude features: a
#' z-scored amplitude of 2 means "twice this participant's own variability",
#' not a volume. Build the breath table from the unnormalised signal when
#' amplitudes matter across participants; see [breath_table()].
#' @export
resp_normalise <- function(x, method = c("robust", "z", "none"), fs = NULL) {
  method <- match.arg(method)
  if (method == "none") return(x)

  with_signal(x, fs, function(sig, fs) {
    if (method == "robust") {
      centre <- stats::median(sig, na.rm = TRUE)
      scale  <- stats::mad(sig, na.rm = TRUE)
    } else {
      centre <- mean(sig, na.rm = TRUE)
      scale  <- stats::sd(sig, na.rm = TRUE)
    }
    if (!is.finite(scale) || scale == 0) {
      warning("Scale estimate is zero or non-finite; centring only. ",
              "The signal is flat or nearly so.", call. = FALSE)
      scale <- 1
    }
    list(signal = (sig - centre) / scale,
         units  = if (method == "robust") "MAD" else "z",
         prov   = list(method, centre, scale))
  }, "normalise(%s): centre=%.6g, scale=%.6g")
}

#' @rdname resp_normalise
#' @export
resp_normalize <- resp_normalise

#' Standard preprocessing chain for a respiratory signal
#'
#' Runs, in order: despike, downsample, band-pass filter, normalise. Every
#' step is optional and every intermediate is retained so you can plot the
#' chain and see what each stage did.
#'
#' @param x A `resp_recording` or numeric vector.
#' @param fs Sampling rate; required for bare numeric input.
#' @param target_fs Rate to decimate towards, or `NULL` to skip. The achieved
#'   rate is reported honestly and may differ (see [resp_downsample()]).
#' @param low,high Band-pass cutoffs in Hz. See [resp_filter()] for why the
#'   upper cutoff matters more than it looks.
#' @param order Butterworth order.
#' @param despike Apply [resp_despike()] before anything else.
#' @param despike_threshold Passed to [resp_despike()].
#' @param normalise One of `"robust"`, `"z"`, `"none"`.
#' @param keep_stages Retain a copy of the signal after each step.
#'
#' @return A list with `recording` (the processed `resp_recording`) and
#'   `stages` (a named list of `resp_recording`s, empty if `keep_stages` is
#'   `FALSE`).
#'
#' @details
#' Despiking runs at the native rate, before decimation, because decimation's
#' anti-alias filter smears a one-sample transient across many samples and
#' makes it much harder to identify afterwards.
#' @export
resp_preprocess <- function(x, fs = NULL,
                            target_fs         = 25,
                            low               = 0.05,
                            high              = 1.0,
                            order             = 2L,
                            despike           = TRUE,
                            despike_threshold = 3,
                            normalise         = c("robust", "z", "none"),
                            keep_stages       = TRUE) {

  normalise <- match.arg(normalise)
  rec <- as_resp_recording(x, fs = fs)
  warn_if_constant(rec$signal)

  stages <- list()
  keep <- function(name, r) if (keep_stages) stages[[name]] <<- r

  keep("raw", rec)

  if (isTRUE(despike)) {
    rec <- resp_despike(rec, threshold = despike_threshold)
    keep("despiked", rec)
  }

  if (!is.null(target_fs)) {
    rec <- resp_downsample(rec, target_fs = target_fs)
    keep("downsampled", rec)
  }

  if (!is.null(low) || !is.null(high)) {
    rec <- resp_filter(rec, low = low, high = high, order = order)
    keep("filtered", rec)
  }

  if (normalise != "none") {
    rec <- resp_normalise(rec, method = normalise)
    keep("normalised", rec)
  }

  list(recording = rec, stages = stages)
}
