# 02_estimate_variance_components.R
#
# Internal pilot extraction for the BreathBelt pre-registration.
#
# PURPOSE
#   Estimate nuisance variance components needed to set sample size, WITHOUT
#   exposing any quantity that appears in a confirmatory decision rule.
#
#   The pilot participants remain eligible for the confirmatory analysis. That
#   only holds if nothing beyond the whitelist below is observed. Enforcement is
#   mechanical: the script computes blocked quantities internally where it must,
#   discards them, and refuses to write output containing anything unlisted.
#
# USAGE
#   Rscript scripts/02_estimate_variance_components.R
#   Output is a single RDS plus a plain-text report. Read the report. Do not run
#   interactively and inspect intermediate objects.
#
# DEPENDENCY
#   Requires RDS files produced by the CORRECTED prep pipeline, in which
#   calibration weights are fitted against the reconstructed pacer on the Block 1
#   window. RDS files from the earlier pipeline fitted weights against the BioPac
#   signal, which shrinks between-participant variance in the bias and would
#   yield an optimistic sample size. The script hard-fails on those files.
#
# CHANGES 2026-08-07
#   - Onset detection now comes from R/onsets.R, the SHARED detector, so the
#     variance components describe the signal the confirmatory analysis sees.
#     This closes handoff Task 2. The private .detect_onsets that used to live
#     here is gone.
#   - C1 applied: the between-participant SD is corrected for the sampling
#     variance of each participant's own mean. Approved by Norm 2026-07-31.
#   - C2 applied: breaths are matched on a 500 ms tolerance window, not by rank
#     position. Rank pairing slipped permanently after the first detection
#     discrepancy, so it described a different statistic from the one H1 computes.
#   - C5 applied: mlr_r_calib_lagcorr is carried alongside mlr_r_calib.
#   - C6 applied: model_margin is carried alongside selected_model_freq.
#   - DISCLOSURE FIX: breath_count used to report the count of PAIRED breaths,
#     which is the numerator of H2's blocked match proportion. It now reports
#     per-device detected breath count. See the note in .extract_one.

# Set Up ---------
## Load libraries ---------
packages <- c(
  "lme4",
  "tidyverse",
  "signal",
  "zoo"
)
new_packages <- packages[!sapply(packages, requireNamespace, quietly = TRUE)]
if (length(new_packages)) install.packages(new_packages, repos = "https://cloud.r-project.org")
options(readr.show_col_types = FALSE)
for (thispack in packages) {
  library(thispack, character.only = TRUE, quietly = TRUE, verbose = FALSE)
}


# ── Disclosure control ────────────────────────────────────────────────────────
#
# EXTRACTED (nuisance parameters; appear in no decision rule)
#   between-participant SD of the per-participant breath-duration bias
#   within-participant SD of breath-level duration differences
#   between-participant SD of the per-participant breath-depth bias
#   between-participant SD of each breathing-variability measure
#   distribution of Block 4 trial counts
#   distribution of calibration fit, uncorrected AND lag-corrected
#   distribution of the belt-to-pacer offset
#   distribution of PER-DEVICE breath counts
#   frequency of each selected calibration model, and the winner's margin
#   alignment residual spread
#
# BLOCKED (effects; each appears in a confirmatory decision rule)
#   mean breath-duration bias                    -> H1 estimand
#   proportion of breaths matched between devices-> H2 test statistic
#   COUNT of matched breaths                     -> numerator of the above
#   onset timing difference                      -> H2 test statistic
#   any duration or depth error by imposed rate  -> H3 interaction
#   any error relative to the pacer              -> H4 estimand
#   any agreement coefficient (ICC, CCC, kappa)  -> H2, H5, H7
#   any pre-to-post change in agreement          -> H6 estimand
#   any alertness-adherence relationship         -> H8 estimand
#   any correlation whatsoever
#   any agreement quantity broken down by selected model -> EH3
#   any per-participant value or identifier
#
# Rationale for three non-obvious calls:
#   Calibration fit and the belt-to-pacer offset are EXTRACTED. Neither enters a
#   decision rule; both are preprocessing parameters the simulation needs, and
#   the offset distribution is separately required for the preregistered check.
#   Selected-model FREQUENCY is extracted; any agreement quantity split by model
#   is blocked, because that split is EH3's test.
#   Breath count is extracted PER DEVICE. The paired count is blocked: with
#   per-device counts also in hand it would give the match proportion directly.

