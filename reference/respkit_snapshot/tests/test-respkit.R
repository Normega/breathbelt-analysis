# =====================================================================
#  test-respkit.R
#
#  Run from the package root with:
#      Rscript tests/test-respkit.R
#  or, once installed, via R CMD check.
# =====================================================================

# Two ways this file gets run, and it has to work under both:
#
#   Rscript tests/test-respkit.R   from the package root, against the working
#                                  tree. The source R/ directory is present.
#   R CMD check                    from respkit.Rcheck/tests, against the
#                                  INSTALLED package. There is no R/ directory,
#                                  and helper-synth.R has already been run as a
#                                  separate test file, so its definitions are
#                                  not in scope here.
#
# The working tree wins when it exists, so development never silently tests an
# older installed copy. Otherwise the namespace is attached rather than the
# package merely loaded, because these tests exercise internal helpers
# (empty_breath_table, ols_slope, prev_greater_idx, debounce_edges) as well as
# the exported API.
if (!nzchar(Sys.getenv("RESPKIT_SOURCED"))) {
  src_root <- if (dir.exists("R") && file.exists("DESCRIPTION")) "."
              else if (dir.exists("../R") && file.exists("../DESCRIPTION")) ".."
              else NA_character_

  if (!is.na(src_root)) {
    for (f in list.files(file.path(src_root, "R"), pattern = "[.]R$", full.names = TRUE))
      source(f)
  } else if (requireNamespace("respkit", quietly = TRUE)) {
    attach(asNamespace("respkit"), name = "respkit-internals", warn.conflicts = FALSE)
  } else {
    stop("Cannot find respkit: no source tree here and the package is not installed.",
         call. = FALSE)
  }

  helper <- Filter(file.exists,
                   c("helper-synth.R", "tests/helper-synth.R", "../tests/helper-synth.R"))
  if (!length(helper))
    stop("Cannot find helper-synth.R next to the test file.", call. = FALSE)
  source(helper[1])

  suppressPackageStartupMessages(library(signal))
}

cat("\n== decimation ==\n")

# The defect being fixed: the original staging loop used integer division on
# the remaining factor, so the achieved decimation undershot the request.
for (q in c(2, 4, 6, 8, 13, 20, 26, 39, 40, 50, 78, 80, 100, 120, 169, 200)) {
  st <- decimation_stages(q)
  ok(prod(as.numeric(st)) == q, sprintf("stages for q=%d multiply to %d (%s)",
                                        q, q, paste(st, collapse = "x")))
  ok(all(st <= 13), sprintf("all stages for q=%d are <= 13", q))
}

ok(legacy_decimation_factor(80)  == 78, "legacy loop achieved 78 when asked for 80")
ok(legacy_decimation_factor(20)  == 13, "legacy loop achieved 13 when asked for 20")
ok(legacy_decimation_factor(100) == 91, "legacy loop achieved 91 when asked for 100")
ok(legacy_decimation_factor(78)  == 78, "legacy loop was correct for 78")

# A prime factor above the stage limit must warn, not silently change the ratio.
w <- NULL
st <- withCallingHandlers(decimation_stages(34),
                          warning = function(x) { w <<- conditionMessage(x)
                                                  invokeRestart("muffleWarning") })
ok(prod(as.numeric(st)) == 34, "q=34 (2 x 17) still multiplies exactly to 34")
ok(grepl("prime factor", w), "q=34 warns about the oversized stage")


cat("\n== recording container ==\n")

s <- synth_resp(rep(4, 30), duty = 0.4, fs = 25)
rec <- resp_recording(s$signal, fs = s$fs, id = "synth01", units = "volts")

ok(is_resp_recording(rec), "constructor returns a resp_recording")
near(resp_duration(rec), length(s$signal) / 25, 1e-9, "duration matches n/fs")
near(resp_time(rec)[1], 0, 1e-12, "first sample is at t = 0")

sl <- resp_slice(rec, from = 10, to = 30)
near(sl$t0, resp_time(rec)[which(resp_time(rec) >= 10)[1]], 1e-9,
     "slice keeps the absolute clock in t0")
near(min(resp_time(sl)), sl$t0, 1e-12, "sliced times start at the new t0")
ok(length(resp_provenance(sl)) == 1, "slice appends exactly one provenance line")

errors_with(resp_recording(numeric(0), fs = 25), "empty", "empty signal is rejected")
errors_with(resp_recording(1:10, fs = -5), "positive", "negative fs is rejected")
errors_with(resp_slice(rec, from = 1e6), "no samples", "out-of-range slice is rejected")


cat("\n== filtering ==\n")

# Reflection padding must remove the edge transient that plain filtfilt leaves.
# A pure oscillation on a large DC offset has a known correct band-pass output:
# the oscillation itself. Measure the deviation from it at the edges.
tt_f  <- seq(0, 400, by = 1 / 25)
osc   <- sin(2 * pi * 0.25 * tt_f)
offs  <- osc + 20                       # realistic belt DC offset

padded   <- resp_filter(offs, low = 0.05, high = 1, fs = 25, pad_s = 60)
unpadded <- resp_filter(offs, low = 0.05, high = 1, fs = 25, pad_s = 0)

edge <- seq_len(25 * 15)
mid  <- seq(length(tt_f) %/% 2, by = 1, length.out = 25 * 15)

err_pad   <- max(abs(padded[edge]   - osc[edge]))
err_nopad <- max(abs(unpadded[edge] - osc[edge]))

tail_i     <- (length(tt_f) - 25 * 15 + 1):length(tt_f)
err_pad_t  <- max(abs(padded[tail_i]   - osc[tail_i]))
err_nop_t  <- max(abs(unpadded[tail_i] - osc[tail_i]))

ok(err_pad < 0.01,
   sprintf("with padding the first 15 s are accurate to %.5f", err_pad))
ok(err_nopad > 1,
   sprintf("without padding the first 15 s are wrong by up to %.3f", err_nopad))
ok(err_nopad / err_pad > 100,
   sprintf("padding reduces the leading edge transient by %.0fx", err_nopad / err_pad))

# Both ends. reflect_pad() pads head and tail independently, so a test reading
# only the first 15 s leaves half of it unguarded.
ok(err_pad_t < 0.01,
   sprintf("with padding the last 15 s are accurate to %.5f", err_pad_t))
ok(err_nop_t / err_pad_t > 100,
   sprintf("and the trailing transient is reduced by %.0fx", err_nop_t / err_pad_t))
near(padded[mid], osc[mid], 0.01, "the middle of the recording is unaffected")

# A single NA must not destroy the whole output. Plain filtfilt propagates it
# across every sample.
long  <- synth_resp(rep(4, 200), duty = 0.4, fs = 25)
gappy <- long$signal
gappy[500] <- NA
out <- resp_filter(gappy, low = 0.05, high = 1, fs = 25)
ok(sum(is.na(out)) == 1, "one NA in, one NA out")
ok(all(is.finite(out[-500])), "the rest of the signal survives an NA")

errors_with(resp_filter(long$signal, low = 1, high = 0.5, fs = 25),
            "must be below", "inverted cutoffs are rejected")


cat("\n== prominence and local maxima ==\n")

# Plateaus: the naive strict-inequality test misses these entirely.
plateau <- c(0, 1, 2, 3, 3, 3, 2, 1, 0, 2, 0)
ok(identical(local_maxima(plateau), c(5L, 10L)),
   "plateau maximum is found and reported at the centre of the flat run")

# Textbook prominence: a tall peak flanked by a shorter one.
#   values:  0 5 0 3 0
#   peak at index 2 has prominence 5; peak at index 4 has prominence 3.
v <- c(0, 5, 0, 3, 0)
near(peak_prominence(v, c(2L, 4L)), c(5, 3), 1e-12,
     "prominence matches the standard definition")

# The case where bounding at the nearest higher *peak* rather than the nearest
# higher *sample* inflates the answer. Signal rises to 10, dips to -5, rises
# to 4, dips to 3, rises to 3.5. For the peak of height 3.5 the nearest higher
# sample to the left is the 4; the nearest higher detected peak is also the 4,
# so this specific case agrees. Verify the general property instead: prominence
# never exceeds the peak height above the global minimum.
set.seed(7)
rv <- cumsum(stats::rnorm(2000)) + sin(seq(0, 40, length.out = 2000)) * 5
rp <- local_maxima(rv)
pr <- peak_prominence(rv, rp)
ok(all(pr >= 0), "prominence is never negative")
ok(all(pr <= rv[rp] - min(rv) + 1e-9),
   "prominence never exceeds height above the global minimum")


cat("\n== detection ==\n")

clean <- synth_resp(rep(4, 40), duty = 0.4, amplitude = 1, fs = 25, noise = 0.01)
rec_c <- resp_recording(clean$signal, fs = 25, id = "clean")
pp    <- resp_preprocess(rec_c, target_fs = NULL, low = 0.05, high = 1,
                         despike = FALSE, normalise = "robust")
det   <- resp_detect(pp$recording, min_prominence = 0.5, min_distance_s = 1.5)

ok(length(det$peaks) == 40,
   sprintf("all 40 synthetic breaths detected (got %d peaks)", length(det$peaks)))

# With no filtering at all the detector is exact, which establishes that any
# timing error seen later comes from the filter and not from the detector.
pp_nf  <- resp_preprocess(resp_recording(synth_resp(rep(4, 40), duty = 0.4, fs = 25,
                                                   noise = 0)$signal, fs = 25),
                          target_fs = NULL, low = NULL, high = NULL,
                          despike = FALSE, normalise = "robust")
det_nf <- resp_detect(pp_nf$recording, min_prominence = 0.5, min_distance_s = 1.5)
near(det_nf$peak_times, synth_resp(rep(4, 40), duty = 0.4, fs = 25, noise = 0)$peak_times,
     1e-9, "unfiltered detection recovers peak times exactly")

near(mean(det$peak_times - clean$peak_times), 0, 0.10,
     "mean peak timing bias under a 1 Hz low-pass stays under 100 ms")

# Alternation must never leave two peaks with no trough between them.
merged <- c(rep(1L, length(det$peaks)), rep(0L, length(det$troughs)))[
  order(c(det$peaks, det$troughs))]
ok(!any(diff(merged) == 0), "peaks and troughs strictly alternate after detection")

# Both detectors should agree on the count for a clean signal.
det_zc <- resp_detect(pp$recording, method = "zerocross")
ok(abs(length(det_zc$peaks) - 40) <= 1,
   sprintf("zero-crossing detector also finds ~40 breaths (got %d)",
           length(det_zc$peaks)))

# Drift is the case that separates them: prominence is indifferent to it,
# zero-crossing is not.
drifty <- synth_resp(rep(4, 40), duty = 0.4, fs = 25, noise = 0.01, drift = 6)
rec_d  <- resp_recording(drifty$signal, fs = 25)
# Detrend only mildly, so drift survives into the detection signal.
pp_d   <- resp_preprocess(rec_d, target_fs = NULL, low = 0.01, high = 1,
                          despike = FALSE, normalise = "robust")
det_p  <- resp_detect(pp_d$recording, method = "prominence",
                      min_prominence = 0.3, min_distance_s = 1.5)
det_z  <- suppressWarnings(resp_detect(pp_d$recording, method = "zerocross"))
ok(abs(length(det_p$peaks) - 40) < abs(length(det_z$peaks) - 40) ||
     length(det_p$peaks) == 40,
   sprintf("under drift, prominence (%d peaks) is at least as good as zero-crossing (%d)",
           length(det_p$peaks), length(det_z$peaks)))


cat("\n== breath table ==\n")

bt <- breath_table(det, pp$recording, polarity = "up")

# The synthetic signal opens and closes at a trough. A sample at the very
# start or end of a recording cannot be a local minimum, so 40 synthesised
# breaths yield 39 detectable interior troughs and 38 complete cycles. A
# breath table only ever contains cycles bounded by two detected troughs;
# it never invents a boundary to reach an expected count.
ok(nrow(bt) == length(det$troughs) - 1L,
   sprintf("cycles = troughs - 1 (%d cycles from %d troughs)",
           nrow(bt), length(det$troughs)))
ok(nrow(bt) == 38, sprintf("38 complete cycles from 40 synthesised breaths (got %d)",
                           nrow(bt)))
near(stats::median(bt$duration), 4, 0.05, "median duration recovers 4 s")
near(stats::median(bt$duty_cycle), 0.4, 0.03,
     "median duty cycle recovers the 0.4 that was synthesised")
near(stats::median(bt$rate_bpm), 15, 0.2, "median rate recovers 15/min")
# abs(), and against the ground truth rather than against the table's own
# columns: t_peak - t_start plus t_end - t_peak is t_end - t_start by
# construction, so comparing them tests nothing about the measurement.
# NOT `Ti + Te == Ttot`: with duration = t_end - t_start, inhale = t_peak -
# t_start and exhale = t_end - t_peak, that identity holds for arbitrary
# numbers and tests nothing. Check the phases against the synthesised truth.
ok(all(bt$inhale_dur > 0 & bt$exhale_dur > 0, na.rm = TRUE),
   "both phases of every cycle have positive duration")
near(stats::median(bt$inhale_dur, na.rm = TRUE) /
       stats::median(bt$duration, na.rm = TRUE), 0.4, 0.03,
     "and the inspiratory fraction matches the 0.4 that was synthesised")
near(stats::median(bt$inhale_dur, na.rm = TRUE), 4 * 0.4, 0.15,
     "inspiratory time matches the synthesised Ti")
near(stats::median(bt$exhale_dur, na.rm = TRUE), 4 * 0.6, 0.15,
     "expiratory time matches the synthesised Te")
ok(all(bt$amplitude > 0, na.rm = TRUE), "amplitudes are positive")

# Asymmetric breathing must produce a duty cycle away from 0.5, which is the
# feature the original pipeline could not measure at all.
asym  <- synth_resp(rep(5, 30), duty = 0.25, fs = 25, noise = 0.01)
rec_a <- resp_recording(asym$signal, fs = 25)
res_a <- resp_analyse(rec_a, target_fs = NULL, min_prominence = 0.5,
                      min_distance_s = 2, quality = FALSE)
bt_a  <- res_a$breaths
near(stats::median(bt_a$duty_cycle), 0.25, 0.05,
     "a 0.25 duty cycle is recovered as 0.25, not as 0.5")

# Regression test for the filter-induced timing bias. Measuring on the same
# aggressively band-passed signal used for detection drags the duty cycle
# towards 0.5; snapping onto a wider-band copy first does not.
biased <- resp_analyse(rec_a, target_fs = NULL, detect_band = c(0.05, 0.4),
                       measure_band = NULL, min_prominence = 0.5,
                       min_distance_s = 2, quality = FALSE)
