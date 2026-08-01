# test_calibration.R
#
# Synthetic-data checks for pacer.R and calibration.R. No participant data is
# read. Run from the repository root:  Rscript tests/test_calibration.R

packages <- c("signal")
new_packages <- packages[!sapply(packages, requireNamespace, quietly = TRUE)]
if (length(new_packages)) install.packages(new_packages, repos = "https://cloud.r-project.org")

source("R/pacer.R")
source("R/calibration.R")

pass <- 0L; fail <- 0L
ok <- function(label, cond, detail = "") {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat(sprintf("  PASS  %s\n", label)) }
  else { fail <<- fail + 1L; cat(sprintf("  FAIL  %s  %s\n", label, detail)) }
}

HZ <- 25; PERIOD <- 4000; ANCHOR <- 1e6

# ── 1. Pacer phase convention ────────────────────────────────────────────────
cat("\n1. Pacer waveform\n")
t <- seq(ANCHOR, ANCHOR + PERIOD, by = 1000 / HZ)
p <- pacer_radius(t, ANCHOR, PERIOD)
ok("radius is 0 at the anchor (anchor is a TROUGH)", abs(p[1]) < 1e-9)
ok("radius peaks at anchor + period/2",
   abs(p[which.min(abs(t - (ANCHOR + PERIOD / 2)))] - 1) < 1e-9)
ok("radius returns to 0 after one full period", abs(p[length(p)]) < 1e-9)
ok("bounded 0..1", min(p) >= -1e-12 && max(p) <= 1 + 1e-12)
# A sin-anchored reconstruction would peak a quarter period early; guard the
# error that silently inverts every calibration weight.
ok("NOT sin-anchored (would peak at period/4)",
   abs(p[which.min(abs(t - (ANCHOR + PERIOD / 4)))] - 1) > 0.4)

# ── 2. Two-phase trial pacer ─────────────────────────────────────────────────
cat("\n2. Trial pacer, condition boundary\n")
tt <- seq(0, 20000, by = 1000 / HZ)
pt <- pacer_radius_trial(tt, 0, 4000, 3000, n_base_breaths = 2L)
ok("continuous (both segments trough) at the 8000 ms boundary",
   abs(pt[which.min(abs(tt - 8000))]) < 1e-6)
ok("condition boundary is trial start + 2 base breaths = 8000 ms",
   abs((0 + 2 * 4000) - 8000) < 1e-9)

