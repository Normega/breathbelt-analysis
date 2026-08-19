# onsets.R
#
# THE breath-onset detector. Sourced by BOTH scripts/02_estimate_variance_components.R
# and the confirmatory analysis, so that the variance components describe the
# same signal the confirmatory analysis sees. That is Task 2 of the handoff, and
# the reason this file exists rather than a private detector in each script.
#
# It is also the H2 detector. Changing anything here changes a preregistered
# analysis; see prereg Section 5.1 step 7 and Section 5.4.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY respkit RATHER THAN A DIRECT PORT OF STUDY 5
#
# The handoff's Task 2 proposed porting find_extrema_prominence out of
# reference/study5_snapshot/breath_pipeline.R. respkit is that function's
# descendant, rebuilt and validated against 198 archived recordings, and it
# fixes defects that reach this study. See reference/respkit_snapshot/PROVENANCE.txt.
#
# The decisive one is respkit Defect 3. Study 5 detected AND measured on a
# single 0.05 to 0.4 Hz band, which sits barely above the respiratory
# fundamental and symmetrises every breath. respkit's fix, adopted here, is two
# filtered copies: locate extrema on a narrow band where the detector is stable,
# then snap each onto a wide band before reading any time off it.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY BOTH COPIES CAN BE BUILT WITHOUT RE-RUNNING PREPROCESSING
#
# Band-pass filtering and the calibrated weighted sum are both linear, so they
# commute:
#
#     w . bandpass(axes)  ==  bandpass(w . axes)
#
# The RDS stores the raw 25 Hz axes in `belt$accel_grid` and the fitted weights
# in `belt$weights`, so any band can be produced here from what is already on
# disk. `belt$accel_grid$mlr_lp` (0.6 Hz) and `$mlr_pred` (calibration band) are
# left alone; this file does not use them.
#
# Nothing here re-fits the calibration. The weights are taken as given.

# ── Load respkit from the vendored snapshot ───────────────────────────────────
#
# Vendored deliberately: a pre-registration must not depend on a shared-drive
# path that can move underneath it.

.ONSETS_RESPKIT <- file.path(
  "I:", "Shared drives", "Behavioral Interoception", "Summer2026_CompareBelts",
  "reference", "respkit_snapshot", "R")

if (!dir.exists(.ONSETS_RESPKIT)) {
  stop("respkit snapshot not found at:\n  ", .ONSETS_RESPKIT,
       "\n  See reference/respkit_snapshot/PROVENANCE.txt.")
}
for (.f in list.files(.ONSETS_RESPKIT, "[.]R$", full.names = TRUE)) source(.f)
rm(.f)


# ── Preregistered detector parameters ─────────────────────────────────────────
#
# Fixed in advance. Every one of these appears in prereg Section 5.1.

ONSET_HZ              <- 25L

# Detection copy. respkit's default. Narrow enough that the detector is stable,
# wide enough to avoid Study 5's symmetrisation.
ONSET_DETECT_BAND     <- c(low = 0.05, high = 0.6)

# Measurement copy. Extrema located on the detection copy are snapped onto this
# one before any time is read. respkit's default, and the knee of its
# duty-cycle bias curve; going below 1 Hz is where the real damage is.
#
# Measured on synthetic breaths with exact ground truth (see
# scripts/00_calibrate_detector.R): worst single-device trough bias over
# periods 2 to 6 s is 199 ms here against 293 ms at a 0.6 Hz measurement band.
ONSET_MEASURE_BAND    <- c(low = 0.05, high = 2.0)

ONSET_FILTER_ORDER    <- 2L      # respkit's resp_filter default
ONSET_NORMALISE       <- "robust"
ONSET_MIN_DISTANCE_S  <- 1.0     # 60 breaths/min ceiling
ONSET_REFINE_WINDOW_S <- 0.5

# Prominence threshold, in normalised signal units. respkit's default, and
# CONFIRMED on participant 14542: the accelerometer's count of implausible
# inter-onset intervals falls 26, 20, 17, 12, 10 across thresholds 0.10 to 0.40
# and then plateaus at 9 through 0.80, so 0.4 sits at the knee. Below 0.3 the
# detector is manufacturing short cycles out of noise ripples. The stretch belt
# is clean at every threshold, so the accelerometer sets the constraint.
#
# NOTE: synthetic signals cannot calibrate this, and the attempt is recorded as
# a negative result in scripts/00_calibrate_detector.R Part 2. The detection
# band smooths broadband noise so thoroughly that a synthetic recording has ~25
# local maxima with prominences 1.4 to 2.9, i.e. the entire swept range lies
# below its floor. Real signals have hundreds of maxima with a lower quartile
# near 0.22. Do not "validate" this number synthetically; it will always look
# flat.
ONSET_MIN_PROMINENCE  <- 0.4