dc_biased <- stats::median(biased$breaths$duty_cycle, na.rm = TRUE)
dc_fixed  <- stats::median(bt_a$duty_cycle, na.rm = TRUE)
ok(dc_biased > 0.40,
   sprintf("measuring on a 0.4 Hz low-passed signal inflates duty cycle to %.3f", dc_biased))
ok(abs(dc_fixed - 0.25) < abs(dc_biased - 0.25) / 3,
   sprintf("refining onto a wider band recovers %.3f instead of %.3f (true 0.25)",
           dc_fixed, dc_biased))

# Polarity: inverting the signal and the polarity argument together must give
# the same timing features back.
rec_inv <- rec_a
rec_inv$signal <- -rec_inv$signal
res_inv <- resp_analyse(rec_inv, target_fs = NULL, polarity = "down",
                        min_prominence = 0.5, min_distance_s = 2, quality = FALSE)
near(stats::median(res_inv$breaths$duty_cycle, na.rm = TRUE),
     stats::median(bt_a$duty_cycle, na.rm = TRUE), 0.03,
     "inverting signal and polarity together leaves duty cycle unchanged")

pol <- resp_polarity(res_a$detection, res_a$measure)
ok(identical(pol$suggestion, "up"), "polarity diagnostic identifies rise-on-inhale")
ok(isTRUE(pol$confident), "polarity diagnostic is confident for asymmetric breathing")

# An inverted signal must actually be diagnosed as inverted. Asserting only
# that the upright case says "up" is satisfied by a function that always
# returns "up".
inv_a <- res_a$measure
inv_a$signal <- -inv_a$signal
det_pol <- resp_detect(inv_a, min_prominence = 0.5, min_distance_s = 2)
ok(identical(resp_polarity(det_pol, inv_a)$suggestion, "down"),
   "polarity diagnostic identifies an inverted signal as fall-on-inhale")

# Confidence must track the data. The previous form re-derived the very
# quantity the function uses to set the flag, giving `!P || P` -- true for
# every input, including inputs where its stated claim is false.
conf_of <- function(du) {
  a <- synth_resp(rep(4, 40), duty = du, fs = 25, noise = 0.01)
  o <- suppressMessages(resp_analyse(resp_recording(a$signal, fs = 25),
                                     target_fs = NULL, min_prominence = 0.4,
                                     min_distance_s = 1.5, quality = FALSE))
  resp_polarity(o$detection, o$measure)
}
p_asym <- conf_of(0.35)
p_sym  <- conf_of(0.50)
ok(isTRUE(p_asym$confident),
   sprintf("clearly asymmetric breathing gives a confident verdict (duty %.3f)",
           p_asym$duty_cycle_up))
ok(!isTRUE(p_sym$confident),
   sprintf("a symmetric signal does not (duty %.3f)", p_sym$duty_cycle_up))
ok(identical(p_asym$suggestion, "up"), "and the asymmetric case is called correctly")

# Flagging keeps everything and marks it, rather than silently dropping rows.
bt_f <- flag_breaths(bt)
ok(nrow(bt_f) == nrow(bt), "flagging does not remove rows")
ok(all(c("low_amplitude", "duration_outlier", "keep") %in% names(bt_f)),
   "flagging adds the expected columns")


cat("\n== features ==\n")

# A deliberate ramp in breath duration: the slope must come back out.
ramp   <- synth_resp(seq(3, 6, length.out = 24), duty = 0.4, fs = 25, noise = 0.01)
rec_r  <- resp_recording(ramp$signal, fs = 25)
pp_r   <- resp_preprocess(rec_r, target_fs = NULL, low = 0.03, high = 1,
                          despike = FALSE, normalise = "robust")
det_r  <- resp_detect(pp_r$recording, min_prominence = 0.4, min_distance_s = 1.5)
bt_r   <- flag_breaths(breath_table(det_r, pp_r$recording))
sm     <- summarise_breaths(bt_r)

expected_slope <- (6 - 3) / 23
near(sm$duration_slope_per_breath, expected_slope, 0.02,
     sprintf("per-breath duration slope recovers %.4f s/breath", expected_slope))
ok(sm$duration_slope_per_s < sm$duration_slope_per_breath,
   "per-second slope is smaller than per-breath slope when breaths lengthen")

# The two rate summaries must differ in the direction Jensen's inequality
# requires, and agree when durations are constant.
ok(sm$rate_bpm_mean > sm$rate_from_mean_duration,
   "mean of instantaneous rates exceeds rate of mean duration when durations vary")
sm_const <- summarise_breaths(flag_breaths(bt))
near(sm_const$rate_bpm_mean, sm_const$rate_from_mean_duration, 0.05,
     "the two rate summaries agree for constant durations")

# Closed-form slope must equal lm().
set.seed(3)
yy <- stats::rnorm(20); xx <- seq_along(yy)
near(ols_slope(yy, xx), unname(stats::coef(stats::lm(yy ~ xx))[2]), 1e-10,
     "closed-form slope equals lm()")
ok(is.na(ols_slope(c(1, NA))), "slope with fewer than two finite points is NA")

rs <- resp_rate_series(bt_r, fs_out = 4)
ok(nrow(rs) > 0 && all(c("time", "rate_bpm", "rvt") %in% names(rs)),
   "continuous rate series has the expected shape")
ok(all(is.finite(rs$rate_bpm)), "continuous rate series has no gaps")


cat("\n== epoching ==\n")

eps <- resp_epochs(onset = c(0, 40, 80), duration = 20, lag = 0,
                   label = c("a", "b", "c"), condition = c("x", "y", "x"))
ok(nrow(eps) == 3 && all(eps$end - eps$start == 20), "epoch table built")
ok(identical(eps$condition, c("x", "y", "x")), "extra columns are carried through")

ef <- epoch_features(bt_f, eps, rule = "start")
ok(nrow(ef) == 3, "one row per epoch, always")
ok(all(ef$n_breaths > 0), "each 20 s epoch of 4 s breathing contains breaths")
ok(all(ef$coverage_frac > 0.6 & ef$coverage_frac <= 1),
   sprintf("coverage is reported and plausible (%s)",
           paste(round(ef$coverage_frac, 2), collapse = ", ")))
ok(all(ef$n_breaths_partial >= 1),
   "partial breaths at window edges are counted, not invented")

# The "start" rule must assign each breath to at most one epoch.
assigned <- epoch_breaths(bt_f, eps, rule = "start")
ok(nrow(assigned) == nrow(bt_f), "start rule does not duplicate breaths")

# An epoch with no data yields a row of NAs, not a missing row.
eps_far <- resp_epochs(onset = 1e5, duration = 20)
ef_far  <- epoch_features(bt_f, eps_far)
ok(nrow(ef_far) == 1 && ef_far$n_breaths == 0,
   "an epoch outside the recording still returns exactly one row")

errors_with(resp_epochs(onset = 10, offset = 5), "end at or before",
            "a backwards window is rejected")


cat("\n== quality ==\n")

good <- synth_resp(rep(4, 200), duty = 0.4, fs = 50, noise = 0.02)
q_good <- resp_quality(good$signal, fs = 50, trim_s = 20, target_fs = 25)
ok(q_good$quality == "good",
   sprintf("clean 4 s breathing is graded good (got %s: %s)",
           q_good$quality, q_good$note))
# 0.02 Hz would be 2.4 FFT bins here; half a bin is the meaningful bound.
near(q_good$dominant_freq_hz, 0.25, 0.004,
     "dominant frequency recovers 0.25 Hz to within half an FFT bin")

flat_sig <- rep(0.5, 50 * 400)
q_flat <- suppressWarnings(resp_quality(flat_sig, fs = 50, trim_s = 20))
ok(q_flat$quality == "unusable", "a flatline is graded unusable")
ok(q_flat$flatline_pct > 90, "flatline percentage is detected on the raw signal")

# Flatline detection must work on the raw signal. Filtering a constant first
# and then testing for constancy is what the original did; verify the raw test
# catches a partial flatline that filtering would smear.
part <- good$signal
part[(50 * 100):(50 * 200)] <- part[50 * 100]
fl <- resp_flatline(part, fs = 50, min_run_s = 1)
ok(fl$pct > 10, sprintf("a 100 s stuck stretch is detected (%.1f%% of samples)", fl$pct))
ok(nrow(fl$runs) >= 1, "flatline runs are located, not just counted")

sat <- resp_saturation(c(rep(0, 100), seq(0, 1, length.out = 800), rep(1, 100)))
ok(sat$pct_saturated > 15, "saturation at both rails is detected")

qs <- resp_quality(good$signal, fs = 50, trim_s = 20, by_segment = TRUE,
                   segment_s = 60)
ok(!is.null(qs$segments) && nrow(qs$segments) >= 3,
   "segment-wise quality returns per-segment rows")
ok(all(qs$segments$usable), "all segments of a clean recording are usable")


cat("\n== io round trip ==\n")

tmp <- file.path(tempdir(), "respkit_test.rds")
rec2 <- resp_recording(clean$signal, fs = 25.641, id = "roundtrip",
                       units = "volts", fs_native = 2000,
                       meta = list(side = "R", session = 2L))
resp_write_rds(rec2, tmp)
back <- resp_read_rds(tmp)
ok(is_resp_recording(back), "round trip returns a resp_recording")
near(back$fs, 25.641, 1e-12, "sampling rate survives the round trip exactly")
ok(identical(back$meta$side, "R"), "metadata survives the round trip")
ok(identical(back$signal, rec2$signal), "signal survives the round trip")

# Legacy import must correct the sampling rate and say so.
legacy <- list(id = 10018, signal = clean$signal, fs = 25, native_fs = 2000,
               side = "R", abcode = 0L, n_triggers = 0L, start_indices = NULL)
lw <- NULL
conv <- withCallingHandlers(
  resp_read_legacy_rds(legacy),
  warning = function(x) { lw <<- conditionMessage(x); invokeRestart("muffleWarning") })
near(conv$fs, 2000 / 78, 1e-9, "legacy fs corrected from 25 to 2000/78 Hz")
ok(grepl("25.641|achieved", lw), "legacy import warns about the correction")
ok(identical(conv$meta$side, "R"), "unknown legacy fields are preserved in meta")

conv_raw <- resp_read_legacy_rds(legacy, correct_fs = FALSE)
near(conv_raw$fs, 25, 1e-12, "correct_fs = FALSE reproduces the original rate")

# start_indices in native samples become seconds.
legacy2 <- legacy
legacy2$start_indices <- c(200000, 4000000)
conv2 <- suppressWarnings(resp_read_legacy_rds(legacy2))
near(conv2$events$time, c(100, 2000), 1e-9,
     "untrimmed start_indices are read as native samples and converted to seconds")

legacy3 <- legacy2
legacy3$trim_offset_s <- 173
conv3 <- suppressWarnings(resp_read_legacy_rds(legacy3))
near(conv3$events$time, 173 + c(200000, 4000000) / (2000 / 78), 1e-6,
     "trimmed start_indices are read as downsampled samples, offset by t0")
near(conv3$t0, 173, 1e-9,
     "a trimmed legacy file carries its trim offset as t0, not as a silent zero")

# The offset is recoverable exactly from trim_offset_samp at the CORRECTED
# rate; the stored trim_offset_s was computed at the uncorrected one and is
# about 2.5% too large.
legacy4 <- legacy2
legacy4$trim_offset_s    <- 1458.44
legacy4$trim_offset_samp <- 36461
conv4 <- suppressWarnings(resp_read_legacy_rds(legacy4))
near(conv4$t0, 36461 / (2000 / 78), 1e-6,
     "t0 comes from trim_offset_samp at the corrected rate")
ok(abs(conv4$t0 - legacy4$trim_offset_s) > 30,
   sprintf("and differs from the stored trim_offset_s (%.1f vs %.1f s)",
           conv4$t0, legacy4$trim_offset_s))


ok(resp_rds_is_legacy(legacy), "legacy format is recognised")
ok(!resp_rds_is_legacy(rec2), "respkit format is not mistaken for legacy")


cat("\n== end-to-end on a realistic recording ==\n")

real <- synth_resp(stats::runif(300, 3, 5), duty = 0.42, amplitude = 1,
                   fs = 500, noise = 0.05, drift = 3, seed = 42)
r <- resp_recording(real$signal, fs = 500, id = "e2e", units = "volts")
pp_e <- resp_preprocess(r, target_fs = 25, low = 0.05, high = 1)
ok(abs(pp_e$recording$fs - 25) < 1e-9, "500 Hz decimates exactly to 25 Hz")
ok(length(pp_e$stages) == 5, "all preprocessing stages are retained")

det_e <- resp_detect(pp_e$recording, min_prominence = 0.4, min_distance_s = 1.5)
bt_e  <- flag_breaths(breath_table(det_e, pp_e$recording))
ok(nrow(bt_e) > 250, sprintf("most of 300 breaths recovered (%d cycles)", nrow(bt_e)))
near(stats::median(bt_e$duration), 4, 0.25,
     "median duration is near the 3-5 s uniform mean of 4 s")
ok(mean(bt_e$keep) > 0.9,
   sprintf("over 90%% of breaths pass QC (%.1f%%)", 100 * mean(bt_e$keep)))

sm_e <- summarise_breaths(bt_e)
ok(is.finite(sm_e$rvt_mean) && sm_e$rvt_mean > 0, "RVT is computed and positive")
ok(is.finite(sm_e$duty_cycle_mean), "duty cycle is computed end to end")

cat("\n== regression: bugs found in review ==\n")

# --- epoch_breaths indexed rows by the `breath` COLUMN rather than by
# position. A breath table that had been filtered errored outright; one that
# had been row-bound across participants was silently half-assigned.
bt_reg  <- flag_breaths(breath_table(det_r, pp_r$recording))
eps_reg <- resp_epochs(onset = c(0, 40, 80), duration = 20)

truth_for <- function(tab) {
  v <- rep(NA_integer_, nrow(tab))
  for (k in seq_len(nrow(eps_reg)))
    v[tab$t_start >= eps_reg$start[k] & tab$t_start <= eps_reg$end[k]] <- k
  v
}

filt_bt <- bt_reg[bt_reg$t_start > 20, , drop = FALSE]
ok(!identical(filt_bt$breath, seq_len(nrow(filt_bt))),
   "the filtered table's breath column no longer equals row position")
ok(identical(as.integer(epoch_breaths(filt_bt, eps_reg)$epoch), truth_for(filt_bt)),
   "epoching a filtered breath table assigns the right rows")

rev_bt <- bt_reg[order(-bt_reg$t_start), , drop = FALSE]
ok(identical(as.integer(epoch_breaths(rev_bt, eps_reg)$epoch), truth_for(rev_bt)),
   "epoching a reordered breath table assigns the right rows")

