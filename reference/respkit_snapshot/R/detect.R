# =====================================================================
#  detect.R — peak and trough detection
#
#  Two detectors are provided because they fail in different ways.
#
#  find_extrema_zerocross()  Khodadad et al. (2018, Physiol. Meas. 39:094001),
#      the default in NeuroKit2. Segments the signal at zero crossings and
#      takes one extremum per half-cycle, so alternation is guaranteed by
#      construction. Its weakness is that it inherits the definition of
#      "zero": any residual baseline drift shifts the crossings and drags
#      every extremum with them. It needs an aggressive high-pass to behave.
#
#  find_extrema_prominence()  Local maxima filtered by topographic
#      prominence and a refractory distance, the same idea as MATLAB
#      findpeaks and scipy.signal.find_peaks. Prominence is measured against
#      surrounding valleys rather than against zero, so it is indifferent to
#      baseline drift. Its weakness is that it makes no guarantee of
#      alternation, so enforce_alternation() is doing real work rather than
#      acting as a safety net.
#
#  Prefer prominence for belt data with drift; prefer zero-crossing when you
#  want strict parity with NeuroKit2.
# =====================================================================

# Internal: index of the nearest preceding sample strictly greater than x[i],
# or 0 if there is none. Monotonic-stack scan, O(n).
prev_greater_idx <- function(x) {
  n   <- length(x)
  res <- integer(n)
  st  <- integer(n)
  top <- 0L
  for (i in seq_len(n)) {
    while (top > 0L && x[st[top]] <= x[i]) top <- top - 1L
    res[i] <- if (top > 0L) st[top] else 0L
    top <- top + 1L
    st[top] <- i
  }
  res
}

#' Local maxima of a signal, including plateaus
#'
#' A run of equal values that is higher than the samples on both sides counts
#' as one maximum, reported at the centre of the run. The naive test
#' `x[i] > x[i-1] & x[i] > x[i+1]` misses these entirely, which matters
#' whenever the signal has been clamped, quantised coarsely, or saturated.
#'
#' @param x Numeric vector.
#' @return Integer vector of indices.
#' @export
local_maxima <- function(x) {
  n <- length(x)
  if (n < 3L) return(integer(0))

  r      <- rle(x)
  m      <- length(r$lengths)
  if (m < 3L) return(integer(0))
  ends   <- cumsum(r$lengths)
  starts <- ends - r$lengths + 1L

  k <- 2L:(m - 1L)
  is_max <- r$values[k] > r$values[k - 1L] & r$values[k] > r$values[k + 1L]
  # rle() gives every NA its own run, so the comparisons above return NA and
  # would otherwise leak NA indices into what is documented as an integer
  # vector of positions -- which then errors inside peak_prominence().
  is_max[is.na(is_max)] <- FALSE
  if (!any(is_max)) return(integer(0))

  sel <- k[is_max]
  as.integer(starts[sel] + (r$lengths[sel] - 1L) %/% 2L)
}

