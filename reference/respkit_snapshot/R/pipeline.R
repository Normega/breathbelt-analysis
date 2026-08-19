# =====================================================================
#  pipeline.R — the one-call entry point
#
#  WHY THERE ARE TWO FILTERED COPIES
#  ---------------------------------
#  Detection and measurement want different filters and there is no single
#  cutoff that serves both.
#
#  Detection wants an aggressive band-pass. Removing everything outside the
#  respiratory fundamental leaves a near-sinusoid with one unambiguous
#  maximum per cycle, and detection becomes almost trivial.
#
#  Measurement wants a gentle one, because that same aggressive filter
#  destroys the waveform shape being measured. Take 30 synthetic breaths of
#  5 s with a known inspiratory fraction, at 25 Hz with noise 0.01, detected
#  on a 0.05-0.4 Hz band. Reading the peak position off that same filtered
#  signal, versus snapping it onto a 0.05-2 Hz copy first:
#
#      true duty cycle    measured at 0.4 Hz    measured with refinement
#            0.25               0.403                    0.274
#            0.35               0.440                    0.368
#            0.40               0.456                    0.406
#
#  The tight low-pass pulls every duty cycle towards 0.5, because it
#  symmetrises the waveform, and it pulls hardest where the asymmetry is
#  greatest -- that is, where the measurement carries the most information.
#  Nothing in the filtered signal reveals this; the numbers look plausible.
#
#  resp_analyse() therefore builds both copies: it detects on the narrow one
#  and then snaps each extremum onto the wide one before measuring anything.
# =====================================================================