WHITELIST <- c(
  "n_participants",
  "duration_bias_between_sd_ms",
  "duration_bias_between_sd_ms_naive",
  "duration_bias_between_sd_ms_moment",
  "duration_diff_within_sd_ms_reml",
  "duration_bias_between_sd_ms_upper95",
  "reml_diagnostics",
  "duration_diff_within_sd_ms",
  "depth_bias_between_sd_z",
  "variability_between_sd",
  "phase3_trial_count",
  "breath_count",
  "calibration_fit",
  "calibration_fit_lagadj",
  # Belt-to-pacer offset. NOT named *_pacer_* : BLOCKED_PATTERNS contains "r_",
  # which "pacer_offset" would match, and the wrong fix would be to weaken the
  # guard. See prereg Section 5.1.
  "belt_offset_ms",
  "selected_model_freq",
  "selected_model_margin",
  "alignment_residual_sd_ms",
  "provenance"
)

# Substrings that must never appear in an output name.
BLOCKED_PATTERNS <- c(
  "mean_bias", "bias_mean", "match", "f1", "onset_diff", "timing_diff",
  "icc", "ccc", "kappa", "cor", "corr", "r_", "_r$", "pacer_err",
  "adherence", "alertness", "by_rate", "by_model", "by_condition",
  "participant_id", "pid", "per_participant", "n_paired", "paired"
)


# ── Paths ─────────────────────────────────────────────────────────────────────
BASE_DIR   <- file.path("I:", "Shared drives", "Behavioral Interoception",
                        "Summer2026_CompareBelts")
DATA_DIR   <- file.path(BASE_DIR, "Data")
BT_DIR     <- file.path(DATA_DIR, "bt_physio")
OUTPUT_DIR <- file.path(BASE_DIR, "Analysis", "output")
PILOT_DIR  <- file.path(BASE_DIR, "Analysis", "pilot_variance")
dir.create(PILOT_DIR, recursive = TRUE, showWarnings = FALSE)

OUT_RDS    <- file.path(PILOT_DIR, "variance_components.rds")
OUT_REPORT <- file.path(PILOT_DIR, "variance_components_report.txt")

# THE SHARED DETECTOR. Sourced, never redefined here. See handoff Task 2.
source(file.path(BASE_DIR, "R", "onsets.R"))

# Participants forming the internal pilot. Fixed in advance, per Section 1.7 and
# docs/discrepancies.md D3: eighteen with an accel CSV, an ACQ file, Block 3 and
# Block 4 trial records, and a recorded phase3_end_ms. 998877 is a test account.
#
# DO NOT EXTEND THIS LIST after output has been seen. Participants recovered
# later join the CONFIRMATORY sample and contribute at the pre-specified interim
# re-estimation, not here.
PILOT_IDS <- c("3997", "9082", "9085", "13738", "14425", "14542", "14677",
               "14701", "16117", "16753", "16807", "17446", "17704", "17734",
               "17755", "17758", "17788", "17896")


# ── Constants ─────────────────────────────────────────────────────────────────
RESP_HZ            <- ONSET_HZ
MIN_BREATHS_BLOCK  <- 5L        # below this a block is not summarised
REQUIRED_CALIB_TARGET <- "pacer"


# ── Helpers ───────────────────────────────────────────────────────────────────

# Peak-to-trough amplitude per breath cycle, standardised within signal so that
# the two devices' incommensurable units can be compared.
.depths_z <- function(x, onsets) {
  if (length(onsets) < 2L) return(numeric(0))
  amp <- vapply(seq_len(length(onsets) - 1L), function(i) {
    seg <- x[onsets[i]:onsets[i + 1L]]
    if (length(seg) < 3L) return(NA_real_)
    max(seg) - min(seg)
  }, numeric(1))
  amp <- amp[is.finite(amp)]
  if (length(amp) < 2L || sd(amp) == 0) return(numeric(0))
  as.numeric(scale(amp))
}

# Breath-to-breath variability for one block.
#
# Sample entropy was dropped 2026-08-07: respkit does not provide it, thirty
# breaths is too short a basis for an entropy-type measure, and Section 5.7
# already treated it as secondary. H5 preregisters CV and RMSSD only.
.variability <- function(d) {
  if (length(d) < MIN_BREATHS_BLOCK) {
    return(c(cv = NA_real_, rmssd = NA_real_, sd_ms = NA_real_))
  }
  c(cv    = sd(d) / mean(d),
    rmssd = sqrt(mean(diff(d)^2)),
    sd_ms = sd(d))
}

.safe_num <- function(x) if (length(x) && is.finite(x)) as.numeric(x) else NA_real_


# ── Per-participant extraction ────────────────────────────────────────────────
#
# Returns a one-row private record. The caller aggregates and discards it.
# Blocked quantities are computed here only where a nuisance parameter requires
# them, and never leave this function.

