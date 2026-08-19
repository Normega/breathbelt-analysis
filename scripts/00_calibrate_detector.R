# 00_calibrate_detector.R
#
# Fixes the two free parameters in R/onsets.R, and leaves the evidence on disk.
#
#   ONSET_MEASURE_BAND    upper cutoff of the measurement copy
#   ONSET_MIN_PROMINENCE  prominence threshold, in normalised signal units
#
# Runs BEFORE 01_batch_prep.R in the numbering because everything downstream
# depends on the detector, but it reads the RDS that 01 produces. Re-run it if
# either parameter is ever revisited.
#
# ─────────────────────────────────────────────────────────────────────────────
# DISCLOSURE
#
# Real data is touched for participant 14542 ONLY, the designated debugging
# participant (handoff Hard Rule 4). Every quantity computed on it is
# single-device:
#
#   breath count       explicitly whitelisted, prereg Section 1.7
#   polarity           a signal orientation check, respkit BeforeYouRun item 2
#   rejection counts   how many extrema each prominence threshold discards
#
# NOTHING between-device is computed here. No match rate, no onset timing
# difference, no correlation, no agreement coefficient. Those are H2's test
# statistics and are blocked.
#
# The waveform asymmetry figure that drives Part 1 is taken from respkit's
# 198-recording archive, NOT from this study's data, precisely so that no
# morphology quantity has to be read off the pilot.
#
# Usage:  Rscript scripts/00_calibrate_detector.R

# Set Up ---------
## Load libraries ---------
packages <- c("signal")
new_packages <- packages[!sapply(packages, requireNamespace, quietly = TRUE)]
if (length(new_packages)) install.packages(new_packages, repos = "https://cloud.r-project.org")
for (thispack in packages) {
  library(thispack, character.only = TRUE, quietly = TRUE, verbose = FALSE)
}

BASE_DIR <- file.path("I:", "Shared drives", "Behavioral Interoception",
                      "Summer2026_CompareBelts")
source(file.path(BASE_DIR, "R", "onsets.R"))

OUT_DIR    <- file.path(BASE_DIR, "Analysis", "detector_calibration")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
OUT_REPORT <- file.path(OUT_DIR, "detector_calibration_report.txt")

DEBUG_PID <- "14542"          # the ONLY real participant this script may open
HZ        <- ONSET_HZ

set.seed(20260807)


# ── Synthetic breathing with exact ground truth ───────────────────────────────
#
# Displacement is what a stretch belt transduces. Phase-warped cosine so the
# inspiratory fraction is controllable and the waveform stays C1 continuous (the
# derivative vanishes at both peak and trough from either side), so no
# derivative corner smuggles in harmonics that the test would then attribute to
# the accelerometer.

displacement <- function(t, period_s, duty) {
  u     <- (t %% period_s) / period_s
  theta <- ifelse(u < duty, pi * u / duty, pi + pi * (u - duty) / (1 - duty))
  -cos(theta)
}

# The accelerometer transduces the SECOND DERIVATIVE of displacement. Its sign
# is resolved by the pacer-target calibration fit, so the reconstructed signal
# comes back in phase with the pacer rather than inverted: for a pure sine
# -d'' = +w^2 * d exactly. For an asymmetric breath the fundamental stays in
# phase but harmonic n is amplified by n^2, which is what reshapes the waveform
# and moves the trough. That is the effect this part measures.
make_signals <- function(period_s, duty, n_cycles, hz_fine = 1000,
                         noise = 0.02, seed = 1) {
  set.seed(seed)
  dur_s  <- period_s * n_cycles
  t_fine <- seq(0, dur_s, by = 1 / hz_fine)
  d      <- displacement(t_fine, period_s, duty)

  dd    <- c(NA, diff(d, differences = 2), NA) * hz_fine^2
  dd[1] <- dd[2]; dd[length(dd)] <- dd[length(dd) - 1]
  accel <- -dd

  cycle_of <- floor(t_fine / period_s)
  own_trough <- function(v)
    unname(vapply(split(seq_along(v), cycle_of),
                  function(ix) t_fine[ix[which.min(v[ix])]], numeric(1)))

  t_grid <- seq(0, dur_s, by = 1 / HZ)
  b <- approx(t_fine, d,     t_grid)$y
  a <- approx(t_fine, accel, t_grid)$y
  b <- b / sd(b) + rnorm(length(b), 0, noise)
  a <- a / sd(a) + rnorm(length(a), 0, noise)

  list(biopac = b, accel = a, n_cycles = n_cycles,
       truth = list(biopac = own_trough(d), accel = own_trough(accel)))
}