both_bt <- rbind(bt_reg, bt_reg)
ok(identical(as.integer(epoch_breaths(both_bt, eps_reg)$epoch), truth_for(both_bt)),
   "epoching a row-bound two-participant table assigns the right rows")

ok(sum(!is.na(epoch_breaths(both_bt, eps_reg)$epoch)) ==
     2L * sum(!is.na(epoch_breaths(bt_reg, eps_reg)$epoch)),
   "a doubled table yields exactly twice the assignments")

# Overlapping windows must be reported, not silently resolved.
wov <- NULL
invisible(withCallingHandlers(
  epoch_breaths(bt_reg, resp_epochs(onset = c(0, 10), duration = 20), rule = "start"),
  warning = function(x) { wov <<- conditionMessage(x); invokeRestart("muffleWarning") }))
ok(!is.null(wov) && grepl("more than one window", wov),
   "overlapping windows warn under the start rule")

errors_with(epoch_breaths(bt_reg,
                          data.frame(epoch = c(1L, 1L), label = c("a", "b"),
                                     start = c(0, 10), end = c(5, 15))),
            "must be unique", "duplicate epoch ids are rejected")

# --- resp_rate_series("constant") stepped at cycle midpoints, so every value
# was carried half a breath late.
step_bt <- data.frame(breath = 1:3, t_start = c(0, 10, 20), t_end = c(10, 20, 30),
                      rate_bpm = c(6, 12, 30))
rs_step <- resp_rate_series(step_bt, fs_out = 1, from = 0, to = 30,
                            what = "rate_bpm", method = "constant")
val_at <- function(tt) rs_step$rate_bpm[which.min(abs(rs_step$time - tt))]
near(c(val_at(1), val_at(9), val_at(11), val_at(19), val_at(26)),
     c(6, 6, 12, 12, 30), 1e-9,
     "each breath's value covers its own cycle, not one shifted half a breath")

# --- resp_decimate silently returned an all-NaN signal for a large prime
# factor. signal::decimate degrades before it fails: q=90 gives 33% amplitude
# error and q=100 gives 65%, both finite, so a finiteness check alone is not
# enough and the factor itself must be refused.
errors_with(decimation_stages(199), "cannot be decimated in stages",
            "a decimation factor with a huge prime factor is refused")
errors_with(decimation_stages(2 * 41), "cannot be decimated in stages",
            "q = 82 is refused rather than run as a single stage of 41")

w34 <- NULL
st34 <- withCallingHandlers(
  decimation_stages(34),
  warning = function(x) { w34 <<- conditionMessage(x); invokeRestart("muffleWarning") })
ok(prod(as.numeric(st34)) == 34 && !is.null(w34),
   "a moderate oversized factor (17) still warns but is allowed")

# resp_downsample should route around the bad factor on its own.
sm <- suppressMessages(resp_downsample(resp_recording(stats::rnorm(200000), fs = 2048),
                                       target_fs = 25))
ok(all(prime_factors(round(2048 / sm$fs)) <= 13),
   sprintf("resp_downsample picks a smoothly factorable q (2048 Hz -> %.4f Hz)", sm$fs))
ok(abs(sm$fs - 25) / 25 < 0.05, "and still lands within 5% of the target")
ok(all(is.finite(sm$signal)), "the decimated signal is finite")

# --- cycles with no detected peak carry a valid duration but nothing else.
# They must be counted so the smaller denominator behind the peak-derived
# statistics stays visible.
ok("has_peak" %in% names(bt_reg), "breath table reports has_peak")
ok(all(bt_reg$has_peak), "every cycle has a peak after alternation is enforced")
ok("n_breaths_no_peak" %in% names(summarise_breaths(bt_reg)),
   "summary reports the count of peakless cycles")

# --- resp_despike thresholded the first difference, which identifies the
# transitions either side of a spike rather than the spike itself. A 40-unit
# spike at sample 1 left a 20-unit artefact at sample 2.
tt_d  <- seq(0, 20, by = 1 / 25)
cl_d  <- sin(2 * pi * 0.25 * tt_d)
sp_1  <- cl_d; sp_1[1] <- 40
sp_n  <- cl_d; sp_n[length(sp_n)] <- 40
ok(max(abs(resp_despike(sp_1, fs = 25) - cl_d)) < 0.2,
   "an endpoint spike leaves no artefact behind")
ok(max(abs(resp_despike(sp_n, fs = 25) - cl_d)) < 0.2,
   "the same holds at the tail")

# The running-median window must not carry the breath's own curvature.
for (w in c(0.2, 0.3)) {
  clean_a <- synth_resp(rep(5, 30), duty = 0.25, fs = 25, noise = 0.01)$signal
  ok(100 * mean(resp_despike(clean_a, fs = 25, window_s = w) != clean_a) < 1,
     sprintf("despike at window_s=%.1f flags under 1%% of a clean signal", w))
}

flat_sp <- rep(1.0, 250); flat_sp[100] <- 50
ok(abs(resp_despike(flat_sp, fs = 25)[100] - 1) < 1e-6,
   "a spike on an otherwise perfectly flat trace is still removed")
quant_sp <- round(sin(2 * pi * 0.25 * tt_d)); quant_sp[200] <- 99
ok(abs(resp_despike(quant_sp, fs = 25)[200]) < 5,
   "a spike on a coarsely quantised trace is still removed")

# --- resp_filter fell through to signal::butter with an empty cutoff when the
# only cutoff given was at or above Nyquist.
vv <- stats::rnorm(500)
ok(identical(suppressMessages(resp_filter(vv, low = NULL, high = 20, fs = 25)), vv),
   "a lone above-Nyquist cutoff returns the signal unfiltered, not an error")
errors_with(resp_filter(vv, low = 20, high = NULL, fs = 25), "at or above Nyquist",
            "a lone above-Nyquist low cutoff is rejected with a clear message")

# --- resp_psd was missing the factor of two that makes a one-sided spectrum
# integrate to the signal variance.
set.seed(11)
xn  <- stats::rnorm(15000)
psd <- resp_psd(xn, fs = 25, segment_s = 120)
near(var(xn) / (sum(psd$power) * (psd$freq[2] - psd$freq[1])), 1, 0.1,
     "PSD integrates to the signal variance (Parseval)")

# --- resp_saturation summed the two rail counts, so a flat signal was 200%.
# Two-sided. The historic bug reported 200%, so the guard was written as
# `<= 100` -- which is equally satisfied by 0%, and turning the rail test from
# `<=` to `<` makes a fully pinned signal report exactly that.
sat_flat <- resp_saturation(rep(1, 100))
near(sat_flat$pct_saturated, 100, 1e-9,
     "a fully rail-pinned signal is 100% saturated, neither 0 nor 200")
# Each rail separately, on the flat case where the value sits exactly on the
# boundary. The union alone cannot see one rail break, because the other
# still returns 100%; and an inclusive/exclusive slip only shows up on
# exact equality.
near(sat_flat$pct_at_min, 100, 1e-9, "with every sample counted at the lower rail")
near(sat_flat$pct_at_max, 100, 1e-9, "and at the upper rail")
ok(resp_saturation(stats::rnorm(10000))$pct_saturated < 1,
   "and ordinary noise is essentially unsaturated")

# The two rails separately: a union test alone still passes if only one of
# them is broken, because the other keeps the total at 100%.
sat_asym <- c(rep(-1, 200), seq(-1, 1, length.out = 600), rep(1, 200))
sat_a <- resp_saturation(sat_asym)
ok(sat_a$pct_at_min > 15,
   sprintf("a plateau at the lower rail is counted (%.1f%%)", sat_a$pct_at_min))
ok(sat_a$pct_at_max > 15,
   sprintf("and one at the upper rail too (%.1f%%)", sat_a$pct_at_max))

# --- resp_quality had no missing-data metric, so a mostly absent recording
# graded good; and by_segment crashed outright on an all-NA segment.
tt_q  <- seq(0, 600, by = 1 / 25)
base_q <- sin(2 * pi * 0.25 * tt_q) + 0.05 * stats::rnorm(length(tt_q))
gap_q <- base_q; gap_q[1:8000] <- NA
q_gap <- suppressWarnings(suppressMessages(resp_quality(resp_recording(gap_q, fs = 25))))
ok(q_gap$quality != "good",
   sprintf("a %.0f%% missing recording is not graded good", q_gap$na_pct))
ok(is.finite(q_gap$na_pct) && q_gap$na_pct > 50, "missing data is measured and reported")

seg_q <- base_q; seg_q[1:3000] <- NA
q_seg <- suppressWarnings(suppressMessages(
  resp_quality(resp_recording(seg_q, fs = 25), by_segment = TRUE)))
ok(is.list(q_seg) && !is.null(q_seg$segments),
   "by_segment survives a segment with no finite samples")
ok(any(!q_seg$segments$usable), "and marks that segment unusable")

# --- find_extrema_zerocross tested x > 0 and x < 0 separately, so a sample
# landing exactly on zero made its crossing invisible. On a quantised signal
# centred on its median that halved the breath count with no warning.
sy_q  <- synth_resp(rep(4, 30), duty = 0.4, fs = 25, noise = 0)
quant <- round(sy_q$signal * 100) + 500
ok(sum(quant == stats::median(quant)) > 10,
   "the quantised test signal really does have samples exactly at its median")
zc_med <- suppressWarnings(find_extrema_zerocross(quant, centre = "median"))
ok(abs(length(zc_med$peaks) - 30) <= 1,
   sprintf("median-centred quantised signal yields ~30 breaths (got %d)",
           length(zc_med$peaks)))

# Extrema are labelled by which half-cycle they came from, not by the sign of
# their value, so a run of cuts that does not alternate cannot mislabel them.
yy <- c(-1,-2,-1, 1, 2, 1, 0, -1,-2,-1, 1, 3, 1, -1, -2, -1, 1, 2, 1, -1)
zc <- find_extrema_zerocross(yy, centre = "none", amplitude_min = 0)
ok(12 %in% zc$peaks, "the tallest peak is not lost to an on-zero sample")
ok(!any(yy[zc$troughs] > 0), "no positive-half extremum is labelled a trough")

# --- refine_extrema used which.max, which returns the first index of a tie
# and so snapped every extremum to the left edge of a plateau, undoing the
# centre convention local_maxima() establishes.
xp <- c(0, 1, 2, 3, 3, 3, 3, 3, 2, 1, 0)
ok(refine_extrema(xp, local_maxima(xp), TRUE, 0.05, 100) == local_maxima(xp),
   "refinement onto the same signal keeps the plateau centre")

sat_sig <- synth_resp(rep(4, 40), duty = 0.40, fs = 25, noise = 0.005)$signal
sat_sig <- pmin(sat_sig, stats::quantile(sat_sig, 0.90))   # clamp -> plateaus
res_sat <- suppressMessages(resp_analyse(resp_recording(sat_sig, fs = 25),
                                         target_fs = NULL, refine_window_s = 0.4,
                                         min_prominence = 0.3, min_distance_s = 1.5,
                                         quality = FALSE))
near(stats::median(res_sat$breaths$duty_cycle, na.rm = TRUE), 0.40, 0.05,
     "a clamped, plateau-ridden signal still gives the right duty cycle")

# --- indices of 0 did not error: sig[0] returns a zero-length vector, so the
# column was silently recycled and unaffected breaths got wrong times too.
sg0 <- sin(2 * pi * seq(0, 20, by = 0.02) / 4)
errors_with(breath_table(list(peaks = c(50L, 250L), troughs = c(0L, 150L, 350L), fs = 50), sg0),
            "1-based and positive", "a zero index is rejected by breath_table")
errors_with(breath_table(list(peaks = 99999L, troughs = c(150L, 350L), fs = 50),
                         sg0, polarity = "down"),
            "past the end", "bounds are checked before the polarity swap")
errors_with(enforce_alternation(c(2L, 50L), 3L, values = c(0, 5, 0, 4, 0)),
            "exceeds the length", "enforce_alternation rejects out-of-range indices")
errors_with(enforce_alternation(2L, 2L, values = c(0, 5, 0, 4, 0)),
            "both a peak and a trough", "and rejects an index that is both")

# --- local_maxima leaked NA indices, which then errored inside peak_prominence.
ok(!anyNA(local_maxima(c(0, 3, 0, NA, 0, 5, 0))), "local_maxima returns no NA indices")
ok(is.integer(local_maxima(c(0, 1, 2, NA, 3, 4, 5))),
   "local_maxima does not error when NAs coexist with no maxima")

# --- polarity = "down" negates the signal internally; baseline is the one
# absolute level, and left negated it inverted the apparent drift direction.
down_sig <- 37 - synth_resp(rep(4, 30), duty = 0.4, fs = 25, noise = 0.005)$signal
res_dn <- suppressMessages(resp_analyse(resp_recording(down_sig, fs = 25, units = "volts"),
                                        target_fs = NULL, polarity = "down",
                                        normalise = "none", min_prominence = 0.3,
                                        min_distance_s = 1.5, quality = FALSE))
near(res_dn$breaths$baseline[1],
     res_dn$measure$signal[res_dn$breaths$i_start[1]], 1e-9,
     "baseline is reported on the recording's own scale under polarity=\"down\"")
ok(all(res_dn$breaths$amplitude > 0, na.rm = TRUE),
   "amplitudes stay positive under polarity=\"down\"")

# --- refinement can merge two extrema onto one sample, deleting a cycle, and
# can select the same sample as both a peak and a trough in a flat stretch.
fast_s <- sin(2 * pi * 0.5 * seq(0, 120, by = 1 / 25))
slow_s <- sin(2 * pi * 0.1 * seq(0, 120, by = 1 / 25))
w_merge <- NULL
invisible(withCallingHandlers(
  resp_detect(resp_recording(fast_s, fs = 25), refine_on = resp_recording(slow_s, fs = 25),
              refine_window_s = 2, min_prominence = 0.3, min_distance_s = 1),
  warning = function(x) { w_merge <<- conditionMessage(x); invokeRestart("muffleWarning") }))
ok(!is.null(w_merge), "merging extrema during refinement is warned about")

cat("\n== regression: found by fuzzing ==\n")

# --- Band-passed white noise wanders slowly enough to look like breathing:
# it passed the amplitude and frequency checks and yielded 43 "breaths".
# band_ratio is the only metric that separates it from a real signal.
set.seed(99)
q_noise <- suppressWarnings(suppressMessages(
  resp_quality(stats::rnorm(15000), fs = 25, trim_s = 20)))
ok(q_noise$quality != "good",
   sprintf("band-passed white noise is not graded good (band_ratio %.3f)",
           q_noise$band_ratio))
ok(q_noise$band_ratio < 0.80, "and its band ratio is below the threshold")