.extract_one <- function(pid) {
  rds_path <- file.path(OUTPUT_DIR, paste0(pid, "_physio.rds"))
  if (!file.exists(rds_path)) {
    warning("No RDS for participant ", pid, "; skipped")
    return(NULL)
  }
  d <- readRDS(rds_path)

  # -- Guard: refuse circular-fit files -------------------------------------
  calib_target <- d$belt$calib_target
  if (is.null(calib_target)) {
    stop("Participant ", pid, ": RDS has no `belt$calib_target` field.\n",
         "  This file predates the corrected prep pipeline. Re-run preprocessing\n",
         "  with calibration weights fitted against the reconstructed pacer, and\n",
         "  record the target in `belt$calib_target`.")
  }
  if (!identical(calib_target, REQUIRED_CALIB_TARGET)) {
    stop("Participant ", pid, ": calibration fitted against '", calib_target,
         "', not '", REQUIRED_CALIB_TARGET, "'.\n",
         "  Weights fitted against the BioPac signal absorb participant-specific\n",
         "  variance and would understate the between-participant SD.")
  }

  grid <- d$belt$accel_grid

  # Both device signals, built by the SHARED code path from the raw axes and the
  # fitted weights. Neither is read from a pre-filtered column, so the detection
  # and measurement bands are the ones R/onsets.R preregisters.
  sig_belt   <- belt_signal_raw(d$belt)
  sig_biopac <- biopac_signal_raw(d$belt)

  # Belt-to-pacer offset, applied so that matching happens on corrected onsets
  # (prereg 5.4). Positive offset means the belt signal trails the pacer, so the
  # correction subtracts it.
  offset_s <- .safe_num(d$belt$belt_offset_ms) / 1000
  if (!is.finite(offset_s)) offset_s <- 0

  # -- Free-breathing windows from the raw accel phase labels ---------------
  accel_csv <- list.files(BT_DIR,
                          pattern = paste0("^", pid, "_session[0-9]+_accel[.]csv$"),
                          full.names = TRUE)
  if (!length(accel_csv)) {
    warning("No accel CSV for participant ", pid, "; skipped")
    return(NULL)
  }
  phase_bounds <- readr::read_csv(accel_csv[1], show_col_types = FALSE) |>
    dplyr::filter(phase %in% c("baseline", "post_baseline")) |>
    dplyr::group_by(phase) |>
    dplyr::summarise(t_min = min(packet_timestamp),
                     t_max = max(packet_timestamp),
                     .groups = "drop")

  # -- Windows -------------------------------------------------------------
  #
  # Four blocks, not two. Restricting this to free breathing left only 8 of 18
  # participants with a usable estimate, and it is the WORST case for matching:
  # the free blocks hold roughly 60 of ~196 breaths, and the pacer-symmetric
  # asymmetry offset (see scripts/00_calibrate_detector.R Part 1) is absent
  # there, so a systematic between-device onset offset survives the Block-1
  # correction. The paced blocks carry more than twice the breaths under a
  # symmetric pacer. Section 5.3 already specifies H1 as tested per block and
  # pooled.
  tt <- d$alignment$trial_table
  windows <- list()
  for (k in seq_len(nrow(phase_bounds)))
    windows[[length(windows) + 1]] <- list(
      block = phase_bounds$phase[k],
      t0 = phase_bounds$t_min[k], t1 = phase_bounds$t_max[k])

  if (!is.null(tt) && nrow(tt) && !is.null(tt$belt_onset_epoch_ms)) {
    # session_start is not stored directly; recover it from the pair that is.
    sess0 <- tt$belt_onset_epoch_ms - tt$belt_onset_ms
    t_end <- sess0 + tt$trial_end_ms
    for (k in seq_len(nrow(tt))) {
      ph <- tt$phase[k]
      lbl <- if (ph == 2 || ph == "2") "phase2" else
             if (ph == 3 || ph == "3") "phase3" else NA_character_
      if (is.na(lbl) || !is.finite(tt$belt_onset_epoch_ms[k]) ||
          !is.finite(t_end[k]) || t_end[k] <= tt$belt_onset_epoch_ms[k]) next
      windows[[length(windows) + 1]] <- list(
        block = lbl, t0 = tt$belt_onset_epoch_ms[k], t1 = t_end[k])
    }
  }

  # -- Detect ONCE on the continuous session, then assign onsets to windows --
  #
  # Detecting inside each window instead would filter 16 s trial segments, where
  # the 0.05 Hz corner has a 20 s period and reflection padding cannot rescue it,
  # and would give every free block its own edge transient. One pass over the
  # continuous signal avoids both.
  det_belt   <- detect_breaths(sig_belt,   RESP_HZ)
  det_biopac <- detect_breaths(sig_biopac, RESP_HZ)
  ep_belt    <- grid$epoch_ms[det_belt$onset_idx]   / 1000 - offset_s
  ep_biopac  <- grid$epoch_ms[det_biopac$onset_idx] / 1000

  # Accumulate matched duration pairs per BLOCK, pooling across that block's
  # windows. A paced trial is only 4 breaths, so per-trial summarising would
  # exclude every one of them under MIN_BREATHS_BLOCK.
  acc <- list()
  for (w in windows) {
    ib <- which(ep_belt   >= w$t0 / 1000 & ep_belt   <= w$t1 / 1000)
    jb <- which(ep_biopac >= w$t0 / 1000 & ep_biopac <= w$t1 / 1000)
    if (length(ib) < 2L || length(jb) < 2L) next

    on_belt   <- ep_belt[ib]
    on_biopac <- ep_biopac[jb]

    # C2: tolerance-window matching, not rank position. 500 ms is H1's
    # bookkeeping window; see the rationale block in R/onsets.R.
    mt <- match_onsets(on_belt, on_biopac, H1_MATCH_TOLERANCE_MS)

    # Durations of MATCHED breaths.
    #
    # A breath contributes only when BOTH devices resolve BOTH of its ends: the
    # opening onset and the closing onset are each a matched pair, and each is
    # adjacent in its own device's onset sequence.
    #
    # The permissive alternative, taking each device's own next onset without
    # requiring it to be matched, was tried and rejected. It admits DETECTION
    # MISSES as though they were duration disagreements: if one device misses the
    # closing onset, its "duration" spans two breaths and contributes an error of
    # a full breath period. Measured consequence, same data: the within-
    # participant SD of the difference rose from 314 ms to 1460 ms, against a
    # breath period of roughly 4000 ms. That is a detection statistic wearing a
    # duration statistic's clothes, and detection is H2's question, not H1's.
    #
    # The cost is real and is reported: this rule is why only some participants
    # contribute a usable free-breathing block.
    dur_belt   <- numeric(0); dur_biopac <- numeric(0)
    if (length(mt$a_idx) >= 2L) {
      ab <- on_belt[mt$a_idx]; bb <- on_biopac[mt$b_idx]
      consecutive <- which(diff(mt$a_idx) == 1L & diff(mt$b_idx) == 1L)
      if (length(consecutive)) {
        da <- diff(ab)[consecutive] * 1000
        db <- diff(bb)[consecutive] * 1000
        keep <- da >= ONSET_MIN_BREATH_MS & da <= ONSET_MAX_BREATH_MS &
                db >= ONSET_MIN_BREATH_MS & db <= ONSET_MAX_BREATH_MS
        dur_belt <- da[keep]; dur_biopac <- db[keep]
      }
    }
    if (!length(dur_belt)) next

    b <- w$block
    if (is.null(acc[[b]])) acc[[b]] <- list(diff = numeric(0), dur_b = numeric(0),
                                            i_belt = integer(0), j_biopac = integer(0))
    acc[[b]]$diff     <- c(acc[[b]]$diff, dur_belt - dur_biopac)
    acc[[b]]$i_belt   <- c(acc[[b]]$i_belt, ib)
    acc[[b]]$j_biopac <- c(acc[[b]]$j_biopac, jb)
  }
  if (!length(acc)) return(NULL)

  # Depth and variability stay on the FREE blocks only. Depth in a paced block is
  # constrained by the pacer, and prereg Section 5.7 restricts the variability
  # measures to free breathing for the same reason.
  free_idx <- function(dev_ep, w) which(dev_ep >= w$t0 / 1000 & dev_ep <= w$t1 / 1000)
  dep_diffs <- numeric(0); var_b <- list(); n_dev_free <- 0
  for (w in windows) {
    if (!w$block %in% c("baseline", "post_baseline")) next
    ib <- free_idx(ep_belt, w); jb <- free_idx(ep_biopac, w)
    if (length(ib) < MIN_BREATHS_BLOCK || length(jb) < MIN_BREATHS_BLOCK) next
    dep_belt   <- .depths_z(det_belt$measure,   det_belt$onset_idx[ib])
    dep_biopac <- .depths_z(det_biopac$measure, det_biopac$onset_idx[jb])
    n_dep <- min(length(dep_belt), length(dep_biopac))
    if (n_dep >= MIN_BREATHS_BLOCK)
      dep_diffs <- c(dep_diffs,
                     mean(dep_belt[seq_len(n_dep)] - dep_biopac[seq_len(n_dep)]))
    var_b[[length(var_b) + 1]] <- .variability(durations_ms(ep_belt[ib]))
    n_dev_free <- n_dev_free + mean(c(length(ib), length(jb)))
  }

  block_records <- lapply(acc, function(a) list(
    # BLOCKED beyond this function: the raw breath-level differences and the
    # participant-level mean. Both are retained only so the caller can fit ONE
    # variance-components model across participants and keep its variances.
    # The model's fixed intercept is the H1 estimand and is discarded there.
    dur_diff_raw  = if (length(a$diff) >= MIN_BREATHS_BLOCK) a$diff else numeric(0),
    dur_diff_mean = if (length(a$diff) >= MIN_BREATHS_BLOCK) mean(a$diff) else NA_real_,
    dur_diff_sd   = if (length(a$diff) >= MIN_BREATHS_BLOCK) sd(a$diff)   else NA_real_,
    # BLOCKED beyond this function: the count of matched breaths is the
    # numerator of H2's match proportion. Used only to weight the C1
    # correction, never reported.
    n_paired      = length(a$diff)
  ))

  vmean <- function(nm) {
    v <- vapply(var_b, function(z) unname(z[nm]), numeric(1))
    v <- v[is.finite(v)]
    if (!length(v)) NA_real_ else mean(v)
  }

  wmean <- function(f) {
    v <- vapply(block_records, f, numeric(1))
    v <- v[is.finite(v)]
    if (!length(v)) NA_real_ else mean(v)
  }

  # D4: the RDS trial table may code phase as integer or string. Check both
  # rather than assuming, per docs/discrepancies.md D4.
  n_phase3 <- if (!is.null(d$alignment$trial_table$phase)) {
    p <- d$alignment$trial_table$phase
    sum(p == 3 | p == "3" | p == "phase3", na.rm = TRUE)
  } else NA_integer_

  list(
    dur_diff_raw    = unlist(lapply(block_records, function(b) b$dur_diff_raw),
                             use.names = FALSE),
    dur_diff_mean   = wmean(function(b) b$dur_diff_mean),
    dur_diff_sd     = wmean(function(b) b$dur_diff_sd),
    n_paired        = sum(vapply(block_records, function(b) b$n_paired, numeric(1))),
    n_blocks_used   = sum(vapply(block_records,
                                 function(b) is.finite(b$dur_diff_sd), logical(1))),
    dep_diff_mean   = if (length(dep_diffs)) mean(dep_diffs) else NA_real_,
    n_device        = n_dev_free,
    var_cv          = vmean("cv"),
    var_rmssd       = vmean("rmssd"),
    var_sd_ms       = vmean("sd_ms"),
    n_phase3        = n_phase3,
    calib_fit       = .safe_num(d$belt$mlr_r_calib),
    calib_fit_lc    = .safe_num(d$belt$mlr_r_calib_lagcorr),   # C5
    model_margin    = .safe_num(d$belt$model_margin),          # C6
    lag_ms          = .safe_num(d$belt$belt_offset_ms),
    selected_model  = if (!is.null(d$belt$calib_model_label))
                        as.character(d$belt$calib_model_label) else NA_character_,
    align_resid_sd  = .safe_num(d$alignment$residual_sd_ms)
  )
}