# Signed error against that device's OWN true troughs. Positive = reported late.
bias_ms <- function(onset_s, truth, period) {
  if (!length(onset_s)) return(NA_real_)
  keep <- truth[truth > 2 & truth < max(truth) - 2]     # drop edge cycles
  if (!length(keep)) return(NA_real_)
  err <- vapply(keep, function(tt) { dd <- onset_s - tt; dd[which.min(abs(dd))] },
                numeric(1))
  err <- err[abs(err) < period / 3]
  if (!length(err)) return(NA_real_)
  mean(err) * 1000
}


# ── Part 1: measurement band ──────────────────────────────────────────────────

periods <- c(2, 3, 4, 5, 6)      # Block 3 spans 3-5, Block 4 spans 2-6
duties  <- c(0.35, 0.40, 0.45, 0.50)
bands   <- c(0.6, 1.0, 2.0, 4.0)
seeds   <- 1:6

rows <- list()
for (p in periods) for (dy in duties) for (s in seeds) {
  sg <- make_signals(p, dy, n_cycles = max(12, round(90 / p)), seed = s)
  for (mh in bands) for (dev in c("biopac", "accel")) {
    r <- detect_breaths(sg[[dev]], HZ,
                        measure_band = c(low = 0.05, high = mh))
    rows[[length(rows) + 1]] <- data.frame(
      period = p, duty = dy, seed = s, band = mh, device = dev,
      bias = bias_ms(r$onset_s, sg$truth[[dev]], p))
  }
}
band_res <- do.call(rbind, rows)

a <- band_res[band_res$device == "accel", ]
b <- band_res[band_res$device == "biopac", ]
band_diff <- merge(a, b, by = c("period", "duty", "seed", "band"),
                   suffixes = c(".a", ".b"))
band_diff$diff <- band_diff$bias.a - band_diff$bias.b


# ── Part 2: why synthetic cannot set the prominence threshold ─────────────────

proms <- c(0.10, 0.15, 0.20, 0.30, 0.40, 0.50, 0.60, 0.80)


# NEGATIVE RESULT, RECORDED DELIBERATELY.
#
# Synthetic signals CANNOT calibrate this threshold, and three attempts to make
# them do so all failed for the same underlying reason. What settles it is the
# prominence DISTRIBUTION, measured below.
#
# The 0.05 to 0.6 Hz detection band-pass is so effective at smoothing broadband
# noise that a synthetic recording contains almost no low-prominence extrema to
# reject. Even at noise SD 1.5, a 25-cycle synthetic yields 27 local maxima with
# prominences from 1.40 to 2.90, i.e. every one of them far above the whole
# swept range. Adding an in-band second harmonic degrades detection badly but
# still does not change the answer at any threshold, because the extrema it
# creates are large too.
#
# Real signals are not like that. On 14542 the accelerometer has 453 local
# maxima with a median prominence of 0.88 and a lower quartile of 0.22, and the
# stretch belt has 340 with a median of 1.83. That population of small ripples,
# produced by motion, posture change and strap slippage, is what a prominence
# threshold is for, and reproducing it convincingly would mean modelling the
# artefact structure rather than the breathing.
#
# So the threshold is set from participant 14542 in Part 3, which is the route
# Norm approved and is what respkit's own guidance prescribes: "Pick it by
# looking at what gets rejected, not by its effect on the summary statistics."
# The synthetic role here is only to show that the swept range lies entirely
# below the synthetic prominence floor, so a flat result there is expected
# rather than reassuring.

prom_dist <- list()
for (noise in c(0.02, 0.30, 0.80, 1.50)) {
  sg  <- make_signals(4, 0.45, n_cycles = 25, noise = noise, seed = 1)
  det <- resp_filter(sg$biopac, low = ONSET_DETECT_BAND[["low"]],
                     high = ONSET_DETECT_BAND[["high"]], fs = HZ,
                     order = ONSET_FILTER_ORDER)
  det <- resp_normalise(det, method = ONSET_NORMALISE, fs = HZ)
  idx <- local_maxima(det)
  pr  <- peak_prominence(det, idx)
  prom_dist[[length(prom_dist) + 1]] <- data.frame(
    source = sprintf("synthetic, noise SD %.2f", noise),
    n_maxima = length(idx), min = min(pr),
    q25 = unname(quantile(pr, .25)), median = median(pr), max = max(pr))
}
prom_dist <- do.call(rbind, prom_dist)


# ── Part 3: prominence on participant 14542 ───────────────────────────────────
#
# Single-device quantities only. See the disclosure block at the top.