#' Topographic prominence of peaks
#'
#' Prominence is the vertical drop required to leave a peak and reach any
#' higher ground. It is measured from the peak down to the higher of the two
#' minima found between the peak and the nearest strictly higher sample on
#' each side.
#'
#' @section Difference from the original implementation:
#' The pipeline this replaces bounded each search at the nearest higher
#' *detected local maximum* rather than the nearest higher *sample*. That
#' turns out to make no difference on continuous data: any sample higher than
#' the peak belongs to a run whose own maximum is a local maximum at least as
#' high, so the two bounds coincide. Across 300 continuous random signals the
#' two rules never disagreed, and across the ~156,000 peaks of a 198-recording
#' archive they gave bit-identical prominences.
#'
#' They do diverge when peak heights are exactly equal: the original stopped
#' at a peak of *equal* height, whereas the standard definition walks past it.
#' On data rounded to one decimal place that changed the answer for two thirds
#' of signals. This implementation matches MATLAB `findpeaks` and
#' `scipy.signal.peak_prominences`, is robust to ties, and runs in `O(n)`
#' rather than `O(n^2)`.
#'
#' @param x Numeric vector.
#' @param peaks Integer indices of peaks in `x`.
#' @return Numeric vector of prominences, same length as `peaks`.
#' @export
peak_prominence <- function(x, peaks) {
  if (!length(peaks)) return(numeric(0))
  # The monotonic-stack scan compares values directly, so a single NA makes an
  # `if (NA)` deep inside it and the user gets "missing value where TRUE/FALSE
  # needed", naming neither the argument nor the function.
  if (any(!is.finite(x)))
    stop("`x` contains ", sum(!is.finite(x)), " non-finite value(s). ",
         "Prominence is undefined across a gap; interpolate or trim first ",
         "(resp_detect() does this for you).", call. = FALSE)
  n <- length(x)

  left_bound  <- prev_greater_idx(x)
  right_bound <- (n + 1L) - rev(prev_greater_idx(rev(x)))
  right_bound[right_bound > n] <- n + 1L

  vapply(peaks, function(p) {
    lo <- left_bound[p]  + 1L
    hi <- right_bound[p] - 1L
    lo <- max(lo, 1L)
    hi <- min(hi, n)
    left_min  <- min(x[lo:p])
    right_min <- min(x[p:hi])
    x[p] - max(left_min, right_min)
  }, numeric(1))
}

# Internal: greedy refractory-period filter. Peaks are accepted in order of
# descending prominence; a candidate is rejected if an already-accepted peak
# lies within min_dist samples. This is the standard approach (MATLAB
# MinPeakDistance) and is deterministic, unlike the pairwise sweep it
# replaces, which could remove a peak whose only close neighbour had already
# been removed earlier in the same pass.
enforce_min_distance <- function(idx, prominence, min_dist) {
  if (length(idx) < 2L || min_dist < 1) return(seq_along(idx))
  ord      <- order(prominence, decreasing = TRUE)
  accepted <- integer(0)
  for (i in ord) {
    if (!length(accepted) || all(abs(idx[i] - idx[accepted]) >= min_dist))
      accepted <- c(accepted, i)
  }
  sort(accepted)
}

#' Detect respiratory extrema by prominence
#'
#' @param x Numeric vector, usually filtered and normalised.
#' @param fs Sampling rate in Hz.
#' @param min_prominence Minimum prominence, in the units of `x`. On a
#'   robust-normalised signal a value near 0.5 keeps only clear breaths;
#'   values near 0.15 are permissive and will admit cardiac ripple on a
#'   loosely fitted belt.
#' @param min_distance_s Refractory period in seconds. Adults rarely breathe
#'   faster than 30/min at rest, so 1-2 s is a safe floor; raise it for paced
#'   breathing protocols.
#' @return List with integer `peaks` and `troughs`.
#' @export
find_extrema_prominence <- function(x, fs,
                                    min_prominence = 0.5,
                                    min_distance_s = 1) {

  min_dist <- max(1L, round(min_distance_s * fs))

  detect_one <- function(v) {
    idx <- local_maxima(v)
    if (!length(idx)) return(integer(0))
    prom <- peak_prominence(v, idx)
    keep <- prom >= min_prominence
    idx  <- idx[keep]
    prom <- prom[keep]
    if (length(idx) < 2L) return(idx)
    idx[enforce_min_distance(idx, prom, min_dist)]
  }

  list(peaks   = detect_one(x),
       troughs = detect_one(-x))
}

