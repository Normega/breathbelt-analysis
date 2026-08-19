# calibration.R
#
# Fit the accelerometer-to-breathing transformation against the RECONSTRUCTED
# PACER, on the Phase 1 calibration window only.
#
# WHY NOT AGAINST THE STRETCH BELT
#
# The previous offline pipeline regressed the three band-passed axes onto the
# BioPac breath signal, then reported how well the result agreed with BioPac.
# That is circular twice over: it fits a model to predict device B and then
# scores it on predicting device B, and it absorbs participant-specific variance
# into the fit, which shrinks the between-participant SD of the bias and yields
# an optimistically small sample size.
#
# Note the LIVE software already targets the pacer (fitBestModel in
# breathUtils.js). The circularity was introduced by the offline refit alone.
#
# Fitting is confined to calibration and never extended to paced trials: doing so
# would compromise H4, which tests prediction of the pacer.
#
# Mirrors radlab BreathBelt/breathUtils.js fitBestModel (commit 98b2dca), with
# three deliberate departures, each marked DEPARTURE below.
#
# Requires: signal. Sourced by scripts/; installs nothing.


# ── Filter bands ──────────────────────────────────────────────────────────────
#
# The pre-registration makes the OFFLINE settings authoritative; the live values
# exist only to drive the participant's on-screen preview.
#
#   wide  0.05 to 1.0 Hz   pre-registration Section 5.1 (software uses 0.1 to 1.0)
#   lp    0.6 Hz           post-smoothing for the -lp variants
#
# THE TIGHT BAND (0.10 to 0.4 Hz) WAS DROPPED, 2026-08-07, approved by Norm.
#
# It is respkit Defect 3 sitting inside the calibration step: a 0.4 Hz cutoff
# sits barely above the respiratory fundamental, so it symmetrises every breath
# and biases extremum timing. Measured consequence on participant 14542, whose
# winning model was mlr-tight-lp: median duty cycle read 0.48 to 0.55 in every
# block, i.e. pinned at 0.50 regardless of true morphology, while the stretch
# belt on the same breaths read 0.43 to 0.47. A reconstruction that cannot
# express asymmetry cannot support H2's onset timing, H3's depth-by-rate
# interaction, or EH2's waveform shape.
#
# Dropping it also makes the reconstruction band consistent with the detector's
# measurement band (R/onsets.R, 0.05 to 2.0 Hz) and makes participants
# comparable: under the old rule a tight-band participant and a wide-band
# participant were not running the same measurement.
#
# Consequences, all intended:
#   - the candidate set falls from six models to three (mlr-wide, mlr-wide-lp,
#     pca-wide), which docs/discrepancies.md C6 argues is no loss, since under
#     collinear axes the six scored within noise of each other and selection was
#     close to a coin flip
#   - EH3 is correspondingly narrower; see prereg Section 5.11
#   - mlr-wide and mlr-wide-lp share IDENTICAL weights and differ only in
#     whether the 0.6 Hz smooth is applied before scoring, so the fitted weights
#     no longer depend on which of the two wins
#
# The constant is kept below rather than deleted so the dropped band stays on
# the record.
CALIB_BAND_DROPPED_TIGHT <- c(low = 0.10, high = 0.4)
#
# Order 4 in butter() plus filtfilt gives an effective 8th-order zero-phase
# response. The software uses 2nd-order biquads under filtfilt, i.e. effective
# 4th. The pre-registration says "4th-order Butterworth, applied forwards and
# backwards", which is ambiguous about whether 4 is before or after doubling.
# Order 4 is used here to match the existing offline pipeline. Flagged for Norm.

CALIB_BANDS <- list(
  wide  = c(low = 0.05, high = 1.0)
)
CALIB_LP_HZ    <- 0.6
CALIB_ORDER    <- 4L
CALIB_MAX_LAG_MS <- 2000        # pre-registration Section 5.1: plus or minus 2000
CALIB_MIN_R      <- 0.40        # SYNC_FAIR; flag threshold, not an exclusion