# ── Aggregate ─────────────────────────────────────────────────────────────────

if (!length(PILOT_IDS)) {
  stop("PILOT_IDS is empty. Fix the pilot sample in the pre-registration, then set it here.")
}

message("Extracting variance components from ", length(PILOT_IDS), " participants...")

recs <- lapply(PILOT_IDS, function(p) {
  tryCatch(.extract_one(p),
           error = function(e) { message("[", p, "] FAILED: ", conditionMessage(e)); NULL })
})
recs <- recs[!vapply(recs, is.null, logical(1))]
n_ok <- length(recs)
if (n_ok < 5L) stop("Only ", n_ok, " participants extracted; too few to estimate variance.")

pull <- function(f) vapply(recs, function(r) .safe_num(r[[f]]), numeric(1))

# Distribution summary that reveals spread and shape but not a mean.
.dist <- function(v) {
  v <- v[is.finite(v)]
  if (!length(v)) return(NULL)
  c(n = length(v),
    min = min(v),
    q25 = unname(quantile(v, .25)),
    median = median(v),
    q75 = unname(quantile(v, .75)),
    max = max(v),
    sd = sd(v))
}

# ── C1: correct the between-participant SD ────────────────────────────────────
#
# sd() of the observed per-participant means estimates
#
#     Var(observed means) = sigma^2_between + sigma^2_within / k
#
# not sigma^2_between, where k is that participant's paired breath count. Since
# the required N scales with the variance, the inflation is SQUARED in the
# sample size. Both terms are already whitelisted, so the correction discloses
# nothing new. Approved by Norm 2026-07-31; docs/discrepancies.md C1.
#
# n_paired stays inside this calculation and is not reported: it is the
# numerator of H2's blocked match proportion.
.between_sd_corrected <- function(means, within_sds, ks) {
  ok <- is.finite(means) & is.finite(within_sds) & is.finite(ks) & ks > 1
  if (sum(ok) < 3L) return(NA_real_)
  s2_obs    <- stats::var(means[ok])
  s2_within <- mean(within_sds[ok]^2 / ks[ok])
  sqrt(max(0, s2_obs - s2_within))
}