#' Detect respiratory extrema by zero-crossing segmentation
#'
#' Implements Khodadad et al. (2018): the signal is cut at every zero
#' crossing, one extremum is taken per half-cycle, and extrema whose vertical
#' distance to their neighbours is small relative to the recording average are
#' discarded as noise.
#'
#' @param x Numeric vector. Should already be high-passed to remove drift.
#' @param amplitude_min Fraction of the mean adjacent vertical distance below
#'   which an extremum is discarded. 0.3 is the NeuroKit2 default.
#' @param centre How to place the zero line before segmenting: `"mean"`
#'   (default, matching Khodadad and NeuroKit2), `"median"`, or `"none"` to
#'   use the signal as supplied.
#'
#' @section Why centring is done here rather than left to the caller:
#' This algorithm defines a breath cycle entirely by where the signal crosses
#' zero, so it is only correct when zero sits at the signal's centre. That
#' makes it quietly sensitive to how the signal was normalised upstream.
#' Robust normalisation centres on the median, and for asymmetric breathing
#' the median sits well below the mean, because the signal spends longer near
#' the bottom of each cycle than near the top. Take 40 synthetic breaths with
#' an inspiratory fraction of 0.4, band-pass them 0.05-1 Hz and normalise with
#' `method = "robust"`: the mean of the result sits at -0.2005 while the
#' median is at zero. Under the pre-fix strict-inequality partition that
#' displacement left the crossings intact but made the half-cycles so unequal
#' that the amplitude filter discarded 26 of the 40 breaths, returning 14
#' peaks. Centring inside the function removes the dependence on the caller's
#' choice: 40 of 40 either way.
#'
#' @return List with integer `peaks` and `troughs`.
#' @export
find_extrema_zerocross <- function(x, amplitude_min = 0.3,
                                   centre = c("mean", "median", "none")) {
  centre <- match.arg(centre)
  x <- switch(centre,
              mean   = x - mean(x, na.rm = TRUE),
              median = x - stats::median(x, na.rm = TRUE),
              none   = x)

  n <- length(x)
  if (n < 3L) return(list(peaks = integer(0), troughs = integer(0)))

  # Samples sitting exactly at zero must be assigned to one side, not to
  # neither. Testing `x > 0` and `x < 0` separately leaves an exact zero in
  # neither class, so a crossing that lands on it is invisible. That is not an
  # exotic case: a quantised signal centred on its median puts many samples
  # exactly at zero, because the median of quantised data is itself one of the
  # quantisation levels. The consequence was a halved breath count with no
  # warning. A two-way partition also guarantees that rises and falls strictly
  # alternate, which the half-cycle parity below depends on.
  positive <- x >= 0

  rise <- which(!positive[-n] &  positive[-1L])
  fall <- which( positive[-n] & !positive[-1L])

  if (!length(rise) || !length(fall)) {
    warning("No zero crossings found: the signal never changes sign. It is ",
            "flat, or its centre is not at zero. High-pass it and check the ",
            "`centre` argument before calling this detector.", call. = FALSE)
    return(list(peaks = integer(0), troughs = integer(0)))
  }

  # Whether the first segment is a positive or negative half-cycle depends on
  # which kind of crossing comes first.
  first_is_positive <- rise[1L] < fall[1L]

  cuts   <- sort(c(rise, fall))
  n_segs <- length(cuts) - 1L
  if (n_segs < 1L) return(list(peaks = integer(0), troughs = integer(0)))

  extrema  <- integer(n_segs)
  is_peak  <- logical(n_segs)
  for (k in seq_len(n_segs)) {
    beg <- cuts[k]
    end <- cuts[k + 1L]
    seg <- x[beg:end]
    seek_max <- xor(k %% 2L == 1L, !first_is_positive)
    off <- if (seek_max) which.max(seg) else which.min(seg)
    extrema[k] <- beg + off - 1L
    is_peak[k] <- seek_max
  }

  # Amplitude-based rejection: for each extremum take the smaller of the two
  # vertical distances to its neighbours, and drop it if that is a small
  # fraction of the mean distance across the recording.
  if (length(extrema) >= 3L) {
    vert <- abs(diff(x[extrema]))
    n_ex <- length(extrema)
    min_adj <- numeric(n_ex)
    min_adj[1L]    <- vert[1L]
    min_adj[n_ex]  <- vert[n_ex - 1L]
    min_adj[2L:(n_ex - 1L)] <- pmin(vert[1L:(n_ex - 2L)], vert[2L:(n_ex - 1L)])
    keep    <- min_adj >= amplitude_min * mean(vert)
    extrema <- extrema[keep]
    is_peak <- is_peak[keep]
  }

  if (!length(extrema)) return(list(peaks = integer(0), troughs = integer(0)))

  # Classify by which half-cycle the extremum came from, not by the sign of
  # its value. A shallow breath can have its peak below zero (or its trough
  # above it) whenever the centring is even slightly off, and re-deriving the
  # label from the value would then mislabel it and break alternation.
  list(peaks   = as.integer(extrema[is_peak]),
       troughs = as.integer(extrema[!is_peak]))
}