# ── Edge padding ──────────────────────────────────────────────────────────────
#
# THIS IS NOT OPTIONAL AT THIS WINDOW LENGTH.
#
# Calibration is 16 s. A 0.05 Hz high-pass corner has a 20 s period, LONGER than
# the data being filtered, so a cold zero-state start distorts essentially the
# whole window. Filtering unpadded, the injected-lag recovery in
# tests/test_calibration.R comes out at 160 ms against a true 320 ms, and the
# recovered weight direction misses entirely: the fit is dominated by the
# filter's warm-up transient rather than by the breathing.
#
# The software solves this with oddExtend + a 3000-sample pad (about 15 s at the
# 203 Hz accelerometer rate), citing a settling time of roughly 5 time constants.
# R's signal::filtfilt does no such padding, so it is done explicitly here.
# Reflection is odd (point-reflection through the endpoint), matching both
# oddExtend and scipy's filtfilt default.
CALIB_PAD_SEC <- 15

.odd_extend <- function(sig, n) {
  N <- length(sig)
  if (n < 1L) return(sig)
  left  <- 2 * sig[1] - rev(sig[2:(n + 1L)])
  right <- 2 * sig[N] - rev(sig[(N - n):(N - 1L)])
  c(left, sig, right)
}

.filtfilt_padded <- function(x, bf, hz, pad_sec = CALIB_PAD_SEC) {
  N <- length(x)
  n <- min(as.integer(round(pad_sec * hz)), N - 1L)
  if (n < 1L) return(as.numeric(signal::filtfilt(bf, x)))
  y <- as.numeric(signal::filtfilt(bf, .odd_extend(x, n)))
  y[(n + 1L):(n + N)]
}

bp_filter <- function(x, low, high, hz, order = CALIB_ORDER) {
  nyq <- hz / 2
  if (high / nyq >= 1) stop("Band-pass upper edge is at or above Nyquist.")
  bf  <- signal::butter(order, c(low, high) / nyq, type = "pass")
  .filtfilt_padded(x, bf, hz)
}

lp_filter <- function(x, cutoff = CALIB_LP_HZ, hz, order = CALIB_ORDER) {
  nyq <- hz / 2
  bf  <- signal::butter(order, cutoff / nyq, type = "low")
  .filtfilt_padded(x, bf, hz)
}


# ── Model fitting ─────────────────────────────────────────────────────────────

# Ordinary least squares of `target` on the three axes plus an intercept.
.fit_mlr <- function(xf, yf, zf, target) {
  fit <- stats::lm.fit(cbind(1, xf, yf, zf), target)
  if (any(is.na(fit$coefficients))) return(NULL)
  cf <- unname(fit$coefficients)
  list(bias = cf[1], weights = cf[2:4])
}

# First principal component of the three band-passed axes, then a scalar
# regression of the target on that component.
#
# DEPARTURE 1: the software calls solveLS3(pc1, pc1, pc1, tgt), passing the SAME
# column three times. The design matrix is rank 2 of 4, so its Gaussian
# elimination hits the 1e-14 singularity guard and returns null. The PCA branch
# is therefore SKIPPED on every participant, and pca-wide / pca-tight can never
# be selected. The live "six candidate models" are in practice four.
#
# Verified by replicating solveLS3 in R: returns NULL, design rank 2 of 4.
#
# Fixed here by regressing on the single PC1 column, which is what was intended.
# Consequence: the offline selected model may legitimately differ from
# belt_sessions.calib_model_label. The offline label is the one EH3 and
# selected_model_freq should use.
.fit_pca <- function(xf, yf, zf, target) {
  m  <- cbind(xf, yf, zf)
  cm <- stats::cov(m)
  ev <- eigen(cm, symmetric = TRUE)
  v  <- ev$vectors[, 1]

  pc1 <- as.numeric(scale(m, center = TRUE, scale = FALSE) %*% v)
  fit <- stats::lm.fit(cbind(1, pc1), target)
  if (any(is.na(fit$coefficients))) return(NULL)
  cf <- unname(fit$coefficients)

  # DEPARTURE 2: resolve polarity explicitly. An eigenvector's sign is arbitrary,
  # and the software papers over this by scoring with abs(r), which lets an
  # inverted reconstruction score as a perfect fit. Here the scalar coefficient
  # carries the sign, so folding it into the weights makes the polarity explicit
  # and the reported r signed and interpretable.
  list(bias = cf[1], weights = cf[2] * v)
}

.apply_model <- function(xf, yf, zf, model) {
  model$bias + model$weights[1] * xf + model$weights[2] * yf + model$weights[3] * zf
}