real_like <- synth_resp(rep(4, 150), duty = 0.4, fs = 25, noise = 0.05)$signal
q_real <- suppressWarnings(suppressMessages(resp_quality(real_like, fs = 25, trim_s = 20)))
ok(q_real$quality == "good", "while genuine breathing still grades good")
ok(q_real$band_ratio > 0.90, "and sits far above the threshold")

# --- A signal that is constant to machine precision: high-passing leaves
# floating-point error, and normalising divides by a scale of the same order,
# amplifying rounding noise into a detectable "waveform" with a negative
# amplitude. The cause is warned about and the symptom is flagged.
w_const <- NULL
res_const <- withCallingHandlers(
  suppressMessages(resp_analyse(resp_recording(rep(3.7, 2500), fs = 25),
                                target_fs = NULL, min_prominence = 0.3,
                                min_distance_s = 1, quality = FALSE)),
  warning = function(x) { w_const <<- c(w_const, conditionMessage(x))
                          invokeRestart("muffleWarning") })
ok(any(grepl("constant to within floating-point", w_const)),
   "a constant signal is warned about before it is processed")
ok(all(res_const$breaths$keep %in% FALSE),
   "no cycle from a constant signal survives QC")
ok(summarise_breaths(res_const$breaths)$n_breaths == 0,
   "and the summary counts zero breaths")

# A respiratory cycle cannot have a non-positive excursion.
ok("bad_amplitude" %in% names(res_const$breaths),
   "flag_breaths reports non-positive amplitude explicitly")
ok(all(flag_breaths(bt_reg)$bad_amplitude %in% FALSE),
   "and never fires on a genuine recording")

# --- Setting a threshold to NA is the documented way to disable it while
# calibrating on a new transducer. Comparing against a raw NA gave NA, and
# `if (NA)` is an error, so the documented workflow aborted.
tiny_sig <- synth_resp(rep(4, 60), duty = 0.4, amplitude = 1e-5, fs = 25,
                       noise = 3e-7)$signal
for (nm in c("iqr_unusable", "iqr_degraded", "freq_lo", "freq_hi",
             "flatline_pct", "saturation_pct", "na_degraded", "na_unusable",
             "band_ratio_min")) {
  th_one <- list(); th_one[[nm]] <- NA
  res_th <- tryCatch(suppressWarnings(suppressMessages(
    resp_quality(tiny_sig, fs = 25, trim_s = 20, thresholds = th_one))),
    error = function(e) NULL)
  ok(!is.null(res_th), sprintf("threshold %s can be disabled with NA", nm))
}
q_cal <- suppressWarnings(suppressMessages(resp_quality(
  tiny_sig, fs = 25, trim_s = 20,
  thresholds = list(iqr_unusable = NA, iqr_degraded = NA))))
ok(q_cal$quality == "good",
   "with the scale-dependent amplitude tests off, a microvolt-scale signal grades good")

# --- Transferability: the defaults must recover the truth on respiratory data
# that is not the dataset they were tuned on. The exception is documented:
# breathing faster than the detect band or the refractory period allows.
transfer <- list(
  list(lbl = "resting adult 15/min", dur = 4.0,  n = 60, duty = 0.40, fs = 25,   pol = "up"),
  list(lbl = "slow paced 6/min",     dur = 10.0, n = 30, duty = 0.50, fs = 25,   pol = "up"),
  list(lbl = "child 30/min",         dur = 2.0,  n = 90, duty = 0.40, fs = 50,   pol = "up"),
  list(lbl = "nasal thermistor",     dur = 4.0,  n = 60, duty = 0.40, fs = 25,   pol = "down"),
  list(lbl = "1000 Hz acquisition",  dur = 4.0,  n = 40, duty = 0.40, fs = 1000, pol = "up"),
  list(lbl = "128 Hz acquisition",   dur = 4.0,  n = 40, duty = 0.40, fs = 128,  pol = "up")
)
for (tc in transfer) {
  gt <- synth_resp(rep(tc$dur, tc$n), duty = tc$duty, fs = tc$fs,
                   noise = 0.03, seed = 7)
  sg <- if (tc$pol == "down") -gt$signal + 3 else gt$signal
  ot <- suppressWarnings(suppressMessages(
    resp_analyse(resp_recording(sg, fs = tc$fs), polarity = tc$pol, quality = FALSE)))
  kt <- ot$breaths[ot$breaths$keep %in% TRUE, ]
  ok(nrow(kt) > 0.8 * (tc$n - 1),
     sprintf("%s: most breaths detected (%d of %d)", tc$lbl, nrow(kt), tc$n - 1))
  near(stats::median(kt$duration), tc$dur, tc$dur * 0.05,
       sprintf("%s: duration recovered", tc$lbl))
  near(stats::median(kt$duty_cycle, na.rm = TRUE), tc$duty, 0.05,
       sprintf("%s: duty cycle recovered", tc$lbl))
}

cat("\n== assertions that must be able to fail ==\n")

# --- peak_prominence against an independent brute-force reference.
# The package's headline detection fix is the switch from bounding at the
# nearest higher *peak* to the nearest higher *sample*, and from taking the
# min of the two valley floors to the max. Neither the textbook example nor
# the two range properties can distinguish those, because in a symmetric case
# both bases are equal.
brute_prominence <- function(x, peaks) {
  n <- length(x)
  vapply(peaks, function(p) {
    l <- p; lmin <- x[p]
    while (l > 1L && x[l - 1L] <= x[p]) { l <- l - 1L; lmin <- min(lmin, x[l]) }
    r <- p; rmin <- x[p]
    while (r < n && x[r + 1L] <= x[p]) { r <- r + 1L; rmin <- min(rmin, x[r]) }
    x[p] - max(lmin, rmin)
  }, numeric(1))
}

# Asymmetric valleys: the two bases differ, so max-vs-min is visible.
asym_v <- c(0, 5, 2, 8, 0)
near(peak_prominence(asym_v, 2L), 3, 1e-12,
     "prominence uses the higher of the two valley floors, not the lower")
near(peak_prominence(asym_v, 2L), brute_prominence(asym_v, 2L), 1e-12,
     "and agrees with a brute-force walk")

set.seed(4242)
prom_mismatch <- 0L
for (i in 1:150) {
  xr <- switch(sample(3, 1),
    round(cumsum(stats::rnorm(300)), 1),
    round(sin(seq(0, 30, length.out = 300)) * 5 + stats::rnorm(300), 1),
    sample(0:6, 300, replace = TRUE))
  pk <- local_maxima(xr)
  if (!length(pk)) next
  a <- peak_prominence(xr, pk)
  b <- brute_prominence(xr, pk)
  if (max(abs(a - b)) > 1e-9) prom_mismatch <- prom_mismatch + 1L
}
ok(prom_mismatch == 0L,
   sprintf("prominence matches brute force on 150 varied signals (%d mismatches)",
           prom_mismatch))

# --- the refractory period must actually remove something.
close_pk <- rep(c(rep(0, 5), 1, rep(0, 5)), 40)      # a peak every 11 samples
n_far  <- length(find_extrema_prominence(close_pk, fs = 25,
                                         min_prominence = 0.5,
                                         min_distance_s = 0.04)$peaks)
n_near <- length(find_extrema_prominence(close_pk, fs = 25,
                                         min_prominence = 0.5,
                                         min_distance_s = 1.0)$peaks)
ok(n_far > n_near,
   sprintf("min_distance_s removes closely spaced peaks (%d -> %d)", n_far, n_near))

# The boundary, which is where an inclusive/exclusive slip hides. Peaks spaced
# exactly min_dist apart must all survive; turning `>=` into `>` halves them.
bnd_idx  <- local_maxima(close_pk)
bnd_prom <- peak_prominence(close_pk, bnd_idx)
ok(length(enforce_min_distance(bnd_idx, bnd_prom, 11L)) == length(bnd_idx),
   "peaks spaced exactly min_dist apart are all kept")
ok(length(enforce_min_distance(bnd_idx, bnd_prom, 12L)) < length(bnd_idx),
   "and one sample closer than that starts removing them")

# --- enforce_alternation must be doing work, and the default rule must matter.
# The taller peak is the FURTHER one from the following trough, so the two
# rules disagree: "extreme" keeps index 2, "nearest" keeps index 4.
alt_sig <- c(0, 9, 1, 3, 0)
alt_ex  <- enforce_alternation(peaks = c(2L, 4L), troughs = 5L,
                               values = alt_sig, rule = "extreme")
ok(identical(as.integer(alt_ex$peaks), 2L),
   "the extreme rule keeps the highest peak of a run")
alt_ne  <- enforce_alternation(peaks = c(2L, 4L), troughs = 5L,
                               values = alt_sig, rule = "nearest")
ok(identical(as.integer(alt_ne$peaks), 4L),
   "the nearest rule keeps the one closest to the following trough")
ok(!identical(as.integer(alt_ex$peaks), as.integer(alt_ne$peaks)),
   "so the two rules genuinely differ and the default is a real choice")

# Whether resp_detect is WIRED UP to that function is a separate question, and
# not one a signal-based assertion can settle: prominence detection preserves
# alternation on its own for every realistic waveform tried, so skipping the
# call entirely leaves clean detections unchanged. Checking the call directly
# is the only test that fails when the wiring is removed.
# The substitution has to happen in whatever environment resp_detect resolves
# names in: the global environment when these files are sourced, the package
# namespace when the tests run against an installed copy under R CMD check.
# Overwriting a global of the same name would not be seen in the second case.
alt_env  <- environment(resp_detect)
alt_orig <- get("enforce_alternation", envir = alt_env)
alt_lock <- bindingIsLocked("enforce_alternation", alt_env)

spy_on_alternation <- function(...) {
  if (alt_lock) unlockBinding("enforce_alternation", alt_env)
  hit <- FALSE
  assign("enforce_alternation",
         function(...) { hit <<- TRUE; alt_orig(...) }, envir = alt_env)
  on.exit({
    assign("enforce_alternation", alt_orig, envir = alt_env)
    if (alt_lock) lockBinding("enforce_alternation", alt_env)
  }, add = TRUE)
  invisible(resp_detect(...))
  hit
}

ok(spy_on_alternation(pp$recording, min_prominence = 0.5, min_distance_s = 1.5),
   "resp_detect calls enforce_alternation on its default path")
ok(!spy_on_alternation(pp$recording, min_prominence = 0.5, min_distance_s = 1.5,
                       alternation_rule = "none"),
   "and skips it only when explicitly asked to")
ok(identical(formals(enforce_alternation)$rule[[2]], "extreme"),
   "the default rule is \"extreme\"")

# --- zero-crossing labels must come from half-cycle parity, not from the sign
# of the value. Asserting that no trough has a positive value is satisfied by
# construction if labels are assigned by sign.
# The discriminating case is a positive half-cycle whose maximum is exactly
# zero: parity says peak, the sign of the value says trough. Everywhere else
# the two agree, which is why an assertion phrased as "no trough has a
# positive value" cannot detect the difference.
zc_sig <- c(-1, -2, -1, 0, -1, -2, -1, 1, 3, 1, -1)
zc_lab <- find_extrema_zerocross(zc_sig, centre = "none", amplitude_min = 0)
ok(identical(as.integer(zc_lab$peaks), c(4L, 9L)),
   "a half-cycle peaking at exactly zero is still labelled a peak")
ok(identical(as.integer(zc_lab$troughs), 6L),
   "and the trough is the minimum of its own half-cycle")
ok(zc_sig[zc_lab$peaks[1]] == 0,
   "confirming the labelling came from parity, not from the sign of the value")

# --- coverage_frac must be measured, not stubbed at 1.
cov_bt  <- flag_breaths(breath_table(det, pp$recording))
cov_eps <- resp_epochs(onset = c(0, 30), duration = c(6, 20))
cov_ef  <- epoch_features(cov_bt, cov_eps)
ok(cov_ef$coverage_frac[1] < 0.95,
   sprintf("a 6 s window holding one 4 s breath reports partial coverage (%.3f)",
           cov_ef$coverage_frac[1]))
ok(cov_ef$coverage_frac[2] > cov_ef$coverage_frac[1],
   "and a longer window covers proportionally more")

# --- flag_breaths must reject something, not pass everything.
# Built from the ramped signal: the duration-outlier test is MAD-based, so it
# is inert on a table whose durations are all identical.
flg <- breath_table(det_r, pp_r$recording)
flg$amplitude[1] <- -1                                     # impossible
flg$amplitude[2] <- 0.001 * stats::median(flg$amplitude)   # far too small
flg$duration[3]  <- 60                                     # wild outlier
flg <- flag_breaths(flg)
ok(!flg$keep[1] && flg$bad_amplitude[1],  "a non-positive excursion is rejected")
ok(!flg$keep[2] && flg$low_amplitude[2],  "a vanishing excursion is rejected")
ok(!flg$keep[3] && flg$duration_outlier[3], "a wildly long cycle is rejected")
ok(mean(flg$keep[-(1:3)]) > 0.9, "while genuine cycles are kept")

# `implausible` comes from breath_table's own duration bounds.
imp_bt <- breath_table(det, pp$recording, max_duration_s = 2)
ok(all(imp_bt$implausible), "breath_table flags cycles outside its duration bounds")
ok(!any(breath_table(det, pp$recording)$implausible),
   "and flags none at the default bounds")

# --- resp_epochs(lag) must shift the windows. The quick-start promotes
# lag = 0.2 for belt latency; a version that ignored it would look identical.
ep0 <- resp_epochs(onset = c(10, 50), duration = 20, lag = 0)
ep2 <- resp_epochs(onset = c(10, 50), duration = 20, lag = 0.2)
near(ep2$start - ep0$start, c(0.2, 0.2), 1e-12, "lag shifts every window start")
near(ep2$end   - ep0$end,   c(0.2, 0.2), 1e-12, "and every window end")

# --- dom_lo must keep the drift shoulder out of the dominant-frequency search.
drift_t   <- seq(0, 600, by = 1 / 25)
drift_sig <- sin(2 * pi * 0.25 * drift_t) + 3 * sin(2 * pi * 0.06 * drift_t)
q_hi <- suppressWarnings(suppressMessages(
  resp_quality(drift_sig, fs = 25, trim_s = 0, dom_lo = 0.10)))
q_lo <- suppressWarnings(suppressMessages(
  resp_quality(drift_sig, fs = 25, trim_s = 0, dom_lo = 0.05)))
# Tolerance well inside one FFT bin. At segment_s = 120 and fs = 25 the bin
# width is 0.008333 Hz and 0.25 falls exactly on a bin centre, so anything at
# or above the bin width would admit an axis shifted by a whole bin -- which
# is precisely how an off-by-one in `(seq_len(nf) - 1L)` shows up.
near(q_hi$dominant_freq_hz, 0.25, 0.004,
     "with dom_lo = 0.10 the dominant frequency is the breathing rate, to within half a bin")
