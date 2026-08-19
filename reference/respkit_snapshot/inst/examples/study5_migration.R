# =====================================================================
#  study5_migration.R
#
#  The Study 5 respiration workflow rewritten with respkit, as a worked
#  example of porting an existing pipeline.
#
#  The original chain was:
#
#    Intero2025_BeltQualityScreen.R      .acq -> quality CSV + rds/<id>.rds
#    Intero2025_TrimContaminatedPhysio.R trims contaminated rds in place
#    Intero2025_BehaviourLedBreathAnalysis.R  per-trial detection + features
#    Intero2025_BreathingAdherence.R     per-trial IBI slope + adherence
#
#  Steps 1, 3 and 4 collapse into this file. Step 2 is study-specific
#  (recovering from a BIOPAC template that was not cleared between
#  participants) and stays in the study repository; note only that respkit's
#  reader is non-destructive, so a trim should write a new file rather than
#  overwriting the source, and should be recorded in provenance.
# =====================================================================

## ---- setup -----------------------------------------------------------
# library(respkit)
for (f in list.files("R", "[.]R$", full.names = TRUE)) source(f)

RDS_DIR   <- "Results/rds"
OUT_DIR   <- "Results/respkit"
LAG       <- 0.2      # belt transduction latency, seconds
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

# Behavioural trial table: id, ses, trial, condition, trial.started,
# trial.stopped, and the session onset in recording seconds.
trials <- read.csv("Results/dataFile.csv")
onsets <- read.csv("Results/session_onsets.csv")   # id, ses, onset_s

exclude_ids <- c(1234, 5678, 99998, 99999)


## ---- per-participant processing ---------------------------------------
process_one <- function(id) {

  rds <- file.path(RDS_DIR, paste0(id, ".rds"))
  if (!file.exists(rds)) return(NULL)

  # Legacy files are converted and their sampling rate corrected. The old
  # files claim 25 Hz; the signal is at 2000/78 = 25.641 Hz.
  rec <- resp_read_rds(rds)

  # Quality screen. This replaces Intero2025_BeltQualityScreen.R, and adds
  # saturation and segment-wise verdicts.
  q <- resp_quality(rec, trim_s = 120, by_segment = TRUE)
  if (identical(q$quality, "unusable")) {
    message(id, ": unusable belt (", q$note, ") — features will be NA")
  }

  # Build the trial windows. The original added LAG inside the loop for
  # every trial; here it is one argument to one call.
  tr <- trials[trials$id == id, ]
  if (!nrow(tr)) return(NULL)
  on <- onsets[onsets$id == id, ]
  tr <- merge(tr, on[, c("ses", "onset_s")], by = "ses")

  eps <- resp_epochs(
    onset    = tr$onset_s + tr$trial.started,
    offset   = tr$onset_s + tr$trial.stopped,
    lag      = LAG,
    label    = paste0("s", tr$ses, "_t", tr$trial),
    id       = id,
    ses      = tr$ses,
    trial    = tr$trial,
    condition = tr$condition
  )

  # Detection and features. detect_band/measure_band default to 0.05-0.6 and
  # 0.05-2 Hz; the original used a single 0.05-0.4 Hz band for both, which
  # biases peak timing on asymmetric breaths (see README, defect 3).
  res <- resp_analyse(
    rec,
    target_fs      = 25,
    min_prominence = 0.4,
    min_distance_s = 1.5,
    epochs         = eps,
    epoch_rule     = "start",
    epoch_pad_s    = 0.5,
    quality        = FALSE          # already computed above
  )

  # Attach the participant-level quality verdict to every trial row.
  feats <- res$features
  feats$belt_quality <- q$quality
  feats$belt_note    <- q$note

  list(features = feats, breaths = res$breaths, quality = q, result = res)
}


## ---- run ---------------------------------------------------------------
ids <- setdiff(unique(trials$id), exclude_ids)
all_out <- lapply(ids, function(id)
  tryCatch(process_one(id),
           error = function(e) { message(id, ": FAILED — ", conditionMessage(e)); NULL }))
names(all_out) <- ids
all_out <- all_out[!vapply(all_out, is.null, logical(1))]

trial_features <- do.call(rbind, lapply(all_out, `[[`, "features"))
write.csv(trial_features, file.path(OUT_DIR, "trial_features.csv"), row.names = FALSE)

breath_level <- do.call(rbind, Map(function(o, id) {
  b <- o$breaths; if (!nrow(b)) return(NULL); b$id <- id; b
}, all_out, names(all_out)))
write.csv(breath_level, file.path(OUT_DIR, "breath_level.csv"), row.names = FALSE)


## ---- screening ---------------------------------------------------------
# The honest replacement for padding a trial out to the expected breath
# count: keep windows that were actually measured.
usable <- subset(trial_features,
                 belt_quality != "unusable" & coverage_frac >= 0.7 & n_breaths >= 2)

message(sprintf("%d of %d trials usable (%.1f%%)",
                nrow(usable), nrow(trial_features),
                100 * nrow(usable) / nrow(trial_features)))


## ---- reproducing the original's adherence metric -----------------------
# Intero2025_BreathingAdherence.R computed `ibi_slope`: an OLS slope of
# inter-trough interval on ordinal breath position, per trial. That is
# `duration_slope_per_breath` here, computed in closed form.
#
# Its companion `direction_match` coded missing data and genuine NoChange
# trials both as 0, so trials with too few troughs entered the pct_match
# denominator as neither a match nor a mismatch and deflated both
# percentages. Keep the two distinct:
adherence <- within(usable, {
  direction_match <- ifelse(
    is.na(duration_slope_per_breath), NA_integer_,        # not measured
    ifelse(change == 0, 0L,                               # genuine no-change
           ifelse(sign(duration_slope_per_breath) == sign(change), 1L, -1L)))
})


## ---- QC plots ----------------------------------------------------------
plot_dir <- file.path(OUT_DIR, "qc")
dir.create(plot_dir, showWarnings = FALSE)

for (id in names(all_out)) {
  o <- all_out[[id]]
  png(file.path(plot_dir, paste0("P", id, "_breaths.png")), 1000, 800)
  plot_breaths(o$breaths, main = paste("Participant", id, "-", o$quality$quality))
  dev.off()

  png(file.path(plot_dir, paste0("P", id, "_trace.png")), 1400, 400)
  plot_resp(o$result$measure, detection = o$result$detection,
            from = o$result$measure$t0 + 300, to = o$result$measure$t0 + 420,
            main = paste("Participant", id, "- 2 min excerpt"))
  dev.off()
}