# REML is the estimator of record. The method-of-moments correction above is
# retained only as a cross-check.
#
# On this pilot the moment correction hit the LOWER BOUNDARY: the observed
# spread of participant means was fully explained by within-participant sampling
# noise, so `max(0, .)` returned exactly zero and no sample size could be
# computed from it. That is a known weakness of subtracting one variance
# estimate from another, not a finding about the data.
#
# A random-intercept model estimates the same two components jointly and handles
# the boundary properly. Fitted on the pooled BREATH-LEVEL differences:
#
#     difference ~ 1 + (1 | participant)
#
#   random intercept SD -> between-participant SD of the per-participant bias
#   residual SD         -> within-participant SD of breath-level differences
#
# DISCLOSURE: the fixed intercept of this model IS the mean breath-duration
# bias, i.e. H1's estimand, and is BLOCKED. It is never returned, never printed,
# and the fitted object is destroyed inside this function. Only the two variance
# components leave. This mirrors how prereg Section 5.1 handles the intercept of
# the belt-to-pacer offset decomposition.
.between_sd_reml <- function(recs) {
  if (!requireNamespace("lme4", quietly = TRUE))
    return(c(between = NA_real_, within = NA_real_, n_obs = NA_real_,
             n_part = NA_real_))

  dat <- do.call(rbind, lapply(seq_along(recs), function(i) {
    v <- recs[[i]]$dur_diff_raw
    v <- v[is.finite(v)]
    if (length(v) < MIN_BREATHS_BLOCK) return(NULL)
    data.frame(d = v, g = factor(i))
  }))
  if (is.null(dat) || nlevels(dat$g) < 3L)
    return(c(between = NA_real_, within = NA_real_, n_obs = NA_real_,
             n_part = NA_real_))

  fit <- try(suppressMessages(
    lme4::lmer(d ~ 1 + (1 | g), data = dat, REML = TRUE)), silent = TRUE)
  if (inherits(fit, "try-error"))
    return(c(between = NA_real_, within = NA_real_, between_hi = NA_real_,
             singular = NA_real_, n_obs = nrow(dat), n_part = nlevels(dat$g)))

  vc      <- as.data.frame(lme4::VarCorr(fit))
  between <- as.numeric(vc$sdcor[vc$grp == "g"])[1]
  within  <- as.numeric(vc$sdcor[vc$grp == "Residual"])[1]
  sing    <- as.numeric(lme4::isSingular(fit))
  n_obs   <- nrow(dat); n_part <- nlevels(dat$g)

  # UPPER CONFIDENCE BOUND on the between-participant SD.
  #
  # This is the number the power analysis uses, not the point estimate. A
  # variance component estimated at the boundary is the MOST OPTIMISTIC possible
  # value: zero between-participant variance means H1's participant-level mean is
  # estimated with maximum precision and the required N is minimised. The
  # handoff is explicit that an understated between-participant SD yields an
  # optimistically small sample size, so powering on a boundary estimate would be
  # exactly the error it warns against.
  #
  # Profiling only the random-effects parameters keeps the fixed intercept, which
  # is H1's blocked estimand, out of the computation entirely.
  hi <- try(suppressWarnings(suppressMessages(
    stats::confint(fit, parm = "theta_", method = "profile", level = 0.95,
                   oldNames = FALSE))), silent = TRUE)
  between_hi <- if (inherits(hi, "try-error")) NA_real_ else {
    r <- grep("^sd_\\(Intercept\\)\\|g$", rownames(hi))
    if (length(r)) as.numeric(hi[r[1], 2]) else as.numeric(hi[1, 2])
  }

  # Destroy everything carrying the intercept before returning.
  rm(fit, vc, dat, hi)

  c(between = between, within = within, between_hi = between_hi,
    singular = sing, n_obs = n_obs, n_part = n_part)
}