ok(q_lo$dominant_freq_hz < 0.10,
   sprintf("with dom_lo = 0.05 the drift shoulder wins instead (%.3f Hz)",
           q_lo$dominant_freq_hz))
q_seg_dom <- suppressWarnings(suppressMessages(
  resp_quality(drift_sig, fs = 25, trim_s = 0, by_segment = TRUE,
               segment_s = 120)))
ok(all(q_seg_dom$segments$dominant_freq_hz > 0.10, na.rm = TRUE),
   "and dom_lo reaches the per-segment path too")

# --- the despike default window must be the tested one.
ok(isTRUE(all.equal(formals(resp_despike)$window_s, 0.3)),
   "resp_despike defaults to the 0.3 s window that was calibrated")

# The default is bounded from below by the widest artefact a median over the
# window can still reject, and from above by the breath's own curvature.
spike3 <- synth_resp(rep(4, 60), duty = 0.4, fs = 25, noise = 0.02)$signal
clean3 <- spike3
spike3[1500:1502] <- spike3[1500:1502] + 25
ok(all(abs(resp_despike(spike3, fs = 25)[1500:1502] - clean3[1500:1502]) < 1),
   "at the default window a 3-sample artefact is removed")
ok(!all(abs(resp_despike(spike3, fs = 25, window_s = 0.2)[1500:1502] -
              clean3[1500:1502]) < 1),
   "a narrower window misses it, which is what sets the lower bound")

curvy <- synth_resp(rep(4, 60), duty = 0.25, fs = 25, noise = 0)$signal
ok(100 * mean(resp_despike(curvy, fs = 25) != curvy) < 0.5,
   "at the default window a clean signal is left alone")

# The upper bound on window_s used to be real: under the lag-1 scale the
# residual grew with the window while the scale it was compared against did
# not, so a wide window flagged the breath's own curvature (7.0% of a clean
# 5 s-breath trace at window_s = 2). Measuring the scale at a lag of half the
# window makes the two grow together, so the sensitivity to window_s is gone
# on the upper side. This asserts the property the lag bought; revert the
# scale to diff(v) and it fails.
wide <- vapply(c(0.3, 0.5, 1, 2, 4),
               function(w) 100 * mean(resp_despike(curvy, fs = 25, window_s = w) != curvy),
               numeric(1))
ok(all(wide < 0.5),
   sprintf("a clean signal survives every window from 0.3 s to 4 s (worst %.3f%%)",
           max(wide)))

# The residual from a running median is exactly zero wherever the signal is
# locally monotone, so scaling against mad(resid) collapses the threshold.
# This configuration is where the two scale choices diverge hardest: 0.00%
# flagged against mad(diff), 8.20% against mad(resid), on identical clean data.
scale_sig <- synth_resp(rep(4, 60), duty = 0.40, fs = 25, noise = 0.02)$signal
ok(100 * mean(resp_despike(scale_sig, fs = 25) != scale_sig) < 1,
   "a clean signal at noise 0.02 is left alone (the case a degenerate scale ruins)")

# `threshold` must actually control the flag rate, monotonically. Against a
# collapsed scale it does not: the same sweep runs 34% -> 24% -> 8% -> 1%,
# i.e. the argument is tuning against a quantity pinned near zero.
spiky_sig <- scale_sig; spiky_sig[c(400, 900, 1400)] <- spiky_sig[c(400, 900, 1400)] + 20
rates <- vapply(c(3, 5, 10, 20),
                function(th) mean(resp_despike(spiky_sig, fs = 25, threshold = th) != spiky_sig),
                numeric(1))
ok(all(diff(rates) <= 0), "raising `threshold` never increases the flagged fraction")
ok(rates[1] < 0.02,
   sprintf("and even the most aggressive threshold stays selective (%.3f%%)", 100 * rates[1]))

# --- amplitude is the mean of the two limbs, which differ under drift.
amp_bt <- breath_table(det_r, pp_r$recording)
amp_ok <- !is.na(amp_bt$amp_inhale) & !is.na(amp_bt$amp_exhale)
ok(any(abs(amp_bt$amp_inhale[amp_ok] - amp_bt$amp_exhale[amp_ok]) > 1e-6),
   "the two limbs of a cycle genuinely differ")
near(amp_bt$amplitude[amp_ok],
     (amp_bt$amp_inhale[amp_ok] + amp_bt$amp_exhale[amp_ok]) / 2, 1e-9,
     "and amplitude is their mean")

# --- robust normalisation must be robust: a few large artefacts must not
# collapse the scale the way a standard deviation does.
rob_sig <- synth_resp(rep(4, 60), duty = 0.4, fs = 25, noise = 0.02)$signal
rob_sig[c(200, 700, 1400)] <- 100
sd_scaled  <- resp_normalise(rob_sig, method = "z",      fs = 25)
mad_scaled <- resp_normalise(rob_sig, method = "robust", fs = 25)
ok(stats::IQR(mad_scaled) > 3 * stats::IQR(sd_scaled),
   sprintf("robust scaling survives three large artefacts (IQR %.3f vs %.3f)",
           stats::IQR(mad_scaled), stats::IQR(sd_scaled)))

cat("\n== regression: second review pass ==\n")

# --- a detection measured against a recording at a different sampling rate
# scaled every duration by the ratio, silently. The range check could not
# catch it because the mismatched recording is longer, not shorter.
r250 <- resp_recording(synth_resp(rep(4, 20), duty = 0.4, fs = 250)$signal, fs = 250)
r50  <- suppressMessages(resp_downsample(r250, target_fs = 50))
d50  <- resp_detect(resp_normalise(resp_filter(r50, low = 0.05, high = 2)),
                    min_prominence = 0.4, min_distance_s = 1.5)
errors_with(breath_table(d50, r250), "must agree",
            "measuring a detection against a differently-sampled recording is refused")
ok(nrow(breath_table(d50, r50)) > 0, "while the matching recording works")
errors_with(as_resp_recording(r250, fs = 1000), "must agree",
            "as_resp_recording refuses a contradictory fs")
ok(identical(as_resp_recording(r250, fs = 250), r250),
   "and accepts an agreeing one")

# --- a factor time column became level codes: 120.5, 300.25, 600 -> 1, 2, 3.
ev_fac <- data.frame(time = factor(c("120.5", "300.25", "600")), label = letters[1:3])
rec_fac <- resp_recording(stats::rnorm(20000), fs = 25, events = ev_fac)
near(rec_fac$events$time, c(120.5, 300.25, 600), 1e-9,
     "a factor event-time column keeps its real values")
errors_with(resp_recording(stats::rnorm(100), fs = 25,
                           events = data.frame(time = c("a", "b"))),
            "could not be converted", "and a genuinely non-numeric one is refused")

# --- an NA event time produced an all-NA row that survived every later slice.
rec_na_ev <- resp_recording(stats::rnorm(500), fs = 25,
                            events = data.frame(time = c(1, NA, 5),
                                                label = c("keep", "lost", "keep2"),
                                                stringsAsFactors = FALSE))
sl_na <- resp_slice(rec_na_ev, 0, 19)
ok(nrow(sl_na$events) == 2 && !anyNA(sl_na$events$time),
   "slicing drops an NA-time event instead of blanking its whole row")
ok(identical(sl_na$events$label, c("keep", "keep2")), "and keeps the others intact")

# --- unknown fields were dropped on load rather than kept in meta.
lst_extra <- list(signal = stats::rnorm(500), fs = 25, schema = 1L,
                  side = "R", abcode = 7L)
rec_extra <- as_resp_recording(lst_extra)
ok(identical(rec_extra$meta$side, "R") && identical(rec_extra$meta$abcode, 7L),
   "unrecognised list fields are preserved under meta")

# --- resp_rds_is_legacy used obj$schema, which partial-matches.
ok(resp_rds_is_legacy(list(signal = 1:10, fs = 25, schema_version = "2021")),
   "a legacy file with a schema_version field is still recognised as legacy")
ok(!resp_rds_is_legacy(data.frame(signal = 1:10, fs = 25)),
   "and a data frame is not mistaken for one")

# --- the legacy rate correction trusted target_fs over the file's own fs.
leg_50 <- list(signal = stats::rnorm(5000), fs = 50, native_fs = 1000)
conv_50 <- suppressWarnings(suppressMessages(resp_read_legacy_rds(leg_50)))
near(conv_50$fs, 1000 / legacy_decimation_factor(20), 1e-9,
     "a file stored at 50 Hz is corrected from its own rate, not from target_fs")
ok(abs(conv_50$fs - 25.641) > 1,
   "and is not dragged to the 25 Hz assumption")

# --- exported detectors crashed on NA with untraceable messages.
errors_with(peak_prominence(c(0, 1, NA, 1, 0), 2L), "non-finite",
            "peak_prominence names the real problem on NA input")
ok(is.integer(refine_extrema(c(1, 2, NA, 4, 3), 3L, TRUE, 2, 1)),
   "refine_extrema survives an NA in the search window")

# --- enforce_alternation deleted a whole run when its values were all NA.
v_na <- c(0, 1, 0, -1, 0, 1, 0, -1, 0, 1, 0, -1, 0)
v_na[c(6, 10)] <- NA
alt_na <- enforce_alternation(peaks = c(2L, 6L, 10L), troughs = c(4L, 12L),
                              values = v_na)
merged_na <- c(rep(1L, length(alt_na$peaks)), rep(0L, length(alt_na$troughs)))[
  order(c(alt_na$peaks, alt_na$troughs))]
ok(length(alt_na$peaks) == 2L, "a run with all-NA values keeps one event, not none")
ok(!any(diff(merged_na) == 0), "and alternation still holds")

# --- empty and non-empty breath tables must be bindable across participants.
bt_full  <- breath_table(det, pp$recording)
bt_empty <- breath_table(list(peaks = integer(0), troughs = integer(0), fs = 25),
                         pp$recording)
ok(identical(names(bt_full), names(bt_empty)),
   "an empty breath table has the same columns as a full one")
ok(identical(sort(names(attributes(bt_full))), sort(names(attributes(bt_empty)))),
   "and the same attributes")
ok(nrow(rbind(bt_full, bt_empty)) == nrow(bt_full),
   "so the two bind without error")

# --- resp_downsample rerouted away from an exact factor to dodge a stage it
# already considered safe, making the achieved rate worse every time.
ds_850 <- suppressMessages(resp_downsample(resp_recording(stats::rnorm(60000), fs = 850),
                                           target_fs = 25))
near(ds_850$fs, 25, 1e-9,
     "850 Hz reaches exactly 25 Hz via q = 34 rather than being rerouted")

# --- the length guard checked the largest stage, not the whole factor, so a
# later stage could starve and return finite-but-wrong output.
errors_with(resp_decimate(stats::rnorm(400), q = 169, fs = 5000), "too few",
            "a signal too short for the whole decimation is refused")
ok(length(resp_decimate(stats::rnorm(30 * 169 + 10), q = 169, fs = 5000)$signal) > 0,
   "while a long enough one succeeds")

# --- resp_quality died on wholly missing input instead of grading it.
q_allna <- suppressWarnings(suppressMessages(resp_quality(rep(NA_real_, 2000), fs = 25)))
ok(identical(q_allna$quality, "unusable"),
   "a wholly missing recording is graded unusable rather than erroring")
q_norm <- suppressWarnings(suppressMessages(
  resp_quality(synth_resp(rep(4, 60), fs = 25, noise = 0.02)$signal,
               fs = 25, trim_s = 20)))
ok(identical(names(q_allna), names(q_norm)),
   "and returns the same fields as a normal grading, so a cohort binds")
errors_with(resp_quality(stats::rnorm(5000), fs = 25, dom_lo = 0.9, resp_band = 0.6),
            "must be below", "an empty dominant-frequency window is refused")

# --- an unusable verdict reported only the test that decided it.
multi <- c(rep(0, 7500), rep(1, 7500)); multi[1:3000] <- NA
q_multi <- suppressWarnings(suppressMessages(
  resp_quality(resp_recording(multi, fs = 25), trim_s = 0)))
ok(identical(q_multi$quality, "unusable"), "a multiply-failing recording is unusable")
ok(length(q_multi$flags) >= 3,
   sprintf("and every failing test is reported, not just the deciding one (%d flags)",
           length(q_multi$flags)))

# --- resp_analyse duplicated the filter when both bands were identical.
same <- suppressMessages(resp_analyse(resp_recording(long$signal, fs = 25),
                                      target_fs = NULL,
                                      detect_band = c(0.05, 1),
                                      measure_band = c(0.05, 1), quality = FALSE))
ok(identical(same$recording$signal, same$measure$signal),
   "identical bands reuse one filtered copy")
ok(is.null(same$stages$measure), "and no redundant measure stage is retained")

# --- plotting must survive an all-NA panel and accept graphical parameters.
png(file.path(tempdir(), "respkit_plotchk.png"), 800, 600)
nan_bt <- bt_full; nan_bt$baseline <- NA_real_
plot_ok <- tryCatch({ plot_breaths(nan_bt); TRUE }, error = function(e) FALSE)
plot_ok2 <- tryCatch({ plot_resp(pp$recording, col = "red", lwd = 2); TRUE },
                     error = function(e) FALSE)
dev.off()
ok(plot_ok, "plot_breaths draws an all-NA panel instead of erroring")
ok(plot_ok2, "plot_resp accepts col and lwd without an argument clash")
errors_with(plot_resp(pp$recording, epochs = data.frame(onset = 1, offset = 2)),
            "must have `start` and `end`", "and rejects a malformed epochs table")

cat("\n== regression: third review pass ==\n")

# --- coverage_frac summed whole cycle durations, so a breath assigned by its
# opening trough credited the window with time lying outside it. Over 10 s
# windows on 4 s breaths that overstated coverage by 0.095 on average and
# reported a full 1.0 for 98 of 200 random offsets.
mk_bt_cov <- function(starts, durs) {
  n <- length(starts)
  data.frame(breath = seq_len(n), i_start = seq_len(n), i_peak = seq_len(n),
    i_end = seq_len(n), t_start = starts, t_peak = starts + durs / 2,
    t_end = starts + durs, duration = durs, inhale_dur = durs / 2,
    exhale_dur = durs / 2, duty_cycle = rep(0.5, n), ie_ratio = rep(1, n),
    rate_bpm = 60 / durs, amp_inhale = rep(1, n), amp_exhale = rep(1, n),
    amplitude = rep(1, n), baseline = rep(0, n), rvt = 1 / durs,
    flow_in = rep(1, n), flow_out = rep(1, n), has_peak = rep(TRUE, n),
    implausible = rep(FALSE, n))
}
cov_edge <- epoch_features(mk_bt_cov(c(-4.1, 5.9), c(4, 5)),
                           resp_epochs(onset = 0, offset = 6))