rds <- file.path(BASE_DIR, "Analysis", "output", paste0(DEBUG_PID, "_physio.rds"))
have_real <- file.exists(rds)

if (have_real) {
  d  <- readRDS(rds)
  sigs <- list(accel  = belt_signal_raw(d$belt),
               biopac = biopac_signal_raw(d$belt))

  rows <- list()
  for (pr in proms) for (dev in names(sigs)) {
    r <- detect_breaths(sigs[[dev]], HZ, min_prominence = pr)
    dur <- durations_ms(r$onset_s)
    rows[[length(rows) + 1]] <- data.frame(
      prom = pr, device = dev,
      n_onsets   = length(r$onset_s),
      n_kept     = length(dur),
      n_dropped  = max(0L, length(r$onset_s) - 1L) - length(dur),
      med_dur_ms = if (length(dur)) median(dur) else NA_real_)
  }
  prom_real <- do.call(rbind, rows)

  # The same prominence distribution measured on synthetic in Part 2, so the two
  # are directly comparable. This is the evidence that the synthetic floor sits
  # above the swept range while the real one straddles it.
  prom_real_dist <- do.call(rbind, lapply(names(sigs), function(dev) {
    det <- resp_filter(sigs[[dev]], low = ONSET_DETECT_BAND[["low"]],
                       high = ONSET_DETECT_BAND[["high"]], fs = HZ,
                       order = ONSET_FILTER_ORDER)
    det <- resp_normalise(det, method = ONSET_NORMALISE, fs = HZ)
    idx <- local_maxima(det)
    pr  <- peak_prominence(det, idx)
    data.frame(source = paste0(DEBUG_PID, ", ", dev),
               n_maxima = length(idx), min = min(pr),
               q25 = unname(quantile(pr, .25)), median = median(pr), max = max(pr))
  }))

  # Polarity, per respkit BeforeYouRun item 2. A belt rises on inhalation, and
  # the calibration weights are fitted against the pacer, so both signals should
  # read "up". A duty cycle above 0.5 is the signature of an inverted signal.
  pol <- list()
  for (dev in names(sigs)) {
    r  <- detect_breaths(sigs[[dev]], HZ)
    duty <- NA_real_
    if (length(r$onset_idx) > 2L && length(r$peak_idx)) {
      dd <- vapply(seq_len(length(r$onset_idx) - 1L), function(i) {
        o1 <- r$onset_idx[i]; o2 <- r$onset_idx[i + 1L]
        pk <- r$peak_idx[r$peak_idx > o1 & r$peak_idx < o2]
        if (length(pk) != 1L) return(NA_real_)
        (pk - o1) / (o2 - o1)
      }, numeric(1))
      duty <- median(dd, na.rm = TRUE)
    }
    pol[[dev]] <- c(duty = duty, verdict_up = as.numeric(!is.na(duty) && duty < 0.5))
  }
}


# ── Report ────────────────────────────────────────────────────────────────────

sink(OUT_REPORT)
cat("BreathBelt detector calibration\n")
cat("Generated:", as.character(Sys.time()), "\n")
cat("respkit snapshot: reference/respkit_snapshot (see PROVENANCE.txt)\n")
cat(strrep("=", 78), "\n\n")

cat("PART 1. MEASUREMENT BAND\n\n")
cat("Trough timing bias against each device's own waveform, ms.\n")
cat("Positive = detector reports the trough late. Detection band 0.05-0.6 Hz\n")
cat("throughout; only the measurement band varies. Synthetic, exact ground truth.\n\n")
for (dev in c("biopac", "accel")) {
  cat("--- ", dev, " ---\n", sep = "")
  s <- band_res[band_res$device == dev, ]
  cat("rows = period (s), cols = measurement band upper cutoff (Hz)\n")
  print(round(with(s, tapply(bias, list(period, band), mean, na.rm = TRUE)), 1))
  cat("\n")
}
cat("Worst |single-device bias| over the sweep:\n")
for (mh in bands)
  cat(sprintf("  %.1f Hz : %6.1f ms\n", mh,
              max(abs(band_res$bias[band_res$band == mh]), na.rm = TRUE)))

cat("\nDifferential bias (accel minus biopac), by duty cycle.\n")
cat("This is what survives into a between-device comparison; common-mode cancels.\n")
cat("rows = duty cycle, cols = measurement band upper cutoff (Hz)\n")
print(round(with(band_diff, tapply(diff, list(duty, band), mean, na.rm = TRUE)), 1))