# DEPARTURE 3: signed Pearson r, not abs().
#
# The software's pearsonR returns Math.abs(...). For MLR the weights already
# carry sign, so a negative r means the reconstruction is INVERTED, which is a
# failure, not a success worth selecting. Taking the absolute value lets an
# upside-down signal win. Signed r is used for selection, and any model with
# r <= 0 is rejected outright.
.pearson <- function(a, b) {
  if (length(a) < 4L) return(NA_real_)
  s <- stats::sd(a) * stats::sd(b)
  if (!is.finite(s) || s <= 0) return(NA_real_)
  stats::cor(a, b)
}


# ── Lag ───────────────────────────────────────────────────────────────────────

# BELT-TO-PACER OFFSET by cross-correlation, searched over plus or minus
# max_lag_ms. Positive means the belt trails the pacer.
#
# Deliberately not called device lag. It also contains participant anticipation,
# which is negative and is the norm in sensorimotor synchronisation, so negative
# values are expected. True device lag needs a between-device comparison and is
# reserved for the confirmatory analysis. See prereg Section 5.1.
#
# The software's estimateLagMs searches `for (shift = 0; shift <= maxShift)`,
# i.e. non-negative shifts only, up to +1500 ms. The live `belt_sessions.calib_lag_ms`
# column (that name is the database's, not ours) is therefore
# non-negative BY CONSTRUCTION, which makes the pre-registered sanity check
# "flag any participant whose estimated lag is negative" vacuous on the live
# values. The symmetric search here is what gives that check meaning.
estimate_lag_ms <- function(pred, ref, hz, max_lag_ms = CALIB_MAX_LAG_MS) {
  max_shift <- round(max_lag_ms / 1000 * hz)
  shifts    <- seq(-max_shift, max_shift)
  n         <- length(pred)
  best_r <- -Inf; best_shift <- 0L
  for (s in shifts) {
    if (s >= 0) { a <- pred[(s + 1):n];      b <- ref[1:(n - s)] }
    else        { a <- pred[1:(n + s)];      b <- ref[(-s + 1):n] }
    if (length(a) < 20L) next
    r <- .pearson(a, b)
    if (is.finite(r) && r > best_r) { best_r <- r; best_shift <- s }
  }
  list(lag_ms = best_shift / hz * 1000, lag_r = best_r)
}


# ── Entry point ───────────────────────────────────────────────────────────────