near(cov_edge$coverage_frac, 0.1 / 6, 1e-9,
     "a cycle starting 0.1 s before the window closes contributes only that 0.1 s")
ok(cov_edge$n_breaths_partial >= 1, "and is still counted as a partial cycle")

cov_full <- epoch_features(mk_bt_cov(seq(0, 12, by = 4), rep(4, 4)),
                           resp_epochs(onset = 0, offset = 16))
near(cov_full$coverage_frac, 1, 1e-9, "four abutting 4 s cycles fill a 16 s window")

# --- find_extrema_zerocross(centre = "mean") was only ever exercised on an
# already-centred signal, so removing the centring changed nothing.
off_sig <- synth_resp(rep(4, 30), duty = 0.4, fs = 25, noise = 0.01)$signal + 5
zc_mean <- suppressWarnings(find_extrema_zerocross(off_sig, centre = "mean"))
zc_none <- suppressWarnings(find_extrema_zerocross(off_sig, centre = "none"))
ok(abs(length(zc_mean$peaks) - 29) <= 2,
   sprintf("centre='mean' recovers the breaths of an offset signal (%d peaks)",
           length(zc_mean$peaks)))
ok(length(zc_none$peaks) == 0,
   "while centre='none' finds none at all, so the centring is doing the work")

# --- resp_psd's Hann window and 50% overlap were both unprotected.
# The tone must sit BETWEEN FFT bins: on a bin centre a rectangular window
# leaks nothing either, and the test cannot distinguish the two.
tone_t  <- seq(0, 600, by = 1 / 25)
bin_hz  <- 1 / 60
tone_hz <- 15.5 * bin_hz              # deliberately half a bin off centre
tone    <- sin(2 * pi * tone_hz * tone_t)
psd_t   <- resp_psd(tone, fs = 25, segment_s = 60)
leak    <- max(psd_t$power[abs(psd_t$freq - tone_hz) > 0.05]) / max(psd_t$power)
# Measured at this half-bin offset: Hann leaks 1.2e-03, a rectangular window
# 2.1e-02, a factor of 17. The threshold sits between them.
ok(leak < 5e-3,
   sprintf("windowing holds off-peak leakage to %.2e of the peak", leak))
ok(nrow(resp_psd(tone, fs = 25, segment_s = 60, overlap = 0.5)) ==
     nrow(resp_psd(tone, fs = 25, segment_s = 60, overlap = 0)),
   "overlap changes averaging, not resolution")

# --- na_degraded was never exercised; only na_unusable was.
na5 <- synth_resp(rep(4, 200), duty = 0.4, fs = 25, noise = 0.02)$signal
na5[seq(1, length(na5), by = 20)] <- NA           # 5% missing, scattered
q_na5 <- suppressWarnings(suppressMessages(resp_quality(na5, fs = 25, trim_s = 20)))
ok(q_na5$quality == "degraded",
   sprintf("a 5%% missing recording is degraded (na_pct %.1f)", q_na5$na_pct))
q_na5_off <- suppressWarnings(suppressMessages(
  resp_quality(na5, fs = 25, trim_s = 20, thresholds = list(na_degraded = NA))))
ok(q_na5_off$quality == "good", "and good once na_degraded is disabled")

# --- the three epoch rules were never distinguished from one another.
rule_bt  <- mk_bt_cov(c(-1, 2, 6, 10, 19), rep(4, 5))
rule_eps <- resp_epochs(onset = 0, offset = 20)
n_start  <- sum(!is.na(epoch_breaths(rule_bt, rule_eps, rule = "start")$epoch))
n_cont   <- sum(!is.na(epoch_breaths(rule_bt, rule_eps, rule = "contained")$epoch))
n_over   <- nrow(epoch_breaths(rule_bt, rule_eps, rule = "overlap"))
ok(n_cont < n_start && n_start < n_over,
   sprintf("contained (%d) < start (%d) < overlap (%d)", n_cont, n_start, n_over))
ok(sum(!is.na(epoch_breaths(rule_bt, rule_eps, rule = "start", pad_s = 2)$epoch)) > n_start,
   "and pad_s admits breaths just outside the window")

# --- rmssd and cv were both replaceable by sd().
v_alt <- c(1, 3, 1, 3, 1, 3, 1, 3)      # zero drift, large successive differences
v_ramp <- seq(1, 3, length.out = 8)     # same spread, minimal successive differences
rmssd_ratio <- resp_variability(v_alt)$rmssd / resp_variability(v_ramp)$rmssd
sd_ratio    <- resp_variability(v_alt)$sd    / resp_variability(v_ramp)$sd
ok(rmssd_ratio > 3 * sd_ratio,
   sprintf(paste0("rmssd separates successive-difference variability from spread ",
                  "(rmssd ratio %.1f vs sd ratio %.1f)"), rmssd_ratio, sd_ratio))
near(resp_variability(c(10, 20, 30))$cv, stats::sd(c(10, 20, 30)) / 20, 1e-12,
     "cv is sd over the mean, not sd")

# --- several documented arguments were inert as far as the suite could tell.
# Enough points that the 0.5/99.5 percentiles fall well inside the outliers,
# otherwise the clamp bounds land on the extremes and clipping is a no-op.
set.seed(21)
clip_in  <- c(stats::rnorm(1000), 500, -500)
clip_out <- resp_clip(clip_in, fs = 25)
clip_q   <- stats::quantile(clip_in, c(0.005, 0.995), names = FALSE)
# Against the expected result, not merely "smaller than the input". Swapping
# pmin and pmax collapses the output to a single constant, which is smaller
# than the input's 500 and so passed a magnitude test while destroying the
# signal entirely.
near(clip_out, pmin(pmax(clip_in, clip_q[1]), clip_q[2]), 1e-12,
     "resp_clip clamps to the quantile bounds")
ok(stats::sd(clip_out) > 0.5 * stats::sd(clip_in[abs(clip_in) < 10]),
   "and preserves the variation inside them rather than flattening the signal")
ok(max(clip_out) < 10 && min(clip_out) > -10, "with the outliers actually pulled in")
drifty_d <- synth_resp(rep(4, 40), duty = 0.4, fs = 25, noise = 0.01, drift = 8)$signal
ok(diff(range(resp_detrend(drifty_d, method = "median", window_s = 20, fs = 25))) <
     0.5 * diff(range(drifty_d)),
   "resp_detrend(method='median') removes drift")
stuck <- c(rep(1 + 1e-9 * seq_len(500), 1), stats::rnorm(500))
ok(resp_flatline(round(stuck, 9), fs = 25, digits = 3)$pct >
     resp_flatline(round(stuck, 9), fs = 25, digits = NULL)$pct,
   "resp_flatline(digits) controls how much dither counts as flat")
ramp_sat <- seq(0, 1, length.out = 1000)
ok(resp_saturation(ramp_sat, tol = 0.1)$pct_saturated >
     5 * resp_saturation(ramp_sat, tol = 0.001)$pct_saturated,
   "resp_saturation(tol) widens the rail band")
bad_head <- synth_resp(rep(4, 200), duty = 0.4, fs = 25, noise = 0.02)$signal
bad_head[1:3000] <- 0
ok(suppressWarnings(suppressMessages(
     resp_quality(bad_head, fs = 25, trim_s = 0)))$quality !=
   suppressWarnings(suppressMessages(
     resp_quality(bad_head, fs = 25, trim_s = 130)))$quality,
   "resp_quality(trim_s) changes the verdict when the bad stretch is at an end")

# --- resp_analyse arguments the suite could not see.
an_500 <- resp_recording(synth_resp(rep(4, 40), duty = 0.4, fs = 500,
                                    noise = 0.02)$signal, fs = 500)
ok(suppressMessages(resp_analyse(an_500, target_fs = 25, quality = FALSE))$measure$fs < 30,
   "resp_analyse(target_fs) actually decimates")
ok(abs(suppressMessages(resp_analyse(an_500, target_fs = NULL,
                                     quality = FALSE))$measure$fs - 500) < 1e-9,
   "and leaves the rate alone when told to")
spk_rec <- resp_recording({ v <- synth_resp(rep(4, 40), duty = 0.4, fs = 25,
                                            noise = 0.02)$signal
                            v[500] <- v[500] + 30; v }, fs = 25)
an_dsp <- suppressMessages(resp_analyse(spk_rec, target_fs = NULL, despike = TRUE,
                                        quality = FALSE))$stages$despiked
ok(!is.null(an_dsp) && !identical(an_dsp$signal, spk_rec$signal),
   "resp_analyse(despike=TRUE) produces a despiked stage that differs from the input")
ok(!is.null(an_dsp) && abs(an_dsp$signal[500]) < abs(spk_rec$signal[500]) / 5,
   "and the spike itself is gone")
ok(is.null(suppressMessages(resp_analyse(spk_rec, target_fs = NULL, despike = FALSE,
                                         quality = FALSE))$stages$despiked),
   "and despike=FALSE skips the stage entirely")

# --- min_prominence had no test pinning its effect on the count.
prom_sig <- resp_normalise(resp_filter(
  synth_resp(rep(4, 60), duty = 0.4, fs = 25, noise = 0.15)$signal,
  low = 0.05, high = 3, fs = 25), fs = 25)
n_lo <- length(find_extrema_prominence(prom_sig, fs = 25, min_prominence = 0.05,
                                       min_distance_s = 0.2)$peaks)
n_hi <- length(find_extrema_prominence(prom_sig, fs = 25, min_prominence = 1.0,
                                       min_distance_s = 0.2)$peaks)
ok(n_lo > n_hi, sprintf("min_prominence controls how many peaks survive (%d -> %d)",
                        n_lo, n_hi))

# --- summarise_breaths(prefix) and baseline_drift were inert.
ok(all(grepl("^w1_", names(summarise_breaths(bt_reg, prefix = "w1_")))),
   "summarise_breaths(prefix) renames every column")
drift_bt <- mk_bt_cov(seq(0, 76, by = 4), rep(4, 20))
drift_bt$baseline <- seq(0, 19)          # a clean upward drift
ok(summarise_breaths(drift_bt)$baseline_drift > 0.2,
   "baseline_drift detects a rising end-expiratory level")
flat_bt <- drift_bt; flat_bt$baseline <- rep(3, 20)
near(summarise_breaths(flat_bt)$baseline_drift, 0, 1e-9, "and is zero when it is level")

# --- epoch_features(min_breaths) was inert.
# n_breaths is reported either way; what min_breaths suppresses are the
# feature columns, so that is what has to be checked.
mb_hi <- epoch_features(bt_reg, resp_epochs(onset = 0, duration = 8), min_breaths = 50L)
mb_lo <- epoch_features(bt_reg, resp_epochs(onset = 0, duration = 8), min_breaths = 1L)
ok(is.na(mb_hi$duration_mean) && is.finite(mb_lo$duration_mean),
   "min_breaths suppresses the summary when a window holds too few cycles")
ok(mb_hi$n_breaths == mb_lo$n_breaths,
   "while still reporting how many cycles there were")

# --- resp_rate_series(method="linear") must carry the ends forward.
lin_rs <- resp_rate_series(bt_reg, fs_out = 2, method = "linear",
                           from = min(bt_reg$t_start) - 5,
                           to   = max(bt_reg$t_end) + 5)
ok(all(is.finite(lin_rs$rate_bpm)),
   "linear interpolation extends to the ends rather than leaving NAs")

cat("\n== trigger edge detection ==\n")

# These reproduce, as short synthetic vectors, the patterns actually observed
# in the BIOPAC recordings this was built against, so the suite exercises the
# logic without needing a .acq file or a Python toolchain.

# The real hardware idles at a NON-ZERO code and steps straight to the session
# start. Requiring a return to zero first misses it: on one recording the line
# holds code 3 for 205 s and then goes to code 1, which is the session onset.
idle_nonzero <- c(rep(3, 50), rep(1, 20), rep(0, 10), rep(16, 20))
te <- trigger_edges(idle_nonzero)
ok(identical(te, c(1L, 51L, 81L)),
   "a code-to-code transition is an edge, so a line idling non-zero still yields its trigger")
ok(51L %in% te, "specifically, the 3 -> 1 step is found")

# Codes at or above trigger_max are not triggers. Most channels in the dataset
# sit at 240-243 for their whole duration.
ok(length(trigger_edges(rep(c(240, 241, 242, 243), 25))) == 0L,
   "a channel idling at 240-243 yields no triggers")

# A denormal float is not a trigger code.
ok(length(trigger_edges(c(rep(0, 10), rep(2.05e-289, 10), rep(0, 10)))) == 0L,
   "a denormal float in the trigger channel is not read as a code")

# A lone NA must not swallow the trigger beside it.
na_trig <- c(rep(0, 10), NA, rep(0, 5), rep(5, 10), rep(0, 5))
# identical(), not %in%: leaving the NA in place makes rle() give it its own
# run, the comparison returns NA, and an NA index is carried into the result
# alongside the real one -- so a membership test would still pass.
ok(identical(trigger_edges(na_trig), 17L),
   "a non-finite sample neither hides the real trigger nor leaks an NA index")

# Short settle runs are kept by default and removable on request.
settle <- c(rep(0, 20), rep(3, 2), rep(4, 2), rep(1, 200), rep(0, 20))
ok(length(trigger_edges(settle, fs = 2000)) == 3L,
   "settle artefacts are reported by default")
ok(identical(trigger_edges(settle, min_pulse_s = 0.01, fs = 2000), 25L),
   "and min_pulse_s removes them while keeping the real pulse")

# Debounce measures against the last KEPT edge, so a drizzle is thinned rather
# than annihilated.
dz <- c(0, 5, 0, 5, 0, 5, 0, 5, 0)          # edges at 2,4,6,8
ok(sum(debounce_edges(c(2L, 4L, 6L, 8L), debounce_s = 3, fs = 1)) == 2L,
   "debounce thins a chain of close edges rather than dropping all but the first")
ok(all(debounce_edges(c(2L, 40L, 80L), debounce_s = 3, fs = 1)),
   "and leaves well-separated edges alone")

cat("\n== regression: fourth review pass ==\n")

# --- debouncing kept the FIRST edge of a cluster. A parallel port settles
# through intermediate values BEFORE reaching the code the experiment sent,
# so the first edge is systematically the artefact. On the settle vector
# below it kept the 1 ms code-3 artefact and discarded the 100 ms code-1
# pulse -- wrong code, wrong time. Across 30 archive recordings the old rule
# dropped 346 of 5311 edges, 197 of which were longer than what suppressed
# them.
set_v <- c(rep(0, 20), rep(3, 2), rep(4, 2), rep(1, 200), rep(0, 20))
set_r <- trigger_runs(set_v, fs = 2000)
ok(nrow(set_r) == 3L && identical(set_r$code, c(3, 4, 1)),
   "all three runs of the settle cluster are detected")
