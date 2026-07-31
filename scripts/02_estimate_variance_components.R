# estimate_variance_components.R
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
#   Set PILOT_IDS, run. Output is a single RDS plus a plain-text report.
#   Do not run interactively and inspect intermediate objects. Run the script.
#
# DEPENDENCY
#   Requires RDS files produced by the CORRECTED prep pipeline, in which
#   calibration weights are fitted against the reconstructed pacer on the Phase 1
#   window. RDS files from the earlier pipeline fitted weights against the BioPac
#   signal, which shrinks between-participant variance in the bias and would
#   yield an optimistic sample size. The script hard-fails on those files.

# Set Up ---------
## Load libraries ---------
packages <- c(
  "tidyverse",
  "signal",
  "zoo"
)
new_packages <- packages[!sapply(packages, requireNamespace, quietly = TRUE)]
if (length(new_packages)) install.packages(new_packages)
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
#   distribution of Phase 3 trial counts
#   distribution of calibration fit
#   distribution of device lag
#   distribution of breath counts
#   frequency of each selected calibration model
#   alignment residual spread
#
# BLOCKED (effects; each appears in a confirmatory decision rule)
#   mean breath-duration bias                    -> H1 estimand
#   proportion of breaths matched between devices-> H2 test statistic
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
# Rationale for two non-obvious calls:
#   Calibration fit and device lag are EXTRACTED. Neither enters a decision rule;
#   both are preprocessing parameters the simulation needs, and the lag
#   distribution is separately required for the preregistered sanity check.
#   Selected-model FREQUENCY is extracted; any agreement quantity split by model
#   is blocked, because that split is EH3's test.

WHITELIST <- c(
  "n_participants",
  "duration_bias_between_sd_ms",
  "duration_diff_within_sd_ms",
  "depth_bias_between_sd_z",
  "variability_between_sd",
  "phase3_trial_count",
  "breath_count",
  "calibration_fit",
  "device_lag_ms",
  "selected_model_freq",
  "alignment_residual_sd_ms",
  "provenance"
)