# Fit all six candidate models on the calibration window and return the winner.
#
#   calib: data.frame with t_ms, x, y, z, restricted to the paced window
#          (use calib_fit_window() from pacer.R; do NOT pass the whole
#          calib_breathe label, which overruns pacing by about 3.1 s)
#   anchor_ms, period_ms: pacer phase anchor and commanded period
#   hz: sampling rate of `calib`
#
# Returns a list carrying every field the extraction script requires.
fit_calibration <- function(calib, anchor_ms, period_ms, hz,
                            target = c("pacer", "biopac"),
                            biopac = NULL, pid = NA_character_) {
  target <- match.arg(target)
  stopifnot(all(c("t_ms", "x", "y", "z") %in% names(calib)))
  if (nrow(calib) < 100L) {
    stop("Participant ", pid, ": only ", nrow(calib),
         " calibration samples; need at least 100.")
  }

  tgt <- if (target == "pacer") {
    pacer_radius(calib$t_ms, anchor_ms, period_ms)
  } else {
    if (is.null(biopac)) stop("target='biopac' requires the biopac argument.")
    if (length(biopac) != nrow(calib)) stop("biopac length does not match calib.")
    biopac
  }

  results <- list()
  for (band in names(CALIB_BANDS)) {
    b  <- CALIB_BANDS[[band]]
    xf <- bp_filter(calib$x, b["low"], b["high"], hz)
    yf <- bp_filter(calib$y, b["low"], b["high"], hz)
    zf <- bp_filter(calib$z, b["low"], b["high"], hz)

    mlr <- .fit_mlr(xf, yf, zf, tgt)
    if (!is.null(mlr)) {
      pred <- .apply_model(xf, yf, zf, mlr)
      results[[paste0("mlr-", band)]] <-
        list(model = mlr, band = band, smooth = FALSE, r = .pearson(pred, tgt))
      pred_lp <- lp_filter(pred, hz = hz)
      results[[paste0("mlr-", band, "-lp")]] <-
        list(model = mlr, band = band, smooth = TRUE, r = .pearson(pred_lp, tgt))
    }

    pca <- .fit_pca(xf, yf, zf, tgt)
    if (!is.null(pca)) {
      pred <- .apply_model(xf, yf, zf, pca)
      results[[paste0("pca-", band)]] <-
        list(model = pca, band = band, smooth = FALSE, r = .pearson(pred, tgt))
    }
  }

  rs <- vapply(results, function(z) if (is.finite(z$r)) z$r else -Inf, numeric(1))
  if (!length(rs) || !any(is.finite(rs))) {
    stop("Participant ", pid, ": no calibration model produced a finite fit ",
         "against the ", target, ". Signal is degenerate.")
  }
  win_label <- names(rs)[which.max(rs)]
  win       <- results[[win_label]]

  # Poor calibration is FLAGGED, not excluded. Section 5.2 excludes only for
  # incomplete data, on the reasoning that a participant who calibrates poorly is
  # informative: the question is whether that shows up similarly on both devices.
  # So this returns a usable model with a flag rather than failing.
  #
  # Note that with four free parameters on roughly 400 samples, pure noise still
  # yields r near 0.1 by overfitting, so "r > 0" is not evidence of anything. The
  # threshold matches the live software's SYNC_FAIR gate (Fit R < 0.4 blocked
  # continuation during the session), which keeps the offline flag comparable to
  # the standard participants were actually held to.
  calib_flag <- if (max(rs) < CALIB_MIN_R) {
    sprintf("low calibration fit: best r = %.3f, below %.2f", max(rs), CALIB_MIN_R)
  } else NA_character_
  if (!is.na(calib_flag)) {
    warning("Participant ", pid, ": ", calib_flag, call. = FALSE)
  }

  b  <- CALIB_BANDS[[win$band]]
  xf <- bp_filter(calib$x, b["low"], b["high"], hz)
  yf <- bp_filter(calib$y, b["low"], b["high"], hz)
  zf <- bp_filter(calib$z, b["low"], b["high"], hz)
  pred <- .apply_model(xf, yf, zf, win$model)
  if (win$smooth) pred <- lp_filter(pred, hz = hz)

  lag <- estimate_lag_ms(pred, tgt, hz)

  # Runner-up margin.
  #
  # When the three axes are strongly collinear (the usual case: they are three
  # projections of one chest movement), many weight vectors reconstruct the
  # breathing equally well and the six models score within noise of one another.
  # On the synthetic fixture all six land within 0.014 of each other, so the
  # "selected model" is close to a coin flip.
  #
  # EH3 tests whether the selected model predicts subsequent agreement. If the
  # selection is arbitrary tie-breaking, EH3 is testing a near-random label. The
  # margin lets that be checked rather than assumed, so it is reported alongside
  # the label. Note the WEIGHTS are not identified under collinearity even when
  # the reconstruction is excellent; only the prediction is.
  ord    <- sort(rs, decreasing = TRUE)
  margin <- if (length(ord) >= 2L) unname(ord[1] - ord[2]) else NA_real_

  list(
    calib_target      = target,                 # required by the extraction script
    calib_flag        = calib_flag,             # NA when the fit is acceptable
    calib_model_label = win_label,              # required
    mlr_r_calib       = unname(win$r),          # required; SIGNED, not abs
    belt_offset_ms    = lag$lag_ms,             # required; symmetric search
    belt_offset_r     = lag$lag_r,

    # mlr_r_calib is MECHANICALLY CONFOUNDED WITH LAG. A perfect model still
    # scores only cos(2*pi*lag/period) against an unshifted pacer: 0.88 at a
    # 320 ms lag, and 0.71 at 500 ms, which is exactly the software's SYNC_GOOD
    # boundary. A participant with a sound belt but a long lag is therefore
    # graded "Fair" on model quality they do not lack.
    #
    # Both are reported: the uncorrected value stays comparable to the live gate
    # participants were held to, the corrected value is the actual model quality.
    # They matter separately because calibration_fit and belt_offset_ms are BOTH
    # whitelisted inputs to the simulation, and treating them as independent
    # would double-count a single underlying quantity.
    mlr_r_calib_lagcorr = unname(lag$lag_r),
    model_margin      = margin,
    bias              = win$model$bias,
    weights           = win$model$weights,
    band              = win$band,
    smooth            = win$smooth,
    all_model_r       = rs,
    n_samples         = nrow(calib),
    anchor_ms         = anchor_ms,
    period_ms         = period_ms
  )
}