kept <- set_r$index[debounce_edges(set_r$index, debounce_s = 1, fs = 2000,
                                   weight = set_r$length)]
ok(identical(as.integer(set_v[kept]), 1L),
   "debouncing keeps the longest pulse in a cluster, not the first")
ok(all(debounce_edges(set_r$index, debounce_s = 0, fs = 2000,
                      weight = set_r$length)),
   "and debounce_s = 0 keeps everything")
ok(isTRUE(all.equal(formals(resp_read_acq)$debounce_s, 0)),
   "resp_read_acq debounces off by default rather than inside the real event gap")

# --- a non-finite sample INSIDE a pulse split the run in two: a duplicate
# edge, and with min_pulse_s set the true onset was deleted and a later index
# reported in its place.
pulse    <- c(rep(0, 10), rep(1, 20), rep(0, 10))
pulse_na <- pulse; pulse_na[20] <- NA
ok(identical(trigger_edges(pulse_na, fs = 100), 11L),
   "a non-finite sample inside a pulse does not split it")
ok(identical(trigger_edges(pulse_na, min_pulse_s = 0.1, fs = 100), 11L),
   "and the true onset survives a min_pulse_s filter")

# --- a window column carried through resp_epochs() could shadow a computed
# feature of the same name; `$` then returned the user's value.
errors_with(epoch_features(bt_reg, resp_epochs(onset = 20, duration = 15,
                                               n_breaths = 99)),
            "collide with computed feature names",
            "a colliding window column is refused rather than silently shadowing")

# --- zero windows must give zero rows, not NULL.
ef_none <- epoch_features(bt_reg, resp_epochs(onset = 10, duration = 5)[0, ])
ok(is.data.frame(ef_none) && nrow(ef_none) == 0L,
   "an empty epochs table yields a zero-row frame, not NULL")

# --- window_coverage_s was the unclipped sum, sitting one column from the
# clipped coverage_frac and contradicting it.
cov_eps2 <- resp_epochs(onset = c(0, 30), duration = 10)
cov_ef2  <- epoch_features(bt_reg, cov_eps2)
ok(all(cov_ef2$window_coverage_s <= 10 + 1e-9),
   "window_coverage_s never exceeds the window it describes")
# The min(1, .) clamp needs a table that can exceed it: duplicated breaths
# double the spanned time, so an unclamped coverage would read ~2.
dup_ef <- epoch_features(rbind(bt_reg, bt_reg), cov_eps2)
ok(all(dup_ef$coverage_frac <= 1 + 1e-9),
   sprintf("coverage_frac is clamped to 1 even when cycles overlap (max %.3f)",
           max(dup_ef$coverage_frac)))
ok(any(dup_ef$window_coverage_s > 10),
   "confirming the unclamped span really would exceed the window")
near(cov_ef2$window_coverage_s / 10, cov_ef2$coverage_frac, 1e-9,
     "and agrees with coverage_frac")

# --- an "unusable" verdict could carry an empty note when na_degraded was
# disabled, which is exactly what the documented calibration workflow does.
gap_sig <- synth_resp(rep(4, 200), duty = 0.4, fs = 25, noise = 0.02)$signal
gap_sig[1:7500] <- NA
q_nodeg <- suppressWarnings(suppressMessages(
  resp_quality(gap_sig, fs = 25, thresholds = list(na_degraded = NA))))
ok(q_nodeg$quality == "unusable", "a half-missing recording is still unusable")
ok(length(q_nodeg$flags) > 0 && nzchar(q_nodeg$note),
   "and says why, even with the degraded threshold switched off")

# --- the all-non-finite early return left a NULL fs, which cannot be bound.
q_nofs <- suppressWarnings(suppressMessages(resp_quality(rep(NA_real_, 100))))
ok(!is.null(q_nofs$fs) && length(q_nofs$fs) == 1L,
   "the all-missing early return has a bindable fs")
ok(isTRUE(tryCatch({
     as.data.frame(q_nofs[setdiff(names(q_nofs), "flags")]); TRUE
   }, error = function(e) FALSE)),
   "so a cohort of quality rows can be row-bound")

# --- plot_resp promoted col/lwd/xlab/ylab to arguments but left `type`
# hard-coded, so passing it still collided.
png(file.path(tempdir(), "respkit_type.png"), 600, 400)
type_ok <- tryCatch({ plot_resp(pp$recording, type = "p"); TRUE },
                    error = function(e) FALSE)
dev.off()
ok(type_ok, "plot_resp accepts `type` without an argument clash")

cat("\n== regression: fifth review pass ==\n")

# --- flag_breaths guarded the duration-outlier test with `mad > 0`. Durations
# are differences of floating-point sample times, so on regular breathing the
# MAD is not zero but a residue near 1e-15. The guard passed, the threshold
# became a few femtoseconds, and roughly half the breaths were rejected --
# collapsing duration_sd, duration_cv and duration_rmssd on exactly the
# recordings where regularity is the finding.
reg_start <- cumsum(c(0, rep(c(4.00, 3.96, 4.00, 4.04), 5)))
reg_bt <- data.frame(breath = seq_along(reg_start),
                     t_start = reg_start,
                     t_end   = c(reg_start[-1], reg_start[21] + 4.00))
reg_bt$duration    <- reg_bt$t_end - reg_bt$t_start
reg_bt$amplitude   <- 1
reg_bt$implausible <- FALSE
ok(stats::mad(reg_bt$duration) > 0,
   sprintf("the float residue really is non-zero (mad = %.3g)",
           stats::mad(reg_bt$duration)))
reg_f <- flag_breaths(reg_bt)
ok(sum(reg_f$duration_outlier) == 0L,
   sprintf("regular breathing yields no duration outliers (%d flagged)",
           sum(reg_f$duration_outlier)))
ok(all(reg_f$keep), "and every cycle is kept")

# A genuine outlier must still be caught once real variability exists.
out_bt <- reg_bt
out_bt$duration[5] <- 40
ok(flag_breaths(out_bt)$duration_outlier[5],
   "while a genuinely aberrant duration is still flagged")

# --- resp_quality checked the WHOLE recording for finite samples but then
# worked on the trimmed span, so a belt that disconnected early killed the
# filter -- and a whole batch loop with it.
drop_fs  <- 25
drop_sig <- synth_resp(rep(4, 600), duty = 0.4, fs = drop_fs, noise = 0.02)$signal
drop_sig[(100 * drop_fs + 1):length(drop_sig)] <- NA_real_
q_drop <- suppressWarnings(suppressMessages(resp_quality(drop_sig, fs = drop_fs)))
ok(identical(q_drop$quality, "unusable"),
   "a recording with data only in the trimmed-off head is graded, not crashed on")
ok(nzchar(q_drop$note), "and says why")
ok(identical(names(q_drop),
             names(suppressWarnings(suppressMessages(
               resp_quality(synth_resp(rep(4, 300), fs = 25, noise = 0.02)$signal,
                            fs = 25))))),
   "with the same fields as a normal grading, so a cohort binds")
ok(identical(suppressWarnings(suppressMessages(
       resp_analyse(resp_recording(drop_sig, fs = drop_fs),
                    target_fs = NULL)))$quality$quality, "unusable"),
   "and resp_analyse reports unusable rather than NA")

# The by_segment early return must carry the same fields as the normal path.
ok(identical(
     names(suppressWarnings(suppressMessages(
       resp_quality(rep(NA_real_, 100), fs = 25, by_segment = TRUE)))),
     names(suppressWarnings(suppressMessages(
       resp_quality(synth_resp(rep(4, 120), fs = 25, noise = 0.02)$signal,
                    fs = 25, trim_s = 20, by_segment = TRUE))))),
   "the by_segment early return has the same shape as the normal path")

# --- min_pulse_s is in seconds and was silently inert without a rate: the
# placeholder fs = 1 rounded any sub-second threshold to zero.
errors_with(trigger_edges(c(rep(0, 10), rep(1, 20), rep(0, 10)), min_pulse_s = 0.1),
            "must be given too",
            "min_pulse_s without fs is refused rather than silently ignored")
ok(length(trigger_edges(c(rep(0, 2000), rep(3, 20), rep(1, 2000), rep(0, 100)),
                        min_pulse_s = 0.1, fs = 2000)) == 1L,
   "and with fs it removes the short settle run")

# --- filling non-finite samples forward kept a pulse whole but also stretched
# its measured length across the filled region, so a 3-sample artefact trailed
# by missing data passed a 50-sample floor and outranked real pulses.
fill_trig <- c(rep(0, 10), rep(1, 3), rep(NaN, 87))
ok(nrow(trigger_runs(fill_trig, fs = 100, min_pulse_s = 0.5)) == 0L,
   "a short pulse padded out by missing data does not pass a min_pulse_s floor")
ok(identical(trigger_runs(fill_trig, fs = 100)$length, 3L),
   "because run length counts only samples that were finite to begin with")
na_in_pulse <- replace(c(rep(0, 10), rep(1, 20), rep(0, 10)), 20, NA)
ok(identical(trigger_edges(na_in_pulse, fs = 100), 11L),
   "while an NA inside a pulse still leaves the pulse whole")

cat("\n== boundaries and reported values ==\n")

# Every inclusive/exclusive slip in the recent code hides at exact equality,
# and nothing was tested there.

# resp_quality thresholds: `above_thr` and `below_thr` are the package's whole
# threshold semantics, and neither was exercised at equality.
ok(!above_thr(1.0, 1.0), "above_thr is strict at equality")
ok(!below_thr(1.0, 1.0), "below_thr is strict at equality")
ok(above_thr(1.0 + 1e-9, 1.0) && below_thr(1.0 - 1e-9, 1.0),
   "and fires just past it in each direction")

# trigger_max is an exclusive ceiling.
ok(length(trigger_edges(c(rep(0, 10), rep(200, 10), rep(0, 10)),
                        trigger_max = 200)) == 0L,
   "a code equal to trigger_max is rejected")
ok(length(trigger_edges(c(rep(0, 10), rep(199, 10), rep(0, 10)),
                        trigger_max = 200)) == 1L,
   "and one just below it is kept")

# min_pulse_s is an inclusive floor, and its rounding must be `round`.
edge_pulse <- c(rep(0, 10), rep(1, 10), rep(0, 10))
ok(length(trigger_edges(edge_pulse, min_pulse_s = 0.10, fs = 100)) == 1L,
   "a pulse of exactly min_pulse_s survives")
ok(length(trigger_edges(edge_pulse, min_pulse_s = 0.11, fs = 100)) == 0L,
   "and one just under it does not")

# debounce min_gap is inclusive, matching enforce_min_distance.
ok(all(debounce_edges(c(1L, 11L), debounce_s = 1, fs = 10)),
   "edges exactly debounce_s apart are both kept")
ok(sum(debounce_edges(c(1L, 10L), debounce_s = 1, fs = 10)) == 1L,
   "and one sample closer is thinned")

# resp_flatline's run floor.
flat_run <- c(stats::rnorm(50), rep(7, 25), stats::rnorm(50))
ok(resp_flatline(flat_run, fs = 25, min_run_s = 1)$pct > 15,
   "a run of exactly min_run_s counts as flatline")
ok(resp_flatline(flat_run, fs = 25, min_run_s = 1.08)$pct == 0,
   "and a run just under it does not")

# --- fields that are reported but were only ever checked for existence.
val_bt  <- mk_bt_cov(c(-2, 2, 6, 10), rep(4, 4))
val_eps <- resp_epochs(onset = 4, offset = 12)
val_ef  <- epoch_features(val_bt, val_eps)
# Cycles span (-2,2) (2,6) (6,10) (10,14); the window is [4,12]. Under rule
# "start" only the cycles beginning at 6 and 10 are assigned. Their spans
# clipped to the window are 4 s and 2 s, so 6 of 8 seconds are covered.
ok(val_ef$n_breaths == 2L, sprintf("n_breaths is 2 (got %d)", val_ef$n_breaths))
near(val_ef$window_coverage_s, 6, 1e-9, "window_coverage_s is the clipped 6 s")
near(val_ef$coverage_frac, 0.75, 1e-9, "and coverage_frac is 0.75, not 1")
ok(val_ef$n_breaths_partial == 2L,
   sprintf("n_breaths_partial counts the two cycles straddling the edges (got %d)",
           val_ef$n_breaths_partial))

# Non-overlapping windows must produce no multi-match warning at all.
w_multi <- NULL
invisible(withCallingHandlers(
  epoch_breaths(val_bt, resp_epochs(onset = c(0, 40), duration = 10), rule = "start"),
  warning = function(x) { w_multi <<- conditionMessage(x); invokeRestart("muffleWarning") }))
ok(is.null(w_multi), "ordinary non-overlapping windows raise no warning")

# resp_quality's early-return values, not just their presence.
er <- suppressWarnings(suppressMessages(resp_quality(rep(NA_real_, 100), fs = 25)))
near(er$na_pct, 100, 1e-9, "the all-missing early return reports na_pct = 100")
near(er$duration_s, 4, 1e-9, "and duration_s = n / fs")
near(er$usable_duration_s, 0, 1e-9, "and no usable duration")

# resp_quality's trimming arithmetic: both ends, halved.
tq <- suppressWarnings(suppressMessages(
  resp_quality(synth_resp(rep(4, 100), fs = 25, noise = 0.02)$signal,
               fs = 25, trim_s = 20)))
near(tq$usable_duration_s, tq$duration_s - 40, 0.1,
     "trim_s is removed from each end, not once in total")

# %||% orientation.
ok(identical((NULL %||% 5), 5) && identical((3 %||% 5), 3),
   "%||% returns the left value unless it is NULL")

cat("\n== regression: sixth review pass ==\n")

# --- despike: the same `threshold` must mean the same thing at every rate ---
#
# The scale was the MAD of the FIRST DIFFERENCE, which shrinks as ~1/fs because
# neighbouring samples lie closer together the faster you sample, while the
# residual is measured against a window fixed in SECONDS and does not shrink.
# One real 2000 Hz recording decimated to a range of rates flagged 7.234% at
# 2000 Hz and 0.004% at 25 Hz -- and resp_analyse() despikes at the NATIVE rate
# on purpose, so the default path was the 2000 Hz one, rewriting a median 6.0%
# of samples across 24 archived recordings.
rate_pct <- vapply(c(25, 100, 500, 2000), function(fs_d) {
  s <- synth_resp(rep(4, 12), duty = 0.4, fs = fs_d, noise = 0.002)$signal
  100 * mean(resp_despike(s, fs = fs_d, warn_frac = Inf) != s)
}, numeric(1))
ok(all(rate_pct < 0.5),
   sprintf("a clean trace survives despiking at 25-2000 Hz (worst %.3f%%)",
           max(rate_pct)))