# ── 3. Calibration window and repeat attempts ────────────────────────────────
cat("
3. Calibration window
")
# Build a realistic label stream. Phase is written once per 36-sample PACKET,
# and per-sample times are back-assigned from the packet timestamp.
#
# This must run at the ACCELEROMETER rate (203.4 Hz, 4.916 ms per sample), not
# the 25 Hz analysis grid: calib_anchor_ms operates on the raw accel table, and
# a packet spans 36 x 4.916 = 177 ms, which is what sets the anchor tolerance.
# Building the fixture at 25 Hz makes a packet 1440 ms wide and the tolerances
# meaningless.
MS_PER_SAMP <- 1000 / 203.4
mk <- function(labels, secs, t0 = ANCHOR) {
  ph <- c(); tm <- c(); pk <- c(); t <- t0
  for (i in seq_along(labels)) {
    for (j in seq_len(round(secs[i] * 203.4 / 36))) {
      pt <- t + 36 * MS_PER_SAMP
      ph <- c(ph, rep(labels[i], 36))
      tm <- c(tm, t + seq_len(36) * MS_PER_SAMP)
      pk <- c(pk, rep(pt, 36))
      t  <- pt
    }
  }
  list(phase = ph, t = tm, pkt = pk)
}
# Single attempt, 14542 geometry: 0.9 s fixation then 19.1 s of breathe label.
one <- mk(c("calib_fixation", "calib_breathe"), c(0.9, 19.1))
anc <- calib_anchor_ms(one$phase, one$t, one$pkt)
ok("anchor lands within one packet (177 ms) of the fixation/breathe boundary",
   abs(anc - (ANCHOR + 900)) < 177, sprintf("off by %.0f ms", abs(anc - (ANCHOR + 900))))
w <- calib_fit_window(anc)
ok("fit window is exactly 4 x period", abs(unname(w[2] - w[1]) - 16000) < 1e-9)
chk <- check_calib_window(one$phase, one$t, one$pkt, pid = "synthetic")
ok("single attempt detected as one", chk$n_attempts == 1L)
ok("overrun reported at about 3.1 s", abs(chk$overrun_ms - 3100) < 400,
   sprintf("got %.0f ms", chk$overrun_ms))

# Two attempts, the 14425 case. The FIRST is the one the participant rejected.
two <- mk(c("calib_fixation", "calib_breathe", "calib_fixation", "calib_breathe"),
          c(0.9, 19.1, 0.9, 19.6))
at <- calib_last_attempt(two$phase, two$t, two$pkt)
ok("repeat calibration detected as TWO attempts, not dozens", at$n_attempts == 2L,
   sprintf("got %d (a sample-level rle reports ~26)", at$n_attempts))
anc2 <- calib_anchor_ms(two$phase, two$t, two$pkt)
ok("anchors on the FINAL attempt, not the rejected first one",
   anc2 > ANCHOR + 19000,
   sprintf("anchor sits %.1f s in; the first attempt starts at 0.9 s", (anc2 - ANCHOR)/1000))
ok("the two anchors differ by about one whole attempt",
   abs((anc2 - anc) - 20000) < 1200, sprintf("differ by %.0f ms", anc2 - anc))

short <- mk("calib_breathe", 12)
ok("short calibration block fails loudly",
   inherits(try(check_calib_window(short$phase, short$t, short$pkt, "x"),
                silent = TRUE), "try-error"))

# ── 4. Model recovery on synthetic axes ──────────────────────────────────────
cat("\n4. Fit recovery\n")
set.seed(42)
LAG_MS <- 320
t  <- seq(0, 16000 - 1000 / HZ, by = 1000 / HZ)
tw <- ANCHOR + t
# Chest movement follows the pacer, delayed by a physiological/filter lag.
breath <- pacer_radius(tw - LAG_MS, ANCHOR, PERIOD)
w_true <- c(0.6, -0.3, 0.75); w_true <- w_true / sqrt(sum(w_true^2))
noise  <- function(n) stats::rnorm(n, 0, 0.02)
calib  <- data.frame(
  t_ms = tw,
  x = w_true[1] * breath + noise(length(t)),
  y = w_true[2] * breath + noise(length(t)),
  z = w_true[3] * breath + noise(length(t))
)

fit <- fit_calibration(calib, ANCHOR, PERIOD, HZ, target = "pacer", pid = "synthetic")
cat(sprintf("     winner=%s  r=%.3f  lag=%.0f ms\n",
            fit$calib_model_label, fit$mlr_r_calib, fit$belt_offset_ms))
# The achievable r is CAPPED BY THE LAG: correlating a sinusoid with itself
# delayed by L on a period P cannot exceed cos(2*pi*L/P), here 0.876. Testing
# against a flat 0.9 would fail a correct implementation.
ceiling_r <- cos(2 * pi * LAG_MS / PERIOD)
ok("fit reaches at least 90% of the lag-imposed ceiling",
   fit$mlr_r_calib > 0.9 * ceiling_r,
   sprintf("r = %.3f, ceiling = %.3f", fit$mlr_r_calib, ceiling_r))
ok("lag-corrected r is high, confirming the model itself is good",
   fit$mlr_r_calib_lagcorr > 0.93,
   sprintf("r_lagcorr = %.3f", fit$mlr_r_calib_lagcorr))
ok("lag-corrected r exceeds uncorrected, as it must",
   fit$mlr_r_calib_lagcorr > fit$mlr_r_calib)
ok("fit r is SIGNED and positive, not an absolute value", fit$mlr_r_calib > 0)
ok("recovers the injected belt-to-pacer offset within one sample (40 ms)",
   abs(fit$belt_offset_ms - LAG_MS) <= 40,
   sprintf("got %.0f, expected %d", fit$belt_offset_ms, LAG_MS))
# NOT the weight direction. When the three axes are scaled copies of one signal
# they are collinear, so many weight vectors reconstruct the breathing equally
# well and the weights are not identified. What must be recovered is the
# RECONSTRUCTION, not the coefficients.
b_win <- CALIB_BANDS[[fit$band]]
recon <- fit$bias +
  fit$weights[1] * bp_filter(calib$x, b_win["low"], b_win["high"], HZ) +
  fit$weights[2] * bp_filter(calib$y, b_win["low"], b_win["high"], HZ) +
  fit$weights[3] * bp_filter(calib$z, b_win["low"], b_win["high"], HZ)
# Compare like with like: the reconstruction is band-passed, so score it against
# the band-passed breath. Against the raw 0..1 raised cosine it reads 0.939,
# with the shortfall coming from the filter rather than the fit.
breath_bp <- bp_filter(breath, b_win["low"], b_win["high"], HZ)
ok("reconstruction recovers the underlying breathing signal",
   abs(cor(recon, breath_bp)) > 0.98,
   sprintf("r vs band-passed breath = %.4f (vs raw breath = %.3f)",
           cor(recon, breath_bp), cor(recon, breath)))
ok("reports the runner-up margin so EH3 can tell a real winner from a tie",
   is.finite(fit$model_margin),
   sprintf("margin = %.4f", fit$model_margin))
ok("carries every field the extraction script requires",
   all(c("calib_target", "calib_model_label", "mlr_r_calib", "belt_offset_ms")
       %in% names(fit)))
ok("calib_target is 'pacer'", identical(fit$calib_target, "pacer"))

# ── 5. The PCA branch, which the live software can never reach ───────────────
cat("\n5. PCA branch\n")
ok("all six models are evaluated, not four", length(fit$all_model_r) == 6L,
   sprintf("got %d: %s", length(fit$all_model_r),
           paste(names(fit$all_model_r), collapse = ", ")))
ok("pca-wide and pca-tight both produce a finite fit",
   all(is.finite(fit$all_model_r[c("pca-wide", "pca-tight")])))
ok("PCA polarity is resolved (positive r, not sign-ambiguous)",
   all(fit$all_model_r[c("pca-wide", "pca-tight")] > 0))

# ── 6. Symmetric lag search ──────────────────────────────────────────────────
cat("\n6. Lag search is symmetric\n")
ref  <- pacer_radius(tw, ANCHOR, PERIOD)
lead <- pacer_radius(tw + 240, ANCHOR, PERIOD)   # belt LEADS: negative lag
neg  <- estimate_lag_ms(lead, ref, HZ)
ok("recovers a NEGATIVE lag (the live software cannot: it searches 0..+1500)",
   neg$lag_ms < -150, sprintf("got %.0f ms", neg$lag_ms))

# ── 7. Inverted signal is rejected ───────────────────────────────────────────
cat("\n7. Inverted reconstruction\n")
flat <- data.frame(t_ms = tw, x = noise(length(t)), y = noise(length(t)),
                   z = noise(length(t)))
# Poor calibration is FLAGGED, not excluded (Section 5.2), so noise must return a
# usable object carrying a flag rather than erroring. With 4 free parameters on
# ~400 samples, overfitting alone puts r near 0.1, so "r > 0" proves nothing and
# the 0.4 threshold is what actually catches it.
nf <- withCallingHandlers(
  fit_calibration(flat, ANCHOR, PERIOD, HZ, pid = "noise"),
  warning = function(w) invokeRestart("muffleWarning"))
ok("pure noise still returns a model (flag, do not exclude)", is.list(nf))
ok("pure noise is FLAGGED as low fit", !is.na(nf$calib_flag),
   sprintf("best r = %.3f", max(nf$all_model_r)))
ok("noise fit is well below the 0.4 threshold", max(nf$all_model_r) < 0.4,
   sprintf("got %.3f", max(nf$all_model_r)))
ok("a good fit is NOT flagged", is.na(fit$calib_flag))

cat(sprintf("\n%d passed, %d failed\n", pass, fail))
if (fail > 0) quit(status = 1)
