# =====================================================================
#  breaths.R — the per-breath morphology table
#
#  This is the main analytic addition over the pipeline being replaced.
#  That pipeline detected both peaks and troughs but derived every feature
#  from trough times alone: breath duration, mean rate, and a slope of
#  duration across breath position. Peaks were used only to decide where a
#  trial window began. The peak-to-trough excursion, the split of a cycle
#  into inspiratory and expiratory phases, and everything derived from
#  them, were computed nowhere.
#
#  A respiratory cycle is defined here as trough -> peak -> trough:
#
#        peak                      amplitude = peak - trough
#         /\                       Ti  = inspiratory duration
#        /  \                      Te  = expiratory duration
#       /    \                     Ttot = Ti + Te
#      /      \___                 duty cycle = Ti / Ttot
#   trough      trough             RVT = amplitude / Ttot
#     |<-Ti->|<-Te->|
#
#  Duration and rate reproduce what the original computed. Everything else
#  is new, and several of the new columns are standard in the respiratory
#  literature: duty cycle (Ti/Ttot) is the classic index of respiratory
#  drive timing, and respiratory volume per time is the regressor used
#  throughout the physiological-noise-correction literature.
# =====================================================================

#' Build a per-breath table from detected extrema
#'
#' @param detection Output of [resp_detect()], or a list carrying at least
#'   `peaks`, `troughs` and `fs`.
#' @param recording The `resp_recording` (or numeric vector) from which
#'   amplitudes are read. Indices in `detection` must refer to this signal.
#'   Pass the *unnormalised* signal when you need amplitudes that are
#'   comparable across participants.
#' @param polarity `"up"` (default) if the signal increases during
#'   inhalation, which is the convention for a chest or abdominal
#'   strain-gauge belt. `"down"` for transducers that fall on inhalation,
#'   such as an uninverted nasal thermistor. See [resp_polarity()] for a
#'   diagnostic.
#' @param min_duration_s,max_duration_s Physiological bounds. Cycles outside
#'   them are retained but flagged in the `implausible` column rather than
#'   silently dropped, so that a QC pass can see how much was rejected.
#'
#'   Note that `min_duration_s` cannot fire under [resp_analyse()]'s defaults:
#'   `min_distance_s = 1.5` already makes consecutive troughs at least 1.5 s
#'   apart, so no cycle shorter than that can reach here. It becomes live if
#'   you lower `min_distance_s` for paediatric work, or build the table from a
#'   detection produced some other way.
#'
#' @return A data frame with one row per complete respiratory cycle:
#' \describe{
#'   \item{breath}{Sequential index within the recording.}
#'   \item{i_start, i_peak, i_end}{Sample indices of the opening trough, the
#'     peak, and the closing trough.}
#'   \item{t_start, t_peak, t_end}{The same points in seconds on the
#'     recording clock.}
#'   \item{duration}{Cycle duration Ttot, seconds.}
#'   \item{inhale_dur, exhale_dur}{Ti and Te, seconds.}
#'   \item{duty_cycle}{Ti / Ttot. Around 0.4 in quiet spontaneous breathing;
#'     forced towards 0.5 by a symmetric pacer or by an over-tight low-pass.
#'     A residual upward bias survives even a well-chosen measurement band and
#'     grows with breathing rate — see the duty-cycle section of
#'     [resp_analyse()] before comparing it across conditions whose rates
#'     differ.}
#'   \item{ie_ratio}{Ti / Te.}
#'   \item{rate_bpm}{Instantaneous rate, 60 / duration.}
#'   \item{amp_inhale, amp_exhale}{Peak minus opening trough, and peak minus
#'     closing trough, in the units of `recording`.}
#'   \item{amplitude}{Mean of the two excursions.}
#'   \item{baseline}{Signal value at the opening trough: the end-expiratory
#'     level. A drifting baseline across a run indicates belt slippage or
#'     changing posture.}
#'   \item{rvt}{Respiratory volume per time, amplitude / duration.}
#'   \item{flow_in, flow_out}{Mean inspiratory and expiratory slope,
#'     excursion divided by phase duration.}
#'   \item{has_peak}{`FALSE` when no peak was found between the two troughs.
#'     Such a cycle still has a valid duration, so it is kept, but every
#'     peak-derived column is `NA`. [summarise_breaths()] reports the count as
#'     `n_breaths_no_peak` so that the smaller denominator behind
#'     `duty_cycle_mean` and the amplitude statistics stays visible. After
#'     [enforce_alternation()] this should never occur; if it does, detection
#'     needs looking at.}
#'   \item{implausible}{`TRUE` if the duration falls outside the bounds.}
#' }
#' The `units` attribute records the units of the amplitude columns.
#' @export
breath_table <- function(detection,
                         recording,
                         polarity       = c("up", "down"),
                         min_duration_s = 0.8,
                         max_duration_s = 20) {

  polarity <- match.arg(polarity)

  if (!all(c("peaks", "troughs") %in% names(detection)))
    stop("`detection` must contain `peaks` and `troughs`.", call. = FALSE)

  rec <- as_resp_recording(recording,
                           fs = if (!is.null(detection$fs)) detection$fs else NULL)
  sig <- rec$signal
  fs  <- rec$fs
  tt  <- resp_time(rec)

  peaks   <- as.integer(detection$peaks)
  troughs <- as.integer(detection$troughs)

  # Validate before anything else. An index of 0 does not error in R: sig[0]
  # returns a zero-length vector, so the column is silently recycled and the
  # times of *unaffected* breaths come out wrong too. Checking after the
  # polarity swap or after the n_out early return would let both slip through.
  if (anyNA(peaks) || anyNA(troughs))
    stop("`detection` contains NA indices. Detection must be complete before ",
         "a breath table can be built.", call. = FALSE)
  all_idx <- c(peaks, troughs)
  if (length(all_idx)) {
    if (min(all_idx) < 1L)
      stop("Detection indices must be 1-based and positive; the smallest is ",
           min(all_idx), ".", call. = FALSE)
    if (max(all_idx) > length(sig))
      stop("Detection indices run past the end of `recording` (max index ",
           max(all_idx), " vs ", length(sig), " samples). Detection and ",
           "recording must refer to the same signal.", call. = FALSE)
  }

  peaks   <- sort(peaks)
  troughs <- sort(troughs)

  if (polarity == "down") {
    tmp     <- peaks
    peaks   <- troughs
    troughs <- tmp
    sig     <- -sig
  }

  n_out <- max(0L, length(troughs) - 1L)
  if (n_out == 0L)
    return(empty_breath_table(rec$units, fs = fs, polarity = polarity,
                              id = rec$id))

  # One peak per cycle. findInterval counts how many peaks precede each
  # closing trough; the difference across a trough pair is the peak count in
  # that cycle. Where alternation was enforced this is always 0 or 1.
  n_before <- findInterval(troughs, peaks)
  starts   <- troughs[-length(troughs)]
  ends     <- troughs[-1L]
  n_in     <- n_before[-1L] - n_before[-length(n_before)]

  has_peak <- n_in == 1L
  i_peak   <- rep(NA_integer_, n_out)
  i_peak[has_peak] <- peaks[n_before[-length(n_before)][has_peak] + 1L]

  if (any(n_in > 1L))
    warning(sum(n_in > 1L), " cycle(s) contain more than one peak. Run ",
            "enforce_alternation() before building a breath table, or these ",
            "cycles will have no peak-derived features.", call. = FALSE)
  if (any(n_in == 0L))
    warning(sum(n_in == 0L), " cycle(s) contain no peak at all. They keep a ",
            "valid duration but every peak-derived column is NA; see the ",
            "has_peak column and n_breaths_no_peak. After enforce_alternation() ",
            "this should not happen, so check the detection.", call. = FALSE)

  t_start <- tt[starts]
  t_end   <- tt[ends]
  t_peak  <- ifelse(is.na(i_peak), NA_real_, tt[pmax(i_peak, 1L)])

  duration   <- t_end - t_start
  inhale_dur <- t_peak - t_start
  exhale_dur <- t_end  - t_peak

  amp_inhale <- sig[pmax(i_peak, 1L)] - sig[starts]
  amp_exhale <- sig[pmax(i_peak, 1L)] - sig[ends]
  amp_inhale[is.na(i_peak)] <- NA_real_
  amp_exhale[is.na(i_peak)] <- NA_real_
  amplitude  <- rowMeans(cbind(amp_inhale, amp_exhale))

  out <- data.frame(
    breath      = seq_len(n_out),
    i_start     = starts,
    i_peak      = i_peak,
    i_end       = ends,
    t_start     = t_start,
    t_peak      = t_peak,
    t_end       = t_end,
    duration    = duration,
    inhale_dur  = inhale_dur,
    exhale_dur  = exhale_dur,
    duty_cycle  = inhale_dur / duration,
    ie_ratio    = inhale_dur / exhale_dur,
    rate_bpm    = 60 / duration,
    amp_inhale  = amp_inhale,
    amp_exhale  = amp_exhale,
    amplitude   = amplitude,
    # Reported on the recording's own scale. Every other amplitude column is a
    # difference, so the negation applied for polarity = "down" cancels out of
    # it; baseline is the one absolute level, and left negated it would invert
    # the apparent direction of belt drift.
    baseline    = if (polarity == "down") -sig[starts] else sig[starts],
    rvt         = amplitude / duration,
    flow_in     = amp_inhale / inhale_dur,
    flow_out    = amp_exhale / exhale_dur,
    has_peak    = !is.na(i_peak),
    implausible = duration < min_duration_s | duration > max_duration_s,
    stringsAsFactors = FALSE
  )

  attr(out, "units")    <- rec$units
  attr(out, "fs")       <- fs
  attr(out, "polarity") <- polarity
  attr(out, "id")       <- rec$id
  out
}

