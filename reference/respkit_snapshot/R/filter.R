# =====================================================================
#  filter.R — zero-phase filtering with honest edge handling
#
#  THREE IMPROVEMENTS OVER THE ORIGINAL
#  ------------------------------------
#  1. Reflection padding. R's signal::filtfilt runs the filter forward and
#     backward but does not pad the ends, so a 0.05 Hz high-pass leaves a
#     transient tens of seconds long at each edge. The original pipeline
#     hid this by trimming 120 s off both ends during quality screening,
#     which is fine for hour-long recordings and destroys short ones. Here
#     the signal is reflected about its endpoints before filtering and the
#     padding is discarded afterwards.
#
#  2. Conditioning check. A 2nd-order Butterworth at 0.05 Hz on a 25 Hz
#     signal has a normalised cutoff of 0.004. Direct-form (b, a)
#     coefficients at that ratio sit close to the edge of double precision.
#     The pole radii are checked and an actionable warning is issued rather
#     than letting a subtly unstable filter through.
#
#  3. NA handling. filtfilt propagates a single NA across the entire
#     output. Gaps are interpolated before filtering and restored after, so
#     one dropped sample no longer destroys a recording.
# =====================================================================

# Internal: linear interpolation over non-finite runs, with edge fill.
# Returns the repaired signal plus the mask of positions that were repaired.
fill_gaps <- function(x) {
  bad <- !is.finite(x)
  if (!any(bad)) return(list(signal = x, filled = bad))
  if (all(bad)) stop("Signal contains no finite values.", call. = FALSE)

  idx  <- seq_along(x)
  good <- !bad
  x[bad] <- stats::approx(idx[good], x[good], xout = idx[bad], rule = 2)$y
  list(signal = x, filled = bad)
}

# Internal: reflect `npad` samples about each endpoint.
#   MATLAB's filtfilt uses 3 * (max(length(a), length(b)) - 1). For the very
#   low normalised cutoffs used on respiratory data that is far too short, so
#   the default is expressed in seconds of signal instead.
reflect_pad <- function(x, npad) {
  n <- length(x)
  npad <- min(as.integer(npad), n - 1L)
  if (npad < 1L) return(list(signal = x, npad = 0L))
  head_pad <- 2 * x[1]  - x[(npad + 1L):2L]
  tail_pad <- 2 * x[n]  - x[(n - 1L):(n - npad)]
  list(signal = c(head_pad, x, tail_pad), npad = npad)
}

# Internal: warn when the requested filter is numerically marginal.
check_conditioning <- function(bf, cutoff_hz, fs) {
  poles <- tryCatch(polyroot(rev(bf$a)), error = function(e) complex(0))
  if (!length(poles)) return(invisible(NULL))
  r <- max(Mod(poles))
  if (r >= 0.9999) {
    warning(sprintf(
      paste0("Filter is numerically marginal: max pole radius %.6f at ",
             "cutoff %s Hz with fs = %.4g Hz (normalised %.5f). ",
             "Downsample further before filtering, or raise the low cutoff."),
      r, paste(signif(cutoff_hz, 3), collapse = "-"), fs,
      min(cutoff_hz) / (fs / 2)), call. = FALSE)
  }
  invisible(r)
}