# Polarity. Both signals should rise on inhalation: the stretch belt because it
# lengthens, and the accelerometer because the calibration weights are fitted
# against the pacer, whose radius is maximal at peak inhale.
#
# CAVEAT on respkit's duty-cycle heuristic, which reads duty > 0.5 as inverted.
# It is calibrated for a DISPLACEMENT transducer. On 14542 the stretch belt
# reads 0.449 (clearly upright) while the accelerometer reads 0.526, which trips
# the flag without being inverted: the calibration fit is positively signed, and
# an accelerometer-derived signal is close to symmetric because it is a second
# derivative reshaped by the calibration weights. Treat a duty near 0.5 on the
# accelerometer as expected, and only a value near the belt's complement
# (~0.55 alongside a NEGATIVE calibration fit) as genuine inversion.
ONSET_POLARITY        <- "up"


# ── Device signals ────────────────────────────────────────────────────────────

#' Unfiltered calibrated accelerometer breathing signal.
#'
#' The weighted combination of the RAW axes, with no band-pass applied. Filtering
#' is left to `detect_breaths()` so that the detection and measurement copies
#' are produced from one source under one rule. Correct by linearity, see the
#' header.
#'
#' @param belt the `belt` element of a participant RDS
#' @return numeric vector on the 25 Hz grid
belt_signal_raw <- function(belt) {
  g <- belt$accel_grid
  w <- belt$weights
  if (is.null(w) || length(w) != 3L)
    stop("belt$weights missing or malformed; expected 3 coefficients.")
  if (!all(c("x", "y", "z") %in% names(g)))
    stop("belt$accel_grid lacks raw x/y/z axes. This file predates the ",
         "corrected prep pipeline.")
  # The intercept is a DC term and is removed by any high-pass. Kept for
  # exactness rather than dropped silently.
  bias <- if (is.null(belt$bias)) 0 else belt$bias
  bias + w[1] * g$x + w[2] * g$y + w[3] * g$z
}

#' Stretch belt breathing signal on the same 25 Hz grid.
biopac_signal_raw <- function(belt) {
  g <- belt$accel_grid
  if (is.null(g$biopac_breath))
    stop("belt$accel_grid$biopac_breath missing.")
  g$biopac_breath
}


# ── The detector ──────────────────────────────────────────────────────────────

#' Detect breath onsets in one device's signal.
#'
#' Identical parameters for both devices by construction: this function takes no
#' device argument. Any per-device tuning would make the two signals
#' incomparable, which is the failure H2 exists to detect.
#'
#' @param sig  unfiltered signal on the ONSET_HZ grid
#' @param hz   sampling rate
#' @return list with
#'   `onset_idx`  1-based sample indices of troughs (breath onsets)
#'   `onset_s`    onset times in seconds from the start of `sig`
#'   `peak_idx`   peak indices, needed for duty cycle and EH2
#'   `measure`    the measurement copy, for anything reading amplitude
#'   `detect`     the detection copy, retained for diagnostics
detect_breaths <- function(sig, hz = ONSET_HZ,
                           min_prominence = ONSET_MIN_PROMINENCE,
                           detect_band    = ONSET_DETECT_BAND,
                           measure_band   = ONSET_MEASURE_BAND) {

  sig <- as.numeric(sig)
  if (length(sig) < 3L * hz)
    return(list(onset_idx = integer(0), onset_s = numeric(0),
                peak_idx = integer(0), measure = numeric(0), detect = numeric(0)))

  det <- resp_filter(sig, low = detect_band[["low"]],  high = detect_band[["high"]],
                     fs = hz, order = ONSET_FILTER_ORDER)
  mea <- resp_filter(sig, low = measure_band[["low"]], high = measure_band[["high"]],
                     fs = hz, order = ONSET_FILTER_ORDER)
  det <- resp_normalise(det, method = ONSET_NORMALISE, fs = hz)
  mea <- resp_normalise(mea, method = ONSET_NORMALISE, fs = hz)

  ext <- find_extrema_prominence(det, hz,
                                 min_prominence = min_prominence,
                                 min_distance_s = ONSET_MIN_DISTANCE_S)

  snap <- function(idx, seek_max) {
    if (!length(idx)) return(integer(0))
    refine_extrema(mea, idx, seek_max = seek_max,
                   window_s = ONSET_REFINE_WINDOW_S, fs = hz)
  }
  onset_idx <- sort(unique(snap(ext$troughs, seek_max = FALSE)))
  peak_idx  <- sort(unique(snap(ext$peaks,   seek_max = TRUE)))

  list(onset_idx = onset_idx,
       onset_s   = (onset_idx - 1) / hz,
       peak_idx  = peak_idx,
       measure   = mea,
       detect    = det)
}