dur_means <- pull("dur_diff_mean")
dur_sds   <- pull("dur_diff_sd")
dur_ks    <- pull("n_paired")

reml <- .between_sd_reml(recs)

out <- list(
  n_participants = n_ok,

  # THE key parameter. REML on the pooled breath-level differences; see
  # .between_sd_reml. The MEAN of the per-participant biases is the H1 estimand
  # and is discarded inside that function.
  duration_bias_between_sd_ms = .safe_num(reml[["between"]]),

  # THE number the power analysis uses. See .between_sd_reml: a boundary
  # estimate is the most optimistic possible value, and powering on it is the
  # error the handoff warns against.
  duration_bias_between_sd_ms_upper95 = .safe_num(reml[["between_hi"]]),

  reml_diagnostics = c(singular = .safe_num(reml[["singular"]]),
                       n_obs    = .safe_num(reml[["n_obs"]]),
                       n_part   = .safe_num(reml[["n_part"]])),

  # Method-of-moments cross-checks, both whitelisted. `naive` is the raw SD of
  # participant means, inflated by within-participant sampling variance. `moment`
  # is the C1 correction, which can and on this pilot did hit zero.
  duration_bias_between_sd_ms_naive =
    .safe_num(sd(dur_means, na.rm = TRUE)),
  duration_bias_between_sd_ms_moment =
    .safe_num(.between_sd_corrected(dur_means, dur_sds, dur_ks)),

  # Within-participant noise, from the same REML fit, plus the per-participant
  # distribution for context.
  duration_diff_within_sd_ms_reml = .safe_num(reml[["within"]]),
  duration_diff_within_sd_ms  = .dist(dur_sds),

  depth_bias_between_sd_z     = .safe_num(sd(pull("dep_diff_mean"), na.rm = TRUE)),

  variability_between_sd = c(
    cv    = .safe_num(sd(pull("var_cv"),    na.rm = TRUE)),
    rmssd = .safe_num(sd(pull("var_rmssd"), na.rm = TRUE)),
    sd_ms = .safe_num(sd(pull("var_sd_ms"), na.rm = TRUE))
  ),

  phase3_trial_count       = .dist(pull("n_phase3")),
  breath_count             = .dist(pull("n_device")),      # PER DEVICE, not paired
  calibration_fit          = .dist(pull("calib_fit")),
  calibration_fit_lagadj  = .dist(pull("calib_fit_lc")),  # C5
  selected_model_margin    = .dist(pull("model_margin")),  # C6
  belt_offset_ms           = .dist(pull("lag_ms")),
  alignment_residual_sd_ms = .dist(pull("align_resid_sd")),

  selected_model_freq = table(vapply(recs, function(r) {
    m <- r$selected_model; if (is.null(m) || is.na(m)) "unknown" else m
  }, character(1))),

  provenance = list(
    extracted_at   = as.character(Sys.time()),
    n_requested    = length(PILOT_IDS),
    n_extracted    = n_ok,
    calib_target   = REQUIRED_CALIB_TARGET,
    detector       = "R/onsets.R (respkit snapshot)",
    detect_band    = paste(ONSET_DETECT_BAND, collapse = "-"),
    measure_band   = paste(ONSET_MEASURE_BAND, collapse = "-"),
    min_prominence = ONSET_MIN_PROMINENCE,
    h1_tolerance_ms = H1_MATCH_TOLERANCE_MS,
    script         = "02_estimate_variance_components.R"
  )
)