#' Snap detected extrema onto a reference signal
#'
#' Detection often runs on an aggressively filtered copy of the signal, which
#' shifts extrema by a sample or two relative to the signal you actually want
#' to measure. This walks each index to the true local extremum within a
#' bounded neighbourhood of the reference.
#'
#' @param x Reference signal to snap onto.
#' @param indices Integer indices to refine.
#' @param seek_max `TRUE` for peaks, `FALSE` for troughs.
#' @param window_s Half-width of the search neighbourhood in seconds.
#' @param fs Sampling rate.
#'
#' @details
#' Keep `window_s` well below half a breath period. Too large a window lets an
#' extremum jump onto the neighbouring breath, which silently deletes one
#' cycle and doubles the duration of another.
#' @export
refine_extrema <- function(x, indices, seek_max, window_s = 0.4, fs) {
  if (!length(indices)) return(as.integer(indices))
  indices <- as.integer(round(indices))
  w <- as.integer(round(window_s * fs))
  if (w < 1L) return(indices)
  n <- length(x)
  vapply(indices, function(i) {
    lo  <- max(1L, i - w)
    hi  <- min(n,  i + w)
    seg <- x[lo:hi]
    # which.max/which.min return the FIRST index of a tie, which would snap
    # every extremum to the left edge of a plateau. local_maxima() reports the
    # centre of a flat run, and reverting that here biases peak times early on
    # any clamped, saturated or coarsely quantised signal -- at the default
    # window this read a true duty cycle of 0.40 as 0.33. Take the centre of
    # the tied set instead, matching local_maxima().
    # na.rm, and a fallback when the whole window is missing: without it
    # max(seg) is NA, `which(seg == NA)` is empty, and vapply dies with a
    # length-0 result rather than saying anything useful.
    tgt <- if (seek_max) suppressWarnings(max(seg, na.rm = TRUE))
           else          suppressWarnings(min(seg, na.rm = TRUE))
    if (!is.finite(tgt)) return(i)
    best <- which(seg == tgt)
    lo + best[(length(best) + 1L) %/% 2L] - 1L
  }, integer(1))
}