# Internal: a zero-row table with the right columns, so that downstream code
# can bind results without special-casing participants who produced nothing.
empty_breath_table <- function(units = "arbitrary", fs = NA_real_,
                               polarity = NA_character_, id = NA_character_) {
  out <- data.frame(
    breath = integer(0), i_start = integer(0), i_peak = integer(0),
    i_end = integer(0), t_start = numeric(0), t_peak = numeric(0),
    t_end = numeric(0), duration = numeric(0), inhale_dur = numeric(0),
    exhale_dur = numeric(0), duty_cycle = numeric(0), ie_ratio = numeric(0),
    rate_bpm = numeric(0), amp_inhale = numeric(0), amp_exhale = numeric(0),
    amplitude = numeric(0), baseline = numeric(0), rvt = numeric(0),
    flow_in = numeric(0), flow_out = numeric(0), has_peak = logical(0),
    implausible = logical(0)
  )
  attr(out, "units")    <- units
  attr(out, "fs")       <- fs
  attr(out, "polarity") <- polarity
  attr(out, "id")       <- id
  out
}

#' Diagnose the polarity of a respiratory signal
#'
#' Reports evidence about whether the signal rises or falls during
#' inhalation, so you can set `polarity` in [breath_table()] deliberately
#' rather than by assumption.
#'
#' @param detection Output of [resp_detect()].
#' @param recording The `resp_recording` the detection refers to.
#'
#' @return A list with `duty_cycle_up` (median duty cycle assuming the signal
#'   rises on inhalation), `duty_cycle_down` (its complement), `suggestion`,
#'   `confident`, and `note` explaining the verdict in words.
#'
#' @details
#' The diagnostic rests on inspiration being shorter than expiration in quiet
#' spontaneous breathing, so the correct polarity is the one giving a median
#' duty cycle below 0.5. This is genuinely uninformative under paced
#' breathing with a symmetric pacer, where both polarities give roughly 0.5;
#' `confident` is `FALSE` in that case and you should determine polarity from
#' the transducer documentation instead.
#' @export
resp_polarity <- function(detection, recording) {
  bt <- breath_table(detection, recording, polarity = "up")
  polarity_verdict(if (nrow(bt)) stats::median(bt$duty_cycle, na.rm = TRUE)
                   else NA_real_)
}