# ── Matching between devices ──────────────────────────────────────────────────
#
# H1 and H2 use DIFFERENT tolerances, deliberately, because the two windows do
# different jobs. See prereg Sections 5.3 and 5.4.
#
#   H2  150 ms   a TEST PARAMETER. Detection agreement is the hypothesis, and
#                the window is pinned to the recording's own timing precision:
#                accelerometer timestamp jitter is 35 ms SD, 74 ms at the 95th
#                percentile, so a tolerance below about 75 ms is not supportable.
#
#   H1  500 ms   BOOKKEEPING. It answers "is this the same breath", nothing more.
#                A window as tight as H2's would admit only breaths that already
#                agree in timing to within 150 ms, which conditions H1's duration
#                comparison on good timing agreement and biases the
#                within-participant SD downward.
#
# 500 ms is safe against false pairing: a window creates false pairs only if it
# can reach past the midpoint between adjacent breaths, and the fastest
# breathing in the design is Block 4's 2.0 s floor, where the half-period is
# 1000 ms. If a device misses a breath entirely the neighbouring onset is a full
# period away and falls outside the window, so a miss stays a miss.

H1_MATCH_TOLERANCE_MS <- 500
H2_MATCH_TOLERANCE_MS <- 150

#' Match onsets between two devices, nearest-first within a tolerance.
#'
#' Greedy by absolute difference, so each onset is used at most once. Returns
#' unmatched counts on both sides: a device that yields no answer is not
#' equivalent to one that yields the right answer, and H7's device-specific
#' dropout is invisible unless this is carried forward (docs/discrepancies.md C4).
#'
#' @param a_s,b_s onset times in seconds
#' @param tol_ms  tolerance window
#' @return list(a_idx, b_idx, n_unmatched_a, n_unmatched_b)
match_onsets <- function(a_s, b_s, tol_ms) {
  tol <- tol_ms / 1000
  if (!length(a_s) || !length(b_s))
    return(list(a_idx = integer(0), b_idx = integer(0),
                n_unmatched_a = length(a_s), n_unmatched_b = length(b_s)))

  pairs <- expand.grid(ai = seq_along(a_s), bi = seq_along(b_s))
  pairs$d <- abs(a_s[pairs$ai] - b_s[pairs$bi])
  pairs <- pairs[pairs$d <= tol, ]
  pairs <- pairs[order(pairs$d), ]

  used_a <- logical(length(a_s)); used_b <- logical(length(b_s))
  ka <- integer(0); kb <- integer(0)
  for (r in seq_len(nrow(pairs))) {
    ai <- pairs$ai[r]; bi <- pairs$bi[r]
    if (used_a[ai] || used_b[bi]) next
    used_a[ai] <- TRUE; used_b[bi] <- TRUE
    ka <- c(ka, ai); kb <- c(kb, bi)
  }
  o <- order(ka)
  list(a_idx = ka[o], b_idx = kb[o],
       n_unmatched_a = sum(!used_a), n_unmatched_b = sum(!used_b))
}

#' Breath durations from onset times, in ms.
#'
#' Implausible cycles are dropped rather than clamped. The bounds are generous
#' on purpose: Block 4 reaches a 2.0 s commanded period and free breathing can
#' run slow, so a tighter rule would silently delete real breaths.
ONSET_MIN_BREATH_MS <- 1500
ONSET_MAX_BREATH_MS <- 12000

durations_ms <- function(onset_s) {
  if (length(onset_s) < 2L) return(numeric(0))
  d <- diff(onset_s) * 1000
  d[d >= ONSET_MIN_BREATH_MS & d <= ONSET_MAX_BREATH_MS]
}