#' Zero-phase Butterworth filter for respiratory signals
#'
#' @param x A `resp_recording` or numeric vector.
#' @param low,high Cutoff frequencies in Hz. Supply both for a band-pass,
#'   only `low` for a high-pass, only `high` for a low-pass.
#' @param fs Sampling rate; required when `x` is a bare numeric vector.
#' @param order Butterworth order (default 2). `filtfilt` applies the filter
#'   twice, so the effective order is doubled.
#' @param pad_s Seconds of reflection padding added at each end before
#'   filtering and removed afterwards. Default 60 s, comfortably longer than
#'   the transient of a 0.05 Hz high-pass. Set to 0 to disable.
#' @param na_action `"interpolate"` (default) fills non-finite samples before
#'   filtering and restores them as `NA` afterwards; `"error"` refuses to
#'   filter a signal with gaps.
#'
#' @details
#' Choosing the upper cutoff is a real trade-off, not a formality.
#' The consensus band for respiratory belts is roughly 0.05-3 Hz. A tight
#' upper cutoff near 0.4 Hz makes peak detection almost trivial because it
#' leaves little beyond the fundamental, but it also makes every breath
#' nearly sinusoidal. That erases the inspiratory/expiratory asymmetry that
#' [breath_table()] measures, and biases duty cycle towards 0.5. If you want
#' morphology features, filter no tighter than about 1 Hz and let the
#' detector's prominence and distance constraints do the rejection work.
#'
#' @return As `x`: a `resp_recording` with provenance appended, or a numeric
#'   vector.
#' @export
resp_filter <- function(x, low = 0.05, high = 1.0, fs = NULL,
                        order = 2L, pad_s = 60, na_action = c("interpolate", "error")) {

  na_action     <- match.arg(na_action)
  was_recording <- is_resp_recording(x)
  if (was_recording) {
    fs  <- x$fs
    sig <- x$signal
  } else {
    if (is.null(fs))
      stop("`fs` must be supplied when `x` is not a resp_recording.", call. = FALSE)
    sig <- as.numeric(x)
  }

  nyq <- fs / 2
  if (is.null(low) && is.null(high))
    stop("Supply at least one of `low` or `high`.", call. = FALSE)
  if (!is.null(high) && high >= nyq) {
    message(sprintf("Upper cutoff %.4g Hz is at or above Nyquist (%.4g Hz); ignoring it.",
                    high, nyq))
    high <- NULL
    # Dropping the only cutoff leaves nothing to do. Without this re-check the
    # code falls into the low-pass branch with `high = NULL`, builds an empty
    # cutoff vector that passes the range guard vacuously, and dies inside
    # signal::butter with an error the caller cannot act on.
    if (is.null(low)) {
      message("No cutoff remains below Nyquist; returning the signal unfiltered.")
      if (!was_recording) return(sig)
      return(add_provenance(x, "filter(skipped: only cutoff was at or above Nyquist %.4g Hz)",
                            nyq))
    }
  }
  if (!is.null(low) && !is.null(high) && low >= high)
    stop("`low` (", low, ") must be below `high` (", high, ").", call. = FALSE)
  if (!is.null(low) && low >= nyq)
    stop("Lower cutoff ", low, " Hz is at or above Nyquist (", signif(nyq, 4),
         " Hz) for fs = ", signif(fs, 6), " Hz. There is no signal to keep.",
         call. = FALSE)

  if (!is.null(low) && !is.null(high)) {
    type   <- "pass"
    W      <- c(low, high) / nyq
    cutoff <- c(low, high)
  } else if (!is.null(low)) {
    type   <- "high"
    W      <- low / nyq
    cutoff <- low
  } else {
    type   <- "low"
    W      <- high / nyq
    cutoff <- high
  }

  if (any(W <= 0) || any(W >= 1))
    stop("Normalised cutoff ", paste(signif(W, 4), collapse = ", "),
         " is outside (0, 1). Check `low`/`high` against fs = ", fs, " Hz.",
         call. = FALSE)

  gaps <- fill_gaps(sig)
  if (na_action == "error" && any(gaps$filled))
    stop(sum(gaps$filled), " non-finite sample(s) in signal and ",
         "na_action = \"error\".", call. = FALSE)
  sig_filled <- gaps$signal

  bf <- signal::butter(order, W, type = type)
  check_conditioning(bf, cutoff, fs)

  want_pad <- round(pad_s * fs)
  padded   <- reflect_pad(sig_filled, want_pad)
  if (want_pad > 0 && padded$npad < want_pad)
    message(sprintf(
      paste0("Reflection padding truncated from %.1f s to %.1f s: the signal is ",
             "only %.1f s long. Edge accuracy will be reduced near the ends."),
      want_pad / fs, padded$npad / fs, length(sig_filled) / fs))
  out <- tryCatch(
    as.numeric(signal::filtfilt(bf, padded$signal)),
    error = function(e)
      stop("Filtering failed (", conditionMessage(e), "). This usually means ",
           "the cutoff is too low for the sampling rate, or the signal is ",
           "too short for the padding requested.", call. = FALSE)
  )
  if (padded$npad > 0L)
    out <- out[(padded$npad + 1L):(padded$npad + length(sig_filled))]

  out[gaps$filled] <- NA_real_

  if (!was_recording) return(out)

  res <- x
  res$signal <- out
  add_provenance(res, "filter(%s, %s Hz, order=%d, pad=%gs)",
                 type, paste(signif(cutoff, 4), collapse = "-"), order, pad_s)
}