ok(diff(range(rate_pct)) < 0.5,
   sprintf("and the flagged fraction does not track the sampling rate (spread %.3f%%)",
           diff(range(rate_pct))))

# Sensitivity must be rate-invariant too, not just the false-positive rate:
# a spike of a given size in signal SDs is caught at every rate.
caught <- vapply(c(25, 100, 500, 2000), function(fs_d) {
  s <- synth_resp(rep(4, 12), duty = 0.4, fs = fs_d, noise = 0.01)$signal
  set.seed(4); at <- sort(sample(seq(20, length(s) - 20), 20))
  s[at] <- s[at] + 2 * stats::sd(s) * rep(c(-1, 1), 10)
  sum(at %in% which(resp_despike(s, fs = fs_d, warn_frac = Inf) != s))
}, numeric(1))
ok(all(caught >= 19),
   sprintf("2-SD spikes are caught at every rate from 25 to 2000 Hz (%s of 20)",
           paste(caught, collapse = ", ")))

# The flagged fraction is now reported rather than buried in provenance.
noisy_d <- synth_resp(rep(4, 30), duty = 0.4, fs = 25, noise = 0.01)$signal
noisy_d[seq(50, 2000, by = 7)] <- noisy_d[seq(50, 2000, by = 7)] + 20
warns_with(resp_despike(noisy_d, fs = 25, warn_frac = 0.01),
           "interpolated .* of samples",
           "despiking a large fraction of a recording warns")
no_warning(resp_despike(noisy_d, fs = 25, warn_frac = Inf),
           "and warn_frac = Inf silences it")

# --- polarity is diagnosed, not assumed --------------------------------
#
# resp_polarity() existed and nothing called it, so an inverted transducer
# produced a complete, plausible, silently mirrored breath table.
inv_sig <- -synth_resp(rep(4, 40), duty = 0.28, fs = 25, noise = 0.01)$signal
warns_with(resp_analyse(resp_recording(inv_sig, fs = 25), quality = FALSE),
           "polarity = \"up\" was requested, but the data indicate \"down\"",
           "an inverted signal analysed as \"up\" is warned about")
res_pol <- suppressWarnings(resp_analyse(resp_recording(inv_sig, fs = 25),
                                         polarity = "down", quality = FALSE))
ok(identical(res_pol$polarity$suggestion, "down"),
   "and analysing it as \"down\" agrees with the diagnostic")
no_warning(resp_analyse(resp_recording(inv_sig, fs = 25), polarity = "down",
                        quality = FALSE),
           "and analysing it as \"down\" raises no polarity warning")

# Every path out of the verdict carries the same fields, so a cohort binds.
verdict_fields <- lapply(list(0.3, 0.5, 0.7, NA_real_), polarity_verdict)
ok(length(unique(lapply(verdict_fields, names))) == 1L,
   "polarity_verdict returns identical fields on every path, including NA")
ok(nrow(do.call(rbind, lapply(verdict_fields, function(v)
     as.data.frame(v, stringsAsFactors = FALSE)))) == 4L,
   "so four verdicts row-bind into four rows")

# --- a trigger line that idles off zero ---------------------------------
#
# On this archive the line idles at 240 with codes arriving as 241-248. The
# default trigger_max = 200 returns nothing, and raising it is the wrong fix:
# the idle stretches then qualify as codes and roughly double the edge count.
idle_trig <- rep(240, 2000)
idle_trig[c(200:400, 900:1100, 1500:1600)] <- c(241, 243, 248)[c(1, 2, 3)][
  rep(1:3, times = c(201, 201, 101))]
ok(nrow(trigger_runs(idle_trig, trigger_max = 200, fs = 100)) == 0L,
   "a line idling at 240 yields no runs under the default trigger_max")
raised <- trigger_runs(idle_trig, trigger_max = Inf, fs = 100)
ok(240 %in% raised$code,
   "raising trigger_max admits the idle level itself as a trigger code")
offset <- trigger_runs(idle_trig - 240, trigger_max = 200, fs = 100)
ok(nrow(offset) == 3L && identical(sort(unique(offset$code)), c(1, 3, 8)),
   sprintf("subtracting the idle level recovers exactly the 3 real codes (%s)",
           paste(sort(unique(offset$code)), collapse = ", ")))
ok(identical(as.integer(offset$index), c(200L, 900L, 1500L)),
   "at the right sample indices")
ok("trigger_idle" %in% names(formals(resp_read_acq)),
   "and resp_read_acq exposes trigger_idle so the channel need not be pre-edited")

# The whole .acq trigger path, minus the file read, so that trigger_idle is
# checked for EFFECT rather than merely for existing.
ev_default <- suppressMessages(acq_trigger_events(idle_trig, 100))
ok(is.null(ev_default),
   "the .acq trigger path yields no events on a line idling at 240")
ev_idle <- acq_trigger_events(idle_trig, 100, trigger_idle = 240)
ok(!is.null(ev_idle) && nrow(ev_idle) == 3L,
   sprintf("and trigger_idle = 240 recovers all 3 events (%d)",
           if (is.null(ev_idle)) 0L else nrow(ev_idle)))
near(ev_idle$time, c(199, 899, 1499) / 100, 1e-9,
     "at the right times in seconds")
ok(identical(ev_idle$value, c(1, 3, 8)),
   "carrying the de-offset codes, not the raw 241/243/248")
# "auto" — because the archive is mixed: some recordings idle at 0, others at
# 240, so one hard-coded value silently loses every trigger in one half.
ok(identical(suppressMessages(resolve_trigger_idle(idle_trig, "auto")), 240),
   "trigger_idle = \"auto\" finds the 240 idle level")
ok(identical(resolve_trigger_idle(c(rep(0, 1800), rep(5, 200)), "auto"), 0),
   "and leaves a line that already idles at 0 alone")
# A real archive recording idles at a denormal float rather than a clean zero.
# Codes are integers of at least 1, so anything below half a count is zero.
denorm <- c(rep(2.05227e-289, 1800), rep(5, 200))
ok(identical(resolve_trigger_idle(denorm, "auto"), 0),
   "a denormal idle level is treated as zero, not subtracted and announced")
ok(identical(suppressMessages(acq_trigger_events(denorm, 100))$value, 5),
   "and the codes on such a channel are still found")
ev_auto <- suppressMessages(acq_trigger_events(idle_trig, 100, trigger_idle = "auto"))
ok(!is.null(ev_auto) && identical(ev_auto$value, c(1, 3, 8)),
   "so the same call recovers the codes without being told the level")
ok(identical(resolve_trigger_idle(idle_trig, 240), 240),
   "an explicit number is passed through untouched")
errors_with(resolve_trigger_idle(idle_trig, "guess"),
            "must be a single finite number",
            "and anything else is refused rather than silently ignored")
# A channel with no idle level must not have one invented for it.
warns_with(resolve_trigger_idle(seq_len(2000), "auto"),
           "could not identify an idle level",
           "auto declines when no value dominates the channel")
ok(identical(suppressWarnings(resolve_trigger_idle(seq_len(2000), "auto")), 0),
   "and falls back to 0 rather than subtracting noise")

msg <- utils::capture.output(invisible(acq_trigger_events(idle_trig, 100)),
                             type = "message")
ok(any(grepl("trigger_idle = 240", msg, fixed = TRUE)),
   "and the message names the trigger_idle value to use")
ok(any(grepl("Do NOT", msg, fixed = TRUE)) &&
     any(grepl("raise `trigger_max`", msg, fixed = TRUE)),
   "while warning against the remedy that would admit the idle level as a code")

# --- accuracy against ground truth, not just self-consistency -----------
#
# Everything below the detector was previously checked only for internal
# consistency: that cycles tile, that duty lies in (0, 1), that peaks fall
# inside their own cycle. All of that holds perfectly well for a pipeline that
# is systematically wrong, which is how a rate-dependent duty-cycle bias
# survived the whole suite.
clean_err <- vapply(c(25, 50, 100, 250), function(fs_a) {
  s <- synth_resp(rep(4, 40), duty = 0.4, fs = fs_a, noise = 0.01)
  o <- suppressWarnings(suppressMessages(
    resp_analyse(resp_recording(s$signal, fs = fs_a), target_fs = NULL,
                 quality = FALSE)))
  abs(stats::median(o$breaths$duration) - 4) / 4
}, numeric(1))
ok(all(clean_err < 0.02),
   sprintf("median duration recovers 4.00 s to within 2%% at 25-250 Hz (worst %.3f%%)",
           100 * max(clean_err)))

# A constant scale error -- the decimation defect this package exists to
# prevent -- shows up here and nowhere else in the suite.
scale_err <- vapply(c(2.5, 4, 6, 10), function(D) {
  s <- synth_resp(rep(D, 30), duty = 0.4, fs = 100, noise = 0.01)
  o <- suppressWarnings(suppressMessages(
    resp_analyse(resp_recording(s$signal, fs = 100), target_fs = NULL,
                 quality = FALSE)))
  stats::median(o$breaths$duration) / D
}, numeric(1))
near(scale_err, 1, 0.02,
     "and the recovered/true duration ratio is 1 at every rate from 6 to 24/min")

# Duty cycle is biased upward and the bias grows with breathing rate; see the
# duty-cycle section of ?resp_analyse. This is a tripwire on its magnitude, not
# an endorsement: measured at 0.010 at 7.5/min and 0.040 at 30/min. If it grows,
# something has narrowed the measurement band or broken refinement.
duty_bias <- vapply(c(8, 2), function(D) {
  s <- synth_resp(rep(D, 50), duty = 0.30, fs = 200, noise = 0.01)
  o <- suppressWarnings(suppressMessages(
    resp_analyse(resp_recording(s$signal, fs = 200), target_fs = 50,
                 quality = FALSE)))
  stats::median(o$breaths$duty_cycle, na.rm = TRUE) - 0.30
}, numeric(1))
ok(all(duty_bias >= 0 & duty_bias < 0.06),
   sprintf("duty-cycle bias stays under 0.06 at both 7.5 and 30/min (%.4f, %.4f)",
           duty_bias[1], duty_bias[2]))
ok(duty_bias[2] - duty_bias[1] < 0.06,
   sprintf("and its growth with rate stays bounded (%.4f over 7.5-30/min)",
           duty_bias[2] - duty_bias[1]))

cat("\n== property-based sweep ==\n")

# Invariants that must hold for any input, checked across the parameter space
# rather than at hand-picked points.
set.seed(20260805)
n_ok <- 0L; problems <- character(0); dur_err <- numeric(0)
for (trial in 1:40) {
  fs_p   <- sample(c(20, 25, 25.641, 50, 100), 1)
  durs_p <- stats::runif(sample(8:30, 1), 2, 9)
  duty_p <- stats::runif(1, 0.15, 0.75)
  amp_p  <- 10^stats::runif(1, -2, 2)
  pol_p  <- sample(c("up", "down"), 1)

  sy <- synth_resp(durs_p, duty = duty_p, amplitude = amp_p, fs = fs_p,
                   noise = amp_p * stats::runif(1, 0, 0.15),
                   drift = amp_p * stats::runif(1, 0, 3), seed = trial)
  sig_p <- if (pol_p == "down") -sy$signal + amp_p * 3 else sy$signal

  o <- tryCatch(suppressWarnings(suppressMessages(
        resp_analyse(resp_recording(sig_p, fs = fs_p), target_fs = NULL,
                     polarity = pol_p, normalise = sample(c("robust","z","none"), 1),
                     min_prominence = 0.3, min_distance_s = 1, quality = FALSE))),
        error = function(e) { problems <<- c(problems,
          sprintf("trial %d errored: %s", trial, conditionMessage(e))); NULL })
  if (is.null(o)) next
  n_ok <- n_ok + 1L
  b <- o$breaths
  d <- o$detection
  bad <- character(0)

  merged_p <- c(rep(1L, length(d$peaks)), rep(0L, length(d$troughs)))[
    order(c(d$peaks, d$troughs))]
  if (length(merged_p) > 1 && any(diff(merged_p) == 0)) bad <- c(bad, "non-alternating")
  if (length(intersect(d$peaks, d$troughs)))            bad <- c(bad, "peak==trough")
  if (nrow(b)) {
    hp <- b$has_peak %in% TRUE
    if (any(b$t_start >= b$t_end, na.rm = TRUE))        bad <- c(bad, "t_start>=t_end")
    if (any(b$t_peak[hp] <= b$t_start[hp], na.rm = TRUE) ||
        any(b$t_peak[hp] >= b$t_end[hp],   na.rm = TRUE)) bad <- c(bad, "peak outside cycle")
    if (any(b$t_peak[hp] <= b$t_start[hp] | b$t_peak[hp] >= b$t_end[hp], na.rm = TRUE))
      bad <- c(bad, "peak outside its own cycle")
    if (any(b$inhale_dur <= 0 | b$exhale_dur <= 0, na.rm = TRUE))
      bad <- c(bad, "non-positive phase")
    if (any(b$duty_cycle <= 0 | b$duty_cycle >= 1, na.rm = TRUE)) bad <- c(bad, "duty outside (0,1)")
    if (any(b$amplitude <= 0, na.rm = TRUE))            bad <- c(bad, "amplitude<=0")
    if (nrow(b) > 1 && any(b$i_end[-nrow(b)] != b$i_start[-1])) bad <- c(bad, "cycles do not tile")
  }
  # Accuracy, alongside the invariants. Only where detection recovered most of
  # the breaths -- these are deliberately hostile parameters (drift up to three
  # times the amplitude, duty from 0.15 to 0.75) and some trials are meant to
  # be hard. Where it did recover them, the durations have to be right.
  if (nrow(b) >= 0.5 * length(durs_p))
    dur_err <- c(dur_err,
                 abs(stats::median(b$duration, na.rm = TRUE) -
                       stats::median(durs_p)) / stats::median(durs_p))

  if (length(bad))
    problems <- c(problems, sprintf("trial %d: %s", trial, paste(bad, collapse = ", ")))
}
ok(n_ok == 40, sprintf("all 40 randomised pipelines completed (%d)", n_ok))
ok(length(dur_err) >= 30,
   sprintf("most trials recovered enough breaths to check accuracy (%d of 40)",
           length(dur_err)))
ok(stats::median(dur_err) < 0.10,
   sprintf("and the median duration error across the sweep is small (%.3f)",
           stats::median(dur_err)))
ok(length(problems) == 0,
   sprintf("no invariant violations across the parameter sweep%s",
           if (length(problems)) paste0(": ", paste(head(problems, 3), collapse = "; ")) else ""))

cat("\nAll tests passed.\n")
