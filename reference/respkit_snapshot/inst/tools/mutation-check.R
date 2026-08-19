# =====================================================================
#  mutation-check.R — verify that the test suite can actually fail
#
#  A test that passes when the code it guards is broken is worse than no
#  test, because it manufactures confidence. An earlier audit of this
#  package mutation-tested its own suite and found 23 assertions in that
#  category, including the one supposedly protecting the peak-prominence
#  definition that the README devotes a section to.
#
#  This script breaks each behaviour the suite claims to protect, runs the
#  suite against the broken copy, and reports whether it noticed. A mutation
#  that SURVIVES is a hole in the suite.
#
#  Run it after adding a regression test, to confirm the new test genuinely
#  fails without the fix:
#
#      Rscript inst/tools/mutation-check.R            # every mutation
#      Rscript inst/tools/mutation-check.R <name>     # just one
#
#  The package directory is never modified: each mutation is applied to a
#  fresh copy under tempdir().
# =====================================================================

PKG <- Sys.getenv("RESPKIT_DIR", unset = ".")
if (!file.exists(file.path(PKG, "DESCRIPTION")))
  stop("Run from the package root, or set RESPKIT_DIR to it.", call. = FALSE)

RSCRIPT <- file.path(R.home("bin"), if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")
WORK    <- file.path(tempdir(), "respkit_mutation_check")
# Resolved once, absolutely: the working directory is moved into a copy that is
# then deleted, so restoring to whatever setwd() last returned is not safe.
ROOT    <- normalizePath(PKG, winslash = "/", mustWork = TRUE)

# Each entry: file, a fixed string to find, and what to replace it with.
mutations <- list(
  decim_integer_div = list("R/resample.R",
    "  f <- sort(prime_factors(q), decreasing = TRUE)",
    "  f <- rep(13L, 1L)  # MUTANT"),
  decim_minlen_max = list("R/resample.R",
    "    min_len <- 30L * q",
    "    min_len <- 30L * max(stages)  # MUTANT"),
  filter_no_pad = list("R/filter.R",
    "  want_pad <- round(pad_s * fs)",
    "  want_pad <- 0L  # MUTANT"),
  filter_no_na_restore = list("R/filter.R",
    "  out[gaps$filled] <- NA_real_",
    "  # MUTANT: NA not restored"),
  despike_mad_resid = list("R/clean.R",
    "    scale <- stats::mad(diff(v, lag = h), na.rm = TRUE)",
    "    scale <- stats::mad(resid, na.rm = TRUE)  # MUTANT"),
  despike_window_1s = list("R/clean.R",
    "                         warn_frac = 0.01, fs = NULL) {",
    "                         warn_frac = 0.01, fs = NULL) { window_s <- 1  # MUTANT"),
  refine_which_max = list("R/detect.R",
    "    best <- which(seg == tgt)",
    "    best <- if (seek_max) which.max(seg) else which.min(seg)  # MUTANT"),
  zerocross_strict = list("R/detect.R",
    "  positive <- x >= 0",
    "  positive <- x > 0  # MUTANT"),
  zerocross_label_by_sign = list("R/detect.R",
    "  list(peaks   = as.integer(extrema[is_peak]),\n       troughs = as.integer(extrema[!is_peak]))",
    "  list(peaks = as.integer(extrema[x[extrema] > 0]), troughs = as.integer(extrema[x[extrema] <= 0]))  # MUTANT"),
  prominence_min_not_max = list("R/detect.R",
    "    x[p] - max(left_min, right_min)",
    "    x[p] - min(left_min, right_min)  # MUTANT"),
  alternation_skip = list("R/detect.R",
    "  if (alternation_rule != \"none\") {",
    "  if (FALSE) {  # MUTANT"),
  breaths_no_lower_bound = list("R/breaths.R",
    "    if (min(all_idx) < 1L)",
    "    if (FALSE)  # MUTANT"),
  breaths_baseline_negated = list("R/breaths.R",
    "    baseline    = if (polarity == \"down\") -sig[starts] else sig[starts],",
    "    baseline    = sig[starts],  # MUTANT"),
  breaths_amp_inhale_only = list("R/breaths.R",
    "  amplitude  <- rowMeans(cbind(amp_inhale, amp_exhale))",
    "  amplitude  <- amp_inhale  # MUTANT"),
  flag_no_bad_amp = list("R/breaths.R",
    "  bt$bad_amplitude <- !is.na(bt$amplitude) & bt$amplitude <= 0",
    "  bt$bad_amplitude <- rep(FALSE, nrow(bt))  # MUTANT"),
  rate_series_midpoint = list("R/features.R",
    "    slot <- pmax(1L, findInterval(grid, b$t_start))",
    "    slot <- pmax(1L, findInterval(grid, (b$t_start + b$t_end)/2))  # MUTANT"),
  epoch_index_by_breath = list("R/epoch.R",
    "    which(hit %in% TRUE)",
    "    bt$breath[which(hit %in% TRUE)]  # MUTANT"),
  epoch_ignore_lag = list("R/epoch.R",
    "    start = onset  + lag,\n    end   = offset + lag,",
    "    start = onset, end = offset,  # MUTANT"),
  epoch_coverage_stub = list("R/epoch.R",
    "    coverage <- if (length(spanned) && win_len > 0)",
    "    coverage <- 1; if (FALSE)  # MUTANT"),
  psd_no_factor_2 = list("R/quality.R",
    "    power = 2 * accum / (used * seg * fs * u)",
    "    power = accum / (used * seg * fs * u)  # MUTANT"),
  saturation_sum = list("R/quality.R",
    "       pct_saturated = 100 * sum(at_min | at_max) / length(s),",
    "       pct_saturated = 100 * (sum(at_min) + sum(at_max)) / length(s),  # MUTANT"),
  quality_dom_lo_low = list("R/quality.R",
    "  in_dom <- psd$freq >= dom_lo & psd$freq <= resp_band",
    "  in_dom <- psd$freq >= low & psd$freq <= resp_band  # MUTANT"),
  quality_no_band_ratio = list("R/quality.R",
    "    band_ratio_min = 0.80",
    "    band_ratio_min = NA_real_  # MUTANT"),
  # Faithful to the original defect: the comparison returned NA and the
  # surrounding `if` errored. Dropping only the !is.na() guard while keeping
  # isTRUE() would be an EQUIVALENT mutant -- isTRUE(NA) is FALSE, which is
  # exactly what a disabled threshold should do -- so it must go too.
  quality_na_crash = list("R/quality.R",
    "below_thr <- function(x, thr) isTRUE(is.finite(x) && !is.na(thr) && x < thr)",
    "below_thr <- function(x, thr) is.finite(x) && x < thr  # MUTANT"),
  recording_fs_ignored = list("R/recording.R",
    "        abs(fs - x$fs) > 1e-9 * max(1, abs(x$fs)))",
    "        FALSE)  # MUTANT"),
  recording_factor_time = list("R/recording.R",
    "    if (is.factor(events$time)) events$time <- as.character(events$time)",
    "    # MUTANT: factor left alone"),
  recording_slice_logical = list("R/recording.R",
    "    ev <- ev[which(ev$time >= lo & ev$time <= hi), , drop = FALSE]",
    "    ev <- ev[ev$time >= lo & ev$time <= hi, , drop = FALSE]  # MUTANT"),
  # --- sixth review pass ------------------------------------------------
  # The scale reverted to a lag of one sample: rate-dependent again.
  despike_lag1_scale = list("R/clean.R",
    "    scale <- stats::mad(diff(v, lag = h), na.rm = TRUE)",
    "    scale <- stats::mad(diff(v), na.rm = TRUE)  # MUTANT"),
  # The lag kept but the threshold left at its old value: sensitivity lost.
  despike_old_threshold = list("R/clean.R",
    "resp_despike <- function(x, threshold = 3, max_width_s = 1, window_s = 0.3,",
    "resp_despike <- function(x, threshold = 10, max_width_s = 1, window_s = 0.3,  # MUTANT"),
  despike_no_warn = list("R/clean.R",
    "    if (is.finite(warn_frac) && frac > warn_frac)",
    "    if (FALSE)  # MUTANT"),
  polarity_no_warn = list("R/pipeline.R",
    "  if (isTRUE(pol$confident) && !identical(pol$suggestion, polarity))",
    "  if (FALSE)  # MUTANT"),
  polarity_verdict_ragged = list("R/breaths.R",
    "                suggestion = NA_character_, confident = FALSE,\n                note = paste0(\"No cycle had both a peak and two bounding \",\n                              \"troughs, so duty cycle is undefined and \",\n                              \"polarity cannot be diagnosed from the data.\")))",
    "                suggestion = NA_character_, confident = FALSE))  # MUTANT"),
  acq_ignores_trigger_idle = list("R/io.R",
    "  if (trigger_idle != 0) trig <- trig - trigger_idle",
    "  # MUTANT: trigger_idle ignored"),
  # "auto" guessing an offset on a channel that has no idle level.
  acq_auto_idle_no_share_check = list("R/io.R",
    "  if (share < min_share) {",
    "  if (FALSE) {  # MUTANT"),
  # The idle level taken as the RAREST value rather than the commonest.
  acq_auto_idle_min_not_modal = list("R/io.R",
    "  modal <- as.numeric(names(tab)[which.max(tab)])",
    "  modal <- as.numeric(names(tab)[which.min(tab)])  # MUTANT"),
  io_t0_zero = list("R/io.R",
    "    t0 <- if (!is.null(obj$trim_offset_samp))",
    "    t0 <- 0; if (FALSE)  # MUTANT"),
  io_q_from_target = list("R/io.R",
    "    q_requested <- as.integer(round(native_fs / stored_fs))",
    "    q_requested <- as.integer(round(native_fs / target_fs))  # MUTANT"),
  io_schema_partial = list("R/io.R",
    "    !(\"schema\" %in% names(obj))",
    "    is.null(obj$schema)  # MUTANT"),

  # --- added after the third review pass -----------------------------------
  coverage_whole_durations = list("R/epoch.R",
    "      pmax(0, pmin(usable$t_end, ep$end) - pmax(usable$t_start, ep$start)) else numeric(0)",
    "      usable$duration else numeric(0)  # MUTANT"),
  zerocross_no_centring = list("R/detect.R",
    "              mean   = x - mean(x, na.rm = TRUE),",
    "              mean   = x,  # MUTANT"),
  psd_rectangular = list("R/quality.R",
    "  w  <- 0.5 - 0.5 * cos(2 * pi * (seq_len(seg) - 1L) / (seg - 1L))",
    "  w  <- rep(1, seg)  # MUTANT"),
  quality_no_na_degraded = list("R/quality.R",
    "  if (above_thr(na_pct, th$na_degraded))",
    "  if (FALSE)  # MUTANT"),
  epoch_rules_collapse = list("R/epoch.R",
    "      contained = bt$t_start >= lo[k] & bt$t_end   <= hi[k],",
    "      contained = bt$t_start >= lo[k] & bt$t_start <= hi[k],  # MUTANT"),
  epoch_pad_ignored = list("R/epoch.R",
    "  lo <- epochs$start - pad_s\n  hi <- epochs$end   + pad_s",
    "  lo <- epochs$start; hi <- epochs$end  # MUTANT"),
  variability_rmssd_as_sd = list("R/features.R",
    "  sqrt(mean(diff(y)^2))",
    "  stats::sd(y)  # MUTANT"),
  variability_cv_as_sd = list("R/features.R",
    "  stats::sd(y) / abs(m)",
    "  stats::sd(y)  # MUTANT"),
  clip_inert = list("R/clean.R",
    "    out <- pmin(pmax(sig, qs[1]), qs[2])",
    "    out <- sig  # MUTANT"),
  detrend_median_inert = list("R/clean.R",
    "    out  <- sig - base",
    "    out  <- sig  # MUTANT"),
  flatline_digits_ignored = list("R/quality.R",
    "  v <- if (is.null(digits)) sig else round(sig, digits)",
    "  v <- sig  # MUTANT"),
  saturation_tol_ignored = list("R/quality.R",
    "  band <- if (rng > 0) tol * rng else 0",
    "  band <- 0  # MUTANT"),
  quality_trim_ignored = list("R/quality.R",
    "  trimmed <- if (eff_trim > 0)",
    "  trimmed <- if (FALSE)  # MUTANT"),
  analyse_target_fs_ignored = list("R/pipeline.R",
    "  if (!is.null(target_fs) && target_fs < base$fs) {",
    "  if (FALSE) {  # MUTANT"),
  analyse_despike_ignored = list("R/pipeline.R",
    "  if (isTRUE(despike)) {",
    "  if (FALSE) {  # MUTANT"),
  prominence_threshold_ignored = list("R/detect.R",
    "    keep <- prom >= min_prominence",
    "    keep <- rep(TRUE, length(prom))  # MUTANT"),
  summarise_prefix_ignored = list("R/features.R",
    "  if (nzchar(prefix)) names(out) <- paste0(prefix, names(out))",
    "  # MUTANT: prefix ignored"),
  baseline_drift_na = list("R/features.R",
    "    baseline_drift           = if (n > 1L) ols_slope(b$baseline, b$t_start) else NA_real_,",
    "    baseline_drift           = NA_real_,  # MUTANT"),
  min_breaths_ignored = list("R/epoch.R",
    "    feat <- if (nrow(usable) >= min_breaths) {",
    "    feat <- if (TRUE) {  # MUTANT"),
  rate_series_linear_ends = list("R/features.R",
    "                                method = \"linear\", rule = 2)$y",
    "                                method = \"linear\", rule = 1)$y  # MUTANT"),

  # --- trigger edge detection, added after testing against real .acq files --
  trigger_zero_to_valid = list("R/io.R",
    "  keep <- r$values >= 1 & r$values < trigger_max & real_len >= min_pulse_samp",
    "  keep <- r$values >= 1 & r$values < trigger_max & real_len >= min_pulse_samp & c(TRUE, r$values[-length(r$values)] == 0)  # MUTANT"),
  trigger_no_denormal_guard = list("R/io.R",
    "  keep <- r$values >= 1 & r$values < trigger_max & real_len >= min_pulse_samp",
    "  keep <- r$values != 0 & r$values < trigger_max & real_len >= min_pulse_samp  # MUTANT"),
  trigger_na_poisons = list("R/io.R",
    "    for (i in which(is.na(v))) v[i] <- if (i > 1L) v[i - 1L] else 0",
    "    v[is.na(v)] <- 0  # MUTANT"),
  trigger_min_pulse_ignored = list("R/io.R",
    "  min_pulse_samp <- max(1L, round(min_pulse_s * fs))",
    "  min_pulse_samp <- 1L  # MUTANT"),
  trigger_debounce_first_wins = list("R/io.R",
    "  ord <- order(weight, decreasing = TRUE)",
    "  ord <- seq_along(edge)  # MUTANT: first of a cluster wins"),

  # --- added after the fourth review pass ----------------------------------
  clip_reversed = list("R/clean.R",
    "    out <- pmin(pmax(sig, qs[1]), qs[2])",
    "    out <- pmax(pmin(sig, qs[1]), qs[2])  # MUTANT"),
  saturation_strict = list("R/quality.R",
    "  at_min <- s <= lo + band",
    "  at_min <- s < lo + band  # MUTANT"),
  mindist_strict = list("R/detect.R",
    "    if (!length(accepted) || all(abs(idx[i] - idx[accepted]) >= min_dist))",
    "    if (!length(accepted) || all(abs(idx[i] - idx[accepted]) > min_dist))  # MUTANT"),
  psd_freq_off_by_one = list("R/quality.R",
    "    freq  = (seq_len(nf) - 1L) * fs / seg,",
    "    freq  = seq_len(nf) * fs / seg,  # MUTANT"),
  pad_tail_broken = list("R/filter.R",
    "  tail_pad <- 2 * x[n]  - x[(n - 1L):(n - npad)]",
    "  tail_pad <- rep(x[n], npad)  # MUTANT"),
  trigger_na_zeroed = list("R/io.R",
    "    for (i in which(is.na(v))) v[i] <- if (i > 1L) v[i - 1L] else 0",
    "    v[is.na(v)] <- 0  # MUTANT"),
  epoch_wcov_unclipped = list("R/epoch.R",
    "      feat$window_coverage_s <- sum(spanned, na.rm = TRUE)",
    "      feat$window_coverage_s <- sum(usable$duration, na.rm = TRUE)  # MUTANT"),
  epoch_no_collision_check = list("R/epoch.R",
    "    if (length(dup))",
    "    if (FALSE)  # MUTANT"),
  quality_na_unusable_silent = list("R/quality.R",
    "    if (above_thr(na_pct, th$na_unusable) && !above_thr(na_pct, th$na_degraded))",
    "    if (FALSE)  # MUTANT"),

  # --- added after the fifth review pass -----------------------------------
  flag_mad_bare_zero = list("R/breaths.R",
    "  mad_tol <- .Machine$double.eps^0.5 * max(1, abs(med_dur))",
    "  mad_tol <- 0  # MUTANT"),
  quality_trim_finiteness = list("R/quality.R",
    "  if (!any(is.finite(trimmed$signal)))",
    "  if (FALSE)  # MUTANT"),
  trigger_minpulse_no_fs_guard = list("R/io.R",
    "  if (min_pulse_s > 0 && missing(fs))\n    stop(\"`min_pulse_s` is in seconds, so `fs` must be given too. Without it \",\n         \"the threshold is measured against a placeholder rate of 1 Hz and \",\n         \"silently has no effect.\", call. = FALSE)\n  trigger_runs(",
    "  trigger_runs(  # MUTANT"),
  trigger_runlen_inflated = list("R/io.R",
    "  keep <- r$values >= 1 & r$values < trigger_max & real_len >= min_pulse_samp\n  data.frame(index  = as.integer(starts[keep]),\n             code   = r$values[keep],\n             length = real_len[keep])",
    "  keep <- r$values >= 1 & r$values < trigger_max & r$lengths >= min_pulse_samp\n  data.frame(index = as.integer(starts[keep]), code = r$values[keep], length = as.integer(r$lengths[keep]))  # MUTANT")
)

# The suite locates the package root relative to the WORKING DIRECTORY, so the
# copy must be run from inside itself. Getting this wrong is silently
# catastrophic for a mutation harness: the suite fails to source anything,
# errors immediately, and every mutation is scored "killed" for the wrong
# reason -- a harness that reports perfect coverage while testing nothing.
# `n_ok` guards against exactly that.
run_suite <- function(dir) {
  setwd(dir)
  on.exit(setwd(ROOT), add = TRUE)
  out <- suppressWarnings(system2(RSCRIPT, shQuote(file.path("tests", "test-respkit.R")),
                                  stdout = TRUE, stderr = TRUE))
  g <- grep("FAIL:", out, value = TRUE)
  list(passed     = any(grepl("All tests passed", out)),
       n_ok       = sum(grepl("^\\s+ok", out)),
       first_fail = if (length(g)) sub(".*FAIL: ", "", g[1]) else NA_character_)
}

fresh_copy <- function() {
  unlink(WORK, recursive = TRUE)
  dir.create(WORK, recursive = TRUE, showWarnings = FALSE)
  invisible(file.copy(list.files(PKG, full.names = TRUE), WORK, recursive = TRUE))
}

apply_one <- function(nm) {
  m <- mutations[[nm]]
  fresh_copy()
  p   <- file.path(WORK, m[[1]])
  txt <- paste(readLines(p, warn = FALSE), collapse = "\n")
  if (!grepl(m[[2]], txt, fixed = TRUE))
    return(list(applied = FALSE, passed = NA, n_ok = 0L,
                first_fail = "PATTERN NOT FOUND"))
  writeLines(sub(m[[2]], m[[3]], txt, fixed = TRUE), p)
  c(list(applied = TRUE), run_suite(WORK))
}

# Baseline: an UNMUTATED copy must pass, and must run a realistic number of
# assertions. Without this check a harness that never loads the code under
# test reports every mutation as caught.
cat("Baseline check on an unmutated copy ... ")
fresh_copy()
base <- run_suite(WORK)
if (!isTRUE(base$passed) || base$n_ok < 50L) {
  cat("FAILED\n")
  stop("The unmutated copy did not pass (", base$n_ok, " assertions ran). ",
       "The harness is not exercising the code; fix that before trusting any ",
       "result below.", call. = FALSE)
}
cat(sprintf("ok (%d assertions)\n\n", base$n_ok))
baseline_ok <- base$n_ok

args <- commandArgs(trailingOnly = TRUE)
todo <- if (length(args)) args else names(mutations)

cat(sprintf("%-28s %-9s %s\n", "mutation", "suite", "caught by"))
cat(strrep("-", 110), "\n")
survivors <- character(0)
skipped   <- character(0)
for (nm in todo) {
  r <- apply_one(nm)
  verdict <- if (!isTRUE(r$applied)) "SKIP"
             else if (isTRUE(r$passed)) "SURVIVED"
             else if (r$n_ok < 0.2 * baseline_ok) "BROKE-EARLY"
             else "killed"
  if (identical(verdict, "SURVIVED")) survivors <- c(survivors, nm)
  if (identical(verdict, "SKIP"))     skipped   <- c(skipped, nm)
  cat(sprintf("%-28s %-9s %s\n", nm, verdict,
              if (is.na(r$first_fail)) "" else substr(r$first_fail, 1, 66)))
}
unlink(WORK, recursive = TRUE)

cat("\n")
# A skipped mutation is a FAILURE, not a footnote. Anchor text drifts whenever
# the code it points at is edited -- which is exactly the code most in need of
# guarding -- and counting only SURVIVED made the harness report a perfect
# score while silently testing nothing in the regions most recently rewritten.
# An unfalsifiable pass is the failure this tool exists to catch.
if (length(skipped)) {
  cat(length(skipped), "MUTATION(S) COULD NOT BE APPLIED - their anchor text no",
      "longer matches the source:\n")
  for (s in skipped) cat("  -", s, "\n")
  cat("Re-anchor them against the current code; until then they guard nothing.\n\n")
}
if (length(survivors)) {
  cat(length(survivors), "SURVIVOR(S) - these assertions cannot fail:\n")
  for (s in survivors) cat("  -", s, "\n")
}
if (length(skipped) || length(survivors)) quit(status = 1)
cat("No survivors and nothing skipped: every mutation was applied and caught.\n")