cat("\nCONCLUSION.\n")
cat("The measurement band barely moves the DIFFERENTIAL: paired within seed and\n")
cat("period, 2.0 Hz minus 0.6 Hz is within about 40 ms and its sign depends on\n")
cat("duty cycle. It clearly improves the SINGLE-DEVICE bias, and respkit's own\n")
cat("duty-cycle table puts 2.0 Hz at the knee. ONSET_MEASURE_BAND = 0.05-2.0 Hz.\n")

cat("\nThe finding that matters more than the band:\n")
cat("At duty 0.50 the differential is ~0 at EVERY band. The whole effect is\n")
cat("harmonic distortion from waveform asymmetry, since the accelerometer\n")
cat("amplifies harmonic n by n^2. The BreathBelt pacer is (1-cos)/2, exactly\n")
cat("symmetric, so:\n")
cat("  paced blocks 3 and 4  duty near 0.50, differential offset near zero\n")
cat("  free blocks 2 and 5   duty near 0.43 on respkit's 198-recording archive,\n")
cat("                        giving a differential offset of roughly 135-225 ms\n")
cat("The belt-to-pacer offset is fitted on Block 1, which is PACED and therefore\n")
cat("symmetric, where this offset is zero. It cannot remove the free-breathing\n")
cat("offset. Fitting one there would need between-device timing, which is H2's\n")
cat("estimand and blocked. Hence H2's block-specific tolerance, prereg 5.4.\n")

cat("\n", strrep("=", 78), "\n\n", sep = "")
cat("PART 2. WHY SYNTHETIC CANNOT SET THE PROMINENCE THRESHOLD\n\n")
cat("A negative result, recorded rather than tuned away. Three attempts to\n")
cat("calibrate min_prominence synthetically returned an identical answer at\n")
cat("every threshold from 0.10 to 0.80:\n")
cat("  1. count against expected returned -2 everywhere (the two edge troughs)\n")
cat("  2. a 1.1 Hz cardiac ripple changed nothing (the 0.6 Hz band removes it)\n")
cat("  3. an in-band 2nd harmonic degraded detection badly but still not by\n")
cat("     threshold, because the extrema it creates are large too\n\n")
cat("The reason is visible in the prominence distribution. The detection band\n")
cat("smooths broadband noise so thoroughly that synthetic recordings contain\n")
cat("almost no low-prominence extrema, so the whole swept range lies below the\n")
cat("synthetic floor:\n\n")
print(prom_dist, row.names = FALSE, digits = 3)
if (have_real) {
  cat("\nReal signals carry the population of small ripples that a prominence\n")
  cat("threshold exists to remove. Same measurement, participant ", DEBUG_PID, ":\n\n",
      sep = "")
  print(prom_real_dist, row.names = FALSE, digits = 3)
}
cat("\nSo the threshold is set from Part 3, which is the route Norm approved and\n")
cat("what respkit prescribes: pick it by looking at what gets rejected, not by\n")
cat("its effect on the summary statistics.\n")

cat("\n", strrep("=", 78), "\n\n", sep = "")
cat("PART 3. PROMINENCE, PARTICIPANT ", DEBUG_PID, "\n\n", sep = "")
if (!have_real) {
  cat("SKIPPED: no RDS at ", rds, "\n", sep = "")
} else {
  cat("Single-device quantities only. Breath count is whitelisted (Section 1.7).\n")
  cat("Nothing between-device is computed.\n\n")
  for (dev in c("biopac", "accel")) {
    cat("--- ", dev, " ---\n", sep = "")
    s <- prom_real[prom_real$device == dev, c("prom", "n_onsets", "n_kept",
                                              "n_dropped", "med_dur_ms")]
    print(s, row.names = FALSE)
    cat("\n")
  }
  cat("n_dropped counts intervals outside the ",
      ONSET_MIN_BREATH_MS, "-", ONSET_MAX_BREATH_MS, " ms plausibility bounds.\n", sep = "")
  cat("A threshold that is too low shows as a rising n_onsets with rising\n")
  cat("n_dropped: it is manufacturing short cycles out of noise ripples.\n")

  cat("\nPolarity check (respkit BeforeYouRun item 2).\n")
  cat("Median duty cycle; below 0.50 means the signal rises on inhalation.\n")
  for (dev in names(pol))
    cat(sprintf("  %-7s duty %.3f  ->  %s\n", dev, pol[[dev]]["duty"],
                if (isTRUE(pol[[dev]]["verdict_up"] == 1)) "up (expected)"
                else "DOWN or undetermined - INSPECT"))
}
cat("\nNo between-device quantity appears anywhere above.\n")
sink()

message("Wrote: ", OUT_REPORT)