#' Process a respiratory recording end to end
#'
#' Preprocess, detect breaths, and build a per-breath table, optionally
#' summarised over task windows.
#'
#' @param x A `resp_recording`, numeric vector, or path to an `.rds` file.
#' @param fs Sampling rate; required when `x` is a bare numeric vector.
#' @param target_fs Rate to decimate towards. The achieved rate may differ and
#'   is reported honestly; see [resp_downsample()].
#' @param detect_band Two-element band-pass, in Hz, for the detection copy.
#' @param measure_band Two-element band-pass, in Hz, for the copy amplitudes
#'   and phase timings are read from. Set the upper edge well above the
#'   respiratory fundamental. `NULL` measures on the detection copy, which
#'   reproduces the behaviour of most published pipelines and the bias
#'   described above.
#' @param min_prominence,min_distance_s Detection parameters; see
#'   [find_extrema_prominence()].
#'
#' @section The rate ceiling implied by the defaults:
#' Two defaults put an upper bound on the breathing rate this function can
#' see, and exceeding either is the one failure mode that produces a
#' confident, plausible, halved answer:
#'
#' \itemize{
#'   \item `detect_band` upper edge of 0.6 Hz = 36 breaths/min. Above this the
#'     fundamental is filtered out before detection ever runs.
#'   \item `min_distance_s` of 1.5 s = 40 breaths/min. Above this the
#'     refractory period rejects alternate breaths.
#' }
#'
#' Tested against synthetic recordings with known rates, the defaults recover
#' the truth exactly from 4/min to 30/min, across belt and thermistor
#' polarities and sampling rates from 128 Hz to 1000 Hz. At 45/min they report
#' 22.4/min — precisely half — because every other breath is rejected.
#' `resp_quality()` does catch it (the band ratio collapses to 0.03 because
#' the fundamental sits outside the analysis band), so screen on quality
#' before trusting a rate. For paediatric or infant work, raise `detect_band`
#' to something like `c(0.05, 2)` and drop `min_distance_s` to 0.5 or below.
#' @section Duty cycle carries a bias that grows with breathing rate:
#' Refining onto a wider measurement copy removes most of the low-pass
#' symmetrisation described above, but not all of it, and what remains is not a
#' constant offset. At a fixed true duty cycle of 0.30, with everything else
#' held constant and only the breathing rate varied:
#'
#' \tabular{lrrrrrrr}{
#'   rate (/min) \tab 7.5   \tab 10    \tab 12    \tab 15    \tab 20    \tab 24    \tab 30    \cr
#'   measured    \tab 0.310 \tab 0.314 \tab 0.316 \tab 0.320 \tab 0.327 \tab 0.336 \tab 0.340
#' }
#'
#' That shape is the dangerous one. Any manipulation that also changes
#' breathing rate — stress, cognitive load, a paced block — produces a duty
#' cycle change of the same sign for free. If duty cycle is your outcome and
#' rate differs between conditions, covary for rate and say so.
#'
#' It is not an artefact of the synthetic waveform's apex: a smooth
#' phase-warped sine with no derivative corner still shows +0.030 at a true
#' duty of 0.25. It is filter-induced, and shrinks as `measure_band`'s upper
#' edge rises (true duty 0.25 at 24/min): +0.046 at 2 Hz, +0.030 at 3 Hz,
#' +0.022 at 5 Hz, +0.014 at 15 Hz. Amplitude is attenuated the same way and
#' also rate-dependently — 93.7% of truth at 6/min, 89.5% at 30/min.
#'
#' The default upper edge stays at 2 Hz because widening it is not free. With
#' cardiac ripple at 20% of the respiratory amplitude, widening makes duty
#' *worse*, not better: 0.320 at 2 Hz against 0.379 at 5 Hz, because the
#' heartbeat starts displacing the peak. Raise it if your belt is well fitted
#' and `resp_quality()` reports a high band ratio; leave it if not.
#'
#' Note also that at `target_fs = 25` the duty cycle of a 4 s breath is
#' quantised to about 0.006. For morphology work `target_fs = 50` is cheap.
#'
#' @param method Detection method, `"prominence"` or `"zerocross"`.
#' @param polarity `"up"` if the signal rises during inhalation.
#' @param refine_window_s Half-width, in seconds, of the window used to snap
#'   detections from the detection copy onto the measurement copy.
#' @param normalise Normalisation applied before detection. Amplitudes are
#'   reported in these units, so pass `"none"` when you need amplitudes
#'   comparable across participants on a common physical scale.
#' @param despike Apply [resp_despike()] at the native rate first.
#' @param epochs Optional window table from [resp_epochs()]. When supplied,
#'   `features` holds one row per window; otherwise one row overall.
#' @param epoch_rule,epoch_pad_s Passed to [epoch_features()].
#' @param quality Run [resp_quality()] on the raw signal.
#'
#' @return A list with `recording` (the detection copy — the signal detection
#'   ran on), `measure` (the measurement copy, which every amplitude and phase
#'   timing is read from), `detection`, `breaths` (flagged breath table),
#'   `features`, `quality`, `polarity` (the [resp_polarity()] verdict for this
#'   recording, computed from the data and warned about when it contradicts the
#'   `polarity` argument) and `stages`.
#'
#' @examples
#' \dontrun{
#' rec <- resp_read_rds("data/rds/10018.rds")
#' res <- resp_analyse(rec, target_fs = 25)
#' head(res$breaths)
#' res$features
#'
#' # With task windows
#' eps <- resp_epochs(onset = trials$start, offset = trials$stop,
#'                    lag = 0.2, trial = trials$number)
#' res <- resp_analyse(rec, epochs = eps)
#' }
#' @export
resp_analyse <- function(x,
                         fs              = NULL,
                         target_fs       = 25,
                         detect_band     = c(0.05, 0.6),
                         measure_band    = c(0.05, 2.0),
                         min_prominence  = 0.4,
                         min_distance_s  = 1.5,
                         method          = c("prominence", "zerocross"),
                         polarity        = c("up", "down"),
                         refine_window_s = 0.5,
                         normalise       = c("robust", "z", "none"),
                         despike         = TRUE,
                         epochs          = NULL,
                         epoch_rule      = "start",
                         epoch_pad_s     = 0,
                         quality         = TRUE) {

  method    <- match.arg(method)
  polarity  <- match.arg(polarity)
  normalise <- match.arg(normalise)

  if (is.character(x) && length(x) == 1L && file.exists(x)) x <- resp_read_rds(x)
  rec <- as_resp_recording(x, fs = fs)
  warn_if_constant(rec$signal)

  qual <- if (quality)
    tryCatch(resp_quality(rec, target_fs = target_fs),
             error = function(e) list(quality = NA_character_,
                                      note = paste("quality assessment failed:",
                                                   conditionMessage(e))))
  else NULL

  # Common front end: despike at the native rate, then decimate once. Both
  # filtered copies branch from here so they share an identical time base.
  base <- rec
  stages <- list(raw = rec)
  if (isTRUE(despike)) {
    base <- resp_despike(base)
    stages$despiked <- base
  }
  if (!is.null(target_fs) && target_fs < base$fs) {
    base <- resp_downsample(base, target_fs = target_fs)
    stages$downsampled <- base
  }

  make_copy <- function(band) {
    r <- resp_filter(base, low = band[1], high = band[2])
    if (normalise != "none") r <- resp_normalise(r, method = normalise)
    r
  }

  detect_rec <- make_copy(detect_band)
  stages$detect <- detect_rec

  # Identical bands mean an identical copy: filtering and normalising a second
  # time produces a bit-for-bit duplicate and then refinement searches a signal
  # against itself.
  same_band <- !is.null(measure_band) && isTRUE(all.equal(detect_band, measure_band))
  measure_rec <- if (is.null(measure_band) || same_band) detect_rec else make_copy(measure_band)
  if (!is.null(measure_band) && !same_band) stages$measure <- measure_rec

  detection <- resp_detect(
    detect_rec,
    method           = method,
    min_prominence   = min_prominence,
    min_distance_s   = min_distance_s,
    refine_on        = if (is.null(measure_band) || same_band) NULL else measure_rec,
    refine_window_s  = refine_window_s
  )

  bt <- flag_breaths(breath_table(detection, measure_rec, polarity = polarity))

  # Diagnose polarity from the data and say so when it contradicts the
  # argument. In quiet spontaneous breathing inspiration is the shorter phase,
  # so a median duty cycle above 0.5 means the trace is inverted relative to
  # `polarity` -- and an inverted transducer otherwise yields a complete,
  # plausible, silently mirrored breath table: Ti and Te swap, duty cycle
  # becomes its own complement, and flow_in/flow_out exchange meanings.
  # resp_polarity() already computed this verdict but nothing ever called it.
  #
  # Derived from `bt` rather than by calling resp_polarity(), which would build
  # a second breath table and re-emit its warnings.
  dc_up <- stats::median(bt$duty_cycle, na.rm = TRUE)
  if (polarity == "down") dc_up <- 1 - dc_up
  pol <- polarity_verdict(dc_up)
  if (isTRUE(pol$confident) && !identical(pol$suggestion, polarity))
    warning("polarity = \"", polarity, "\" was requested, but the data indicate \"",
            pol$suggestion, "\": ", pol$note, " Every phase-timing column ",
            "(inhale_dur, exhale_dur, duty_cycle, ie_ratio, flow_in, flow_out) ",
            "is mirrored if this is wrong. Check the transducer, or see ",
            "resp_polarity(). This diagnostic assumes quiet spontaneous ",
            "breathing and is uninformative under a symmetric pacer.",
            call. = FALSE)

  features <- if (is.null(epochs))
    summarise_breaths(bt)
  else
    epoch_features(bt, epochs, rule = epoch_rule, pad_s = epoch_pad_s)

  list(
    recording = detect_rec,
    measure   = measure_rec,
    detection = detection,
    breaths   = bt,
    features  = features,
    quality   = qual,
    polarity  = pol,
    stages    = stages
  )
}