# Internal: the verdict itself, given the median duty cycle computed under the
# assumption that the signal RISES on inhalation.
#
# Split out from resp_polarity() so that resp_analyse() can reach the same
# conclusion from the breath table it has already built instead of building a
# second one, and so that every path returns the same five fields in the same
# order. The old early return omitted `note`, which is the shape bug that makes
# a cohort rbind() recycle one column's values into another.
polarity_verdict <- function(dc_up) {
  if (!is.finite(dc_up))
    return(list(duty_cycle_up = NA_real_, duty_cycle_down = NA_real_,
                suggestion = NA_character_, confident = FALSE,
                note = paste0("No cycle had both a peak and two bounding ",
                              "troughs, so duty cycle is undefined and ",
                              "polarity cannot be diagnosed from the data.")))

  gap <- abs(dc_up - 0.5)
  list(
    duty_cycle_up   = dc_up,
    duty_cycle_down = 1 - dc_up,
    suggestion      = if (dc_up < 0.5) "up" else "down",
    confident       = gap >= 0.05,
    note = if (gap < 0.05)
      paste0("Median duty cycle is ", sprintf("%.3f", dc_up),
             ", too close to 0.5 to distinguish polarity. This is expected ",
             "under paced breathing with a symmetric pacer, or when the ",
             "low-pass cutoff is tight enough to sinusoidalise the signal. ",
             "Set polarity from the transducer specification.")
    else
      paste0("Median duty cycle assuming rise-on-inhale is ",
             sprintf("%.3f", dc_up), "; inspiration is normally the shorter ",
             "phase, so polarity \"", if (dc_up < 0.5) "up" else "down",
             "\" is indicated.")
  )
}