#' Force peaks and troughs to alternate
#'
#' Merges peaks and troughs into one time-ordered sequence and collapses any
#' run of consecutive same-type events down to a single event.
#'
#' @param peaks,troughs Integer index vectors into the same signal.
#' @param values Optional numeric signal. Required for `rule = "extreme"`.
#' @param rule How to choose the survivor of a run. `"extreme"` (default)
#'   keeps the highest peak or lowest trough, which is the physiologically
#'   correct answer: if two peaks share a breath cycle, the cycle's peak is
#'   the higher of the two. `"nearest"` keeps whichever is closest in time to
#'   the following event of the opposite type, reproducing the behaviour of
#'   the original pipeline.
#'
#' @return List with cleaned `peaks` and `troughs`.
#' @export
enforce_alternation <- function(peaks, troughs, values = NULL,
                                rule = c("extreme", "nearest")) {
  rule <- match.arg(rule)
  if (!length(peaks) && !length(troughs))
    return(list(peaks = peaks, troughs = troughs))
  if (rule == "extreme" && is.null(values))
    stop("`values` (the signal) is required when rule = \"extreme\".", call. = FALSE)

  # Out-of-range indices must be refused, not tolerated. Under rule =
  # "extreme" they make values[...] all-NA, which makes which.max() return
  # integer(0), which makes the assignment a no-op -- so an entire run of
  # events would vanish with no error at all.
  all_idx <- c(peaks, troughs)
  if (anyNA(all_idx))
    stop("`peaks`/`troughs` contain NA. Detection indices must be complete.",
         call. = FALSE)
  if (length(all_idx) && min(all_idx) < 1L)
    stop("Detection indices must be 1-based and positive; the smallest is ",
         min(all_idx), ".", call. = FALSE)
  if (!is.null(values) && length(all_idx) && max(all_idx) > length(values))
    stop("Detection index ", max(all_idx), " exceeds the length of `values` (",
         length(values), "). The indices and the signal do not correspond.",
         call. = FALSE)
  dup <- intersect(peaks, troughs)
  if (length(dup))
    stop(length(dup), " index/indices appear as both a peak and a trough (first: ",
         dup[1], "). A sample cannot be both.", call. = FALSE)

  idx  <- c(peaks, troughs)
  type <- c(rep(1L, length(peaks)), rep(0L, length(troughs)))
  ord  <- order(idx)
  idx  <- idx[ord]
  type <- type[ord]

  n <- length(idx)
  keep <- logical(n)
  i <- 1L
  while (i <= n) {
    j <- i
    while (j < n && type[j + 1L] == type[i]) j <- j + 1L

    if (i == j) {
      keep[i] <- TRUE
    } else if (rule == "extreme") {
      v <- values[idx[i:j]]
      # which.max on an all-NA vector returns integer(0), so keep[integer(0)]
      # is a no-op and the entire run would vanish -- from the function whose
      # job is to guarantee alternation. Fall back to the middle of the run.
      pick <- if (all(is.na(v))) (length(v) + 1L) %/% 2L
              else if (type[i] == 1L) which.max(v) else which.min(v)
      keep[i - 1L + pick] <- TRUE
    } else {
      best <- if (j < n) i - 1L + which.min(abs(idx[i:j] - idx[j + 1L])) else j
      keep[best] <- TRUE
    }
    i <- j + 1L
  }

  list(peaks   = idx[keep & type == 1L],
       troughs = idx[keep & type == 0L])
}