# Per-participant biases and all paired counts are discarded here. Nothing
# downstream can recover them.
rm(recs, dur_means, dur_sds, dur_ks, reml)


# ── Enforcement ───────────────────────────────────────────────────────────────

extra <- setdiff(names(out), WHITELIST)
if (length(extra)) {
  stop("Output contains non-whitelisted entries: ", paste(extra, collapse = ", "),
       "\n  Add them to WHITELIST only after confirming they appear in no decision rule.")
}

flat_names <- unlist(lapply(names(out), function(nm) {
  el <- out[[nm]]
  if (is.null(names(el))) nm else paste(nm, names(el), sep = ".")
}))
hits <- flat_names[vapply(flat_names, function(nm) {
  any(vapply(BLOCKED_PATTERNS, function(p) grepl(p, tolower(nm)), logical(1)))
}, logical(1))]
hits <- setdiff(hits, c("provenance.script", "provenance.detector",
                        "provenance.detect_band", "provenance.measure_band",
                        "provenance.min_prominence", "provenance.h1_tolerance_ms"))
if (length(hits)) {
  stop("Output names match blocked patterns: ", paste(hits, collapse = ", "))
}

# A boundary estimate is a legitimate result, not a crash. It says the observed
# spread of participant means is fully explained by within-participant sampling
# noise. The report must still be written, because the UPPER BOUND is what the
# power analysis consumes and it stays usable when the point estimate is zero.
# The run fails only if BOTH are unusable.
if (!is.finite(out$duration_bias_between_sd_ms_upper95) ||
    out$duration_bias_between_sd_ms_upper95 <= 0) {
  stop("Between-participant SD has no usable upper bound: both the point\n",
       "  estimate and its 95% profile bound failed. Inspect preprocessing,\n",
       "  not this output.")
}
if (!is.finite(out$duration_bias_between_sd_ms) ||
    out$duration_bias_between_sd_ms <= 0) {
  warning("Between-participant SD estimated at the BOUNDARY (zero).\n",
          "  The power analysis must use the upper bound, not this point\n",
          "  estimate: zero between-participant variance is the most optimistic\n",
          "  possible value and would minimise the required N.", call. = FALSE)
}