#' Flag implausible or outlying breaths
#'
#' Adds QC columns to a breath table without removing anything, so that the
#' proportion rejected is always visible and reportable.
#'
#' @param bt A breath table from [breath_table()].
#' @param amplitude_min_frac Amplitude below this fraction of the recording's
#'   median amplitude is flagged as `low_amplitude`. Default 0.2.
#' @param duration_mad Cycles whose duration is more than this many median
#'   absolute deviations from the median are flagged as `duration_outlier`.
#'   Default 5.
#'
#' @return `bt` with added logical columns `bad_amplitude`, `low_amplitude`,
#'   `duration_outlier` and `keep`. Note that `keep` can be `TRUE` for a cycle
#'   whose `has_peak` is `FALSE`: such a cycle has a genuine duration but no
#'   peak-derived features, and is counted by
#'   [summarise_breaths()] as `n_breaths_no_peak`.
#' @export
flag_breaths <- function(bt, amplitude_min_frac = 0.2, duration_mad = 5) {
  if (!nrow(bt)) {
    bt$bad_amplitude    <- logical(0)
    bt$low_amplitude    <- logical(0)
    bt$duration_outlier <- logical(0)
    bt$keep             <- logical(0)
    return(bt)
  }

  # A respiratory cycle rises from a trough to a peak and falls back, so its
  # excursion cannot be zero or negative. When it is, the "peak" sits below one
  # of its own bounding troughs and the cycle is an artefact of detection on a
  # signal with no real variation -- normalising a trace that is constant to
  # machine precision amplifies floating-point noise into something that looks
  # like a waveform. Checked explicitly because the relative test below cannot
  # fire when the median amplitude is itself negative.
  bt$bad_amplitude <- !is.na(bt$amplitude) & bt$amplitude <= 0

  med_amp <- stats::median(bt$amplitude, na.rm = TRUE)
  bt$low_amplitude <- if (is.finite(med_amp) && med_amp > 0)
    !is.na(bt$amplitude) & bt$amplitude < amplitude_min_frac * med_amp
  else rep(FALSE, nrow(bt))

  med_dur <- stats::median(bt$duration, na.rm = TRUE)
  mad_dur <- stats::mad(bt$duration, na.rm = TRUE)

  # The guard has to be a RELATIVE epsilon, not `> 0`. Durations are
  # differences of floating-point sample times, so when most of them are
  # nominally identical the MAD is not exactly zero but a residue around
  # 1e-15. A bare `> 0` passes, the threshold becomes a few femtoseconds, and
  # every cycle not bit-identical to the median is declared an outlier: on
  # metronomic breathing that rejects about half the breaths and collapses
  # duration_sd, duration_cv and duration_rmssd to ~1e-15 -- destroying the
  # variability measures on exactly the recordings where regularity is the
  # finding, and dragging epoch coverage down with them. cv() in features.R
  # already uses this idiom.
  #
  # Note this removes the cliff rather than moving it. The rule below is
  # scale-invariant -- deviations of a uniform size can never exceed five
  # times their own MAD, at any magnitude -- so the failure needed a MAD far
  # smaller than the real deviations, which only happens when the MAD is a
  # float residue. Verified across residue magnitudes from 1e-12 to 1e-2.
  mad_tol <- .Machine$double.eps^0.5 * max(1, abs(med_dur))
  bt$duration_outlier <- if (is.finite(mad_dur) && mad_dur > mad_tol)
    !is.na(bt$duration) & abs(bt$duration - med_dur) > duration_mad * mad_dur
  else rep(FALSE, nrow(bt))

  bt$keep <- !bt$implausible & !bt$bad_amplitude & !bt$low_amplitude &
    !bt$duration_outlier & !is.na(bt$duration)
  bt
}