#' Detect breaths in a recording
#'
#' The single entry point for detection. Runs a detector, optionally snaps the
#' result onto a less-filtered reference signal, and forces alternation.
#'
#' @param x A `resp_recording` (or numeric vector plus `fs`) to detect on.
#'   This should be filtered and normalised.
#' @param fs Sampling rate; required for bare numeric input.
#' @param method `"prominence"` (default) or `"zerocross"`.
#' @param min_prominence,min_distance_s Passed to [find_extrema_prominence()].
#' @param amplitude_min Passed to [find_extrema_zerocross()].
#' @param zerocross_centre Passed to [find_extrema_zerocross()] as `centre`.
#' @param refine_on Optional `resp_recording` or numeric vector, at the same
#'   sampling rate and length as `x`, onto which detected extrema are snapped.
#'   Use this to detect on a heavily high-passed copy while measuring on a
#'   gently filtered one.
#' @param refine_window_s Half-width of the snapping window, in seconds.
#' @param alternation_rule Passed to [enforce_alternation()]; `"none"` skips
#'   the step, which is useful when diagnosing a detector.
#'
#' @return A list with `peaks` and `troughs` (integer indices), `peak_times`
#'   and `trough_times` (seconds on the recording clock), `fs`, `t0`,
#'   `method`, and `n_raw` giving the counts before refinement and alternation.
#' @export
resp_detect <- function(x, fs = NULL,
                        method           = c("prominence", "zerocross"),
                        min_prominence   = 0.5,
                        min_distance_s   = 1,
                        amplitude_min    = 0.3,
                        zerocross_centre = "mean",
                        refine_on        = NULL,
                        refine_window_s  = 0.4,
                        alternation_rule = c("extreme", "nearest", "none")) {

  method           <- match.arg(method)
  alternation_rule <- match.arg(alternation_rule)

  rec <- as_resp_recording(x, fs = fs)
  sig <- rec$signal
  fs  <- rec$fs

  if (any(!is.finite(sig))) {
    n_bad <- sum(!is.finite(sig))
    warning(n_bad, " non-finite sample(s) interpolated before detection. ",
            "Detections in those regions are not trustworthy.", call. = FALSE)
    sig <- fill_gaps(sig)$signal
  }

  ext <- switch(
    method,
    prominence = find_extrema_prominence(sig, fs,
                                         min_prominence = min_prominence,
                                         min_distance_s = min_distance_s),
    zerocross  = find_extrema_zerocross(sig, amplitude_min = amplitude_min,
                                        centre = zerocross_centre)
  )

  # Counted before refinement, so that a collapse during refinement is
  # visible by comparing these against the final counts.
  n_detected <- c(peaks = length(ext$peaks), troughs = length(ext$troughs))

  measure_sig <- sig
  if (!is.null(refine_on)) {
    ref <- as_resp_recording(refine_on, fs = fs)
    if (length(ref$signal) != length(sig))
      stop("`refine_on` has ", length(ref$signal), " samples but `x` has ",
           length(sig), ". They must be the same signal at the same rate.",
           call. = FALSE)
    measure_sig  <- fill_gaps(ref$signal)$signal
    ext$peaks    <- refine_extrema(measure_sig, ext$peaks,   TRUE,  refine_window_s, fs)
    ext$troughs  <- refine_extrema(measure_sig, ext$troughs, FALSE, refine_window_s, fs)

    # Two extrema snapping onto the same sample means one breath has been
    # merged into its neighbour. Collapsing them quietly would leave a cycle
    # of double the true duration in the breath table.
    lost_p <- length(ext$peaks)   - length(unique(ext$peaks))
    lost_t <- length(ext$troughs) - length(unique(ext$troughs))
    if (lost_p + lost_t > 0L)
      warning(lost_p, " peak(s) and ", lost_t, " trough(s) snapped onto a ",
              "sample already taken and were merged. refine_window_s (",
              refine_window_s, " s) is too large for the breath rate here; ",
              "reduce it to well under half a breath period.", call. = FALSE)
    ext$peaks    <- unique(ext$peaks)
    ext$troughs  <- unique(ext$troughs)

    # A peak and a trough can also land on the *same* sample, which happens in
    # a near-flat stretch where the two searches converge. Such a sample is
    # neither: it describes a cycle of zero amplitude. Drop it from both sets
    # rather than passing a self-contradictory detection downstream.
    collided <- intersect(ext$peaks, ext$troughs)
    if (length(collided)) {
      warning(length(collided), " sample(s) were selected as both a peak and a ",
              "trough after refinement and have been discarded. This means the ",
              "signal is essentially flat there; check resp_quality() for that ",
              "stretch.", call. = FALSE)
      ext$peaks   <- setdiff(ext$peaks,   collided)
      ext$troughs <- setdiff(ext$troughs, collided)
    }
  }

  if (alternation_rule != "none") {
    ext <- enforce_alternation(ext$peaks, ext$troughs,
                               values = measure_sig, rule = alternation_rule)
  }

  t <- resp_time(rec)
  list(
    peaks        = as.integer(ext$peaks),
    troughs      = as.integer(ext$troughs),
    peak_times   = t[ext$peaks],
    trough_times = t[ext$troughs],
    fs           = fs,
    t0           = rec$t0,
    n_raw        = n_detected,
    method       = method
  )
}