# ── Write ─────────────────────────────────────────────────────────────────────

saveRDS(out, OUT_RDS)

sink(OUT_REPORT)
cat("BreathBelt internal pilot: variance components\n")
cat("Extracted:", out$provenance$extracted_at, "\n")
cat("Participants:", out$n_participants, "of", out$provenance$n_requested, "requested\n")
cat("Calibration target:", out$provenance$calib_target, "\n")
cat("Detector:", out$provenance$detector, "\n")
cat("  detect band", out$provenance$detect_band, "Hz | measure band",
    out$provenance$measure_band, "Hz | min prominence",
    out$provenance$min_prominence, "\n")
cat("  H1 matching tolerance:", out$provenance$h1_tolerance_ms, "ms\n\n")

cat("Between-participant SD of breath-duration bias (ms)\n")
cat("  REML point    :", round(out$duration_bias_between_sd_ms, 1), "\n")
cat("  naive SD      :", round(out$duration_bias_between_sd_ms_naive, 1),
    "  (inflated by within-participant sampling variance)\n")
cat("  moment (C1)   :", round(out$duration_bias_between_sd_ms_moment, 1),
    "  (subtraction estimator; truncates at zero)\n")
cat("  REML upper 95%:", round(out$duration_bias_between_sd_ms_upper95, 1),
    "  <- POWER ANALYSIS USES THIS\n")
cat("  REML singular:", isTRUE(out$reml_diagnostics[["singular"]] == 1),
    "| breath-level obs:", out$reml_diagnostics[["n_obs"]],
    "| participants in fit:", out$reml_diagnostics[["n_part"]], "\n")
if (isTRUE(out$reml_diagnostics[["singular"]] == 1)) {
  cat("\n  NOTE: between-participant variance is estimated at ZERO. The observed\n")
  cat("  spread of participant mean biases is fully explained by within-\n")
  cat("  participant sampling noise. That is the MOST OPTIMISTIC value possible,\n")
  cat("  so the power analysis uses the upper bound above. Duration is a timing\n")
  cat("  quantity and, unlike amplitude, has no obvious route by which body\n")
  cat("  habitus or strap placement would make it differ between people, so a\n")
  cat("  small true value is plausible rather than suspicious.\n\n")
}
cat("Within-participant SD of breath-level differences (ms)\n")
cat("  REML residual :", round(out$duration_diff_within_sd_ms_reml, 1), "\n")
cat("Between-participant SD of breath-depth bias (z):",
    round(out$depth_bias_between_sd_z, 3), "\n\n")
cat("Variability measures, between-participant SD (CV and RMSSD only;\n")
cat("sample entropy dropped, see prereg Section 5.7):\n")
print(round(out$variability_between_sd, 4))
cat("\nDistributions:\n")
for (nm in c("duration_diff_within_sd_ms", "phase3_trial_count", "breath_count",
             "calibration_fit", "calibration_fit_lagadj", "selected_model_margin",
             "belt_offset_ms", "alignment_residual_sd_ms")) {
  cat("\n", nm, "\n", sep = "")
  print(round(out[[nm]], 3))
}
cat("\nSelected calibration model:\n")
print(out$selected_model_freq)
cat("\nbreath_count is PER DEVICE, averaged over the two. The count of MATCHED\n")
cat("breaths is blocked: it is the numerator of H2's match proportion.\n")
cat("\nNo effect-size quantity is reported. See disclosure control block in the script.\n")
sink()

message("Wrote: ", OUT_RDS)
message("Wrote: ", OUT_REPORT)
message("Done. Read the report; do not re-open participant RDS files by hand.")