# Substrings that must never appear in an output name.
BLOCKED_PATTERNS <- c(
  "mean_bias", "bias_mean", "match", "f1", "onset_diff", "timing_diff",
  "icc", "ccc", "kappa", "cor", "corr", "r_", "_r$", "pacer_err",
  "adherence", "alertness", "by_rate", "by_model", "by_condition",
  "participant_id", "pid", "per_participant"
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

# Participants forming the internal pilot. Fix this list BEFORE running and
# record it in the pre-registration. Do not extend it after seeing output.
PILOT_IDS <- c()   # e.g. c("14542", "14601", ...)


# ── Constants ─────────────────────────────────────────────────────────────────
RESP_HZ            <- 25L
MIN_BREATH_MS      <- 1500      # refractory period for onset detection
MAX_BREATH_MS      <- 12000     # implausible beyond this; dropped
SMOOTH_WIN_SAMP    <- 5L        # rolling median window for trough detection
MIN_BREATHS_BLOCK  <- 5L        # below this a block is not summarised
REQUIRED_CALIB_TARGET <- "pacer"


# ── Helpers ───────────────────────────────────────────────────────────────────

# Detect breath onsets as troughs in a filtered respiration signal.
# Returns sample indices. Enforces a refractory period so that noise ripples
# on the descending limb are not counted as separate breaths.
.detect_onsets <- function(x, hz = RESP_HZ) {
  if (length(x) < 3L * hz) return(integer(0))
  xs <- as.numeric(zoo::rollapply(x, width = SMOOTH_WIN_SAMP, FUN = median,
                                  fill = "extend", align = "center"))
  n  <- length(xs)
  is_trough <- c(FALSE, xs[2:(n - 1)] < xs[1:(n - 2)] &
                        xs[2:(n - 1)] <= xs[3:n], FALSE)
  cand <- which(is_trough)
  if (!length(cand)) return(integer(0))

  refractory <- round(MIN_BREATH_MS / 1000 * hz)
  keep <- cand[1]
  for (i in cand[-1]) {
    if (i - keep[length(keep)] >= refractory) {
      keep <- c(keep, i)
    } else if (xs[i] < xs[keep[length(keep)]]) {
      keep[length(keep)] <- i   # deeper trough wins within the refractory window
    }
  }
  keep
}

# Breath durations (ms) from onset indices, with implausible values removed.
.durations_ms <- function(onsets, hz = RESP_HZ) {
  if (length(onsets) < 2L) return(numeric(0))
  d <- diff(onsets) / hz * 1000
  d[d >= MIN_BREATH_MS & d <= MAX_BREATH_MS]
}

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

# Breath-to-breath variability descriptors for one block.
.variability <- function(d) {
  if (length(d) < MIN_BREATHS_BLOCK) {
    return(c(cv = NA_real_, rmssd = NA_real_, sd_ms = NA_real_))
  }
  c(
    cv    = sd(d) / mean(d),
    rmssd = sqrt(mean(diff(d)^2)),
    sd_ms = sd(d)
  )
}

# Pair two duration series by rank position, truncating to the shorter.
# Deliberately NOT a temporal match: temporal matching is H2's test procedure,
# and running it here would expose a blocked quantity.
.pair_by_position <- function(a, b) {
  n <- min(length(a), length(b))
  if (n < MIN_BREATHS_BLOCK) return(NULL)
  data.frame(a = a[seq_len(n)], b = b[seq_len(n)])
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

  # -- Free-breathing windows from the raw accel phase labels ---------------
  accel_csv <- list.files(BT_DIR,
                          pattern = paste0("^", pid, "_session\\d+_accel\\.csv$"),
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

  block_records <- list()
  for (k in seq_len(nrow(phase_bounds))) {
    ph   <- phase_bounds$phase[k]
    mask <- grid$epoch_ms >= phase_bounds$t_min[k] &
            grid$epoch_ms <= phase_bounds$t_max[k]
    if (sum(mask) < 10L * RESP_HZ) next

    belt_sig   <- grid$mlr_lp[mask]
    biopac_sig <- grid$biopac_breath[mask]

    on_belt   <- .detect_onsets(belt_sig)
    on_biopac <- .detect_onsets(biopac_sig)

    dur_belt   <- .durations_ms(on_belt)
    dur_biopac <- .durations_ms(on_biopac)

    dep_belt   <- .depths_z(belt_sig,   on_belt)
    dep_biopac <- .depths_z(biopac_sig, on_biopac)

    pair_dur <- .pair_by_position(dur_belt, dur_biopac)
    pair_dep <- .pair_by_position(dep_belt, dep_biopac)

    block_records[[ph]] <- list(
      # BLOCKED beyond this function: participant-level mean difference.
      # Retained only so the caller can take its SD across participants.
      dur_diff_mean = if (!is.null(pair_dur)) mean(pair_dur$a - pair_dur$b) else NA_real_,
      dur_diff_sd   = if (!is.null(pair_dur)) sd(pair_dur$a - pair_dur$b)   else NA_real_,
      dep_diff_mean = if (!is.null(pair_dep)) mean(pair_dep$a - pair_dep$b) else NA_real_,
      n_breaths     = if (!is.null(pair_dur)) nrow(pair_dur) else 0L,
      var_belt      = .variability(dur_belt),
      var_biopac    = .variability(dur_biopac)
    )
  }
  if (!length(block_records)) return(NULL)

  wmean <- function(f) {
    v <- vapply(block_records, f, numeric(1))
    v <- v[is.finite(v)]
    if (!length(v)) NA_real_ else mean(v)
  }

  n_phase3 <- if (!is.null(d$alignment$trial_table)) {
    sum(d$alignment$trial_table$phase == 3, na.rm = TRUE)
  } else NA_integer_

  list(
    dur_diff_mean   = wmean(function(b) b$dur_diff_mean),
    dur_diff_sd     = wmean(function(b) b$dur_diff_sd),
    dep_diff_mean   = wmean(function(b) b$dep_diff_mean),
    n_breaths       = sum(vapply(block_records, function(b) b$n_breaths, numeric(1))),
    var_cv          = wmean(function(b) unname(b$var_belt["cv"])),
    var_rmssd       = wmean(function(b) unname(b$var_belt["rmssd"])),
    var_sd_ms       = wmean(function(b) unname(b$var_belt["sd_ms"])),
    n_phase3        = n_phase3,
    calib_fit       = .safe_num(d$belt$mlr_r_calib),
    lag_ms          = .safe_num(d$belt$calib_lag_ms),
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

recs <- lapply(PILOT_IDS, .extract_one)
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

out <- list(
  n_participants = n_ok,

  # THE key parameter. SD across participants of each person's own mean bias.
  # The mean of those biases is the H1 estimand and is not computed here.
  duration_bias_between_sd_ms = .safe_num(sd(pull("dur_diff_mean"), na.rm = TRUE)),

  # Within-participant noise. Minor driver of power; needed for realistic simulation.
  duration_diff_within_sd_ms  = .dist(pull("dur_diff_sd")),

  depth_bias_between_sd_z     = .safe_num(sd(pull("dep_diff_mean"), na.rm = TRUE)),

  variability_between_sd = c(
    cv    = .safe_num(sd(pull("var_cv"),    na.rm = TRUE)),
    rmssd = .safe_num(sd(pull("var_rmssd"), na.rm = TRUE)),
    sd_ms = .safe_num(sd(pull("var_sd_ms"), na.rm = TRUE))
  ),

  phase3_trial_count       = .dist(pull("n_phase3")),
  breath_count             = .dist(pull("n_breaths")),
  calibration_fit          = .dist(pull("calib_fit")),
  device_lag_ms            = .dist(pull("lag_ms")),
  alignment_residual_sd_ms = .dist(pull("align_resid_sd")),

  selected_model_freq = table(vapply(recs, function(r) {
    m <- r$selected_model; if (is.null(m) || is.na(m)) "unknown" else m
  }, character(1))),

  provenance = list(
    extracted_at   = as.character(Sys.time()),
    n_requested    = length(PILOT_IDS),
    n_extracted    = n_ok,
    calib_target   = REQUIRED_CALIB_TARGET,
    script         = "estimate_variance_components.R"
  )
)

# Per-participant biases are discarded here. Nothing downstream can recover them.
rm(recs)


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
hits <- setdiff(hits, c("provenance.script"))
if (length(hits)) {
  stop("Output names match blocked patterns: ", paste(hits, collapse = ", "))
}

if (!is.finite(out$duration_bias_between_sd_ms) ||
    out$duration_bias_between_sd_ms <= 0) {
  stop("Between-participant SD is not usable. Inspect preprocessing, not this output.")
}


# ── Write ─────────────────────────────────────────────────────────────────────

saveRDS(out, OUT_RDS)

sink(OUT_REPORT)
cat("BreathBelt internal pilot: variance components\n")
cat("Extracted:", out$provenance$extracted_at, "\n")
cat("Participants:", out$n_participants, "of", out$provenance$n_requested, "requested\n")
cat("Calibration target:", out$provenance$calib_target, "\n\n")
cat("Between-participant SD of breath-duration bias (ms):",
    round(out$duration_bias_between_sd_ms, 1), "\n")
cat("Between-participant SD of breath-depth bias (z):",
    round(out$depth_bias_between_sd_z, 3), "\n\n")
cat("Variability measures, between-participant SD:\n")
print(round(out$variability_between_sd, 4))
cat("\nDistributions:\n")
for (nm in c("duration_diff_within_sd_ms", "phase3_trial_count", "breath_count",
             "calibration_fit", "device_lag_ms", "alignment_residual_sd_ms")) {
  cat("\n", nm, "\n", sep = "")
  print(round(out[[nm]], 3))
}
cat("\nSelected calibration model:\n")
print(out$selected_model_freq)
cat("\nNo effect-size quantity is reported. See disclosure control block in the script.\n")
sink()

message("Wrote: ", OUT_RDS)
message("Wrote: ", OUT_REPORT)
message("Done. Read the report; do not re-open participant RDS files by hand.")
