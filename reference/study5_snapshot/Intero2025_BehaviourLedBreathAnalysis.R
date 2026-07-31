rm(list = ls())

if (!exists("ROOT_DIR")) ROOT_DIR <- "."
analysisPath  <- file.path(ROOT_DIR, "study5_processing")
resultsPath   <- file.path(ROOT_DIR, "results")
dataPath      <- file.path(ROOT_DIR, "data")

#Now using downsampled and de-identified rds files 
#physioPath <- paste0(dataPath, 'Physio/') 

# RDS directory
rds_dir <- file.path(resultsPath, "study5rds")

studySummary      <- file.path(dataPath,    'study5_summary.csv')
taskDataFile      <- file.path(resultsPath, 'study5_long.csv')
taskTestFile      <- file.path(resultsPath, 'study5_test.csv')

#conditionFile     <- paste0(dataPath,    'ConditionLookup.xlsx')
#questionnaireFile <- paste0(resultsPath, 'questionnaireFile.csv')
qcFile            <- file.path(resultsPath, 'qcFile.xlsx')
hrFile            <- file.path(resultsPath, 'hrFile.csv')
hrReportFile      <- file.path(resultsPath, 'hrReport.csv')
beltScreenFile    <- file.path(resultsPath, 'belt_quality_screen.csv')

pipelineFile   <- file.path(analysisPath, 'breath_pipeline.R')
functionsFile  <- file.path(analysisPath, 'Intero2025_RespirationFunctions.R')
alignmentFile  <- file.path(analysisPath, 'Intero2025_AlignmentRecovery.R')


source(pipelineFile)
source(functionsFile)
source(alignmentFile)


# CONSTANTS -------------------------------------------------------
STARTDUR   <- 4     # Starting duration of each breath trial (s)
LAG        <- 0.2   # Signal transduction correction (s) — Biopac belt hardware latency
NUMBREATHS <- 4     # Number of breaths per trial


# Set up ----------------------------------------------------------
packages <- c(
  "readxl", "writexl",
  "ggplot2", "ggeffects", "ggforce", "GGally", "ggpubr",
  "patchwork",
  "corrplot", "psych",
  "lme4", "lmerTest",
  "DataCombine", "sjPlot",
  "tidyverse", "tidyr", "stringr",
  "reticulate",
  "signal",
  "pracma", "tseries"
)

if (length(setdiff(packages, rownames(installed.packages()))) > 0)
  install.packages(setdiff(packages, rownames(installed.packages())))

options(readr.num_columns = 0)
for (thispack in packages)
  library(thispack, character.only = TRUE, quietly = TRUE, verbose = FALSE)

reticulate::py_install("bioread")
bioread <- import("bioread")


# Load files ------------------------------------------------------
condData <- read.csv(studySummary) %>%
  dplyr::distinct() %>%
  dplyr::select(id, Computer, Condition) %>%
  dplyr::rename(firstCondition = Condition)
condData$id <- as.numeric(condData$id)
table(condData$firstCondition)

longData <- read.csv(taskDataFile)
longTest  <- read.csv(taskTestFile)

longData <- left_join(longData, condData, by = "id")

longData$currentCondition <-
  factor(longData$firstCondition == "Visual" & longData$ses == 1,
         labels = c("Breath", "Visual"))

condLookup <- longData %>%
  group_by(id, ses) %>%
  dplyr::select(currentCondition) %>%
  distinct()

longTest <- left_join(longTest, condLookup, by = c("id", "ses"))

testingIds <- c("1234", "5678")
longData   <- longData[!longData$id %in% testingIds, ]
longTest   <- longTest[!longTest$id %in% testingIds, ]

idList   <- unique(longData$id)
fileList <- list.files(path = physioPath)

# Belt quality screen — loaded once, looked up per participant in the loop
beltScreen <- read.csv(beltScreenFile, stringsAsFactors = FALSE)

# ── Manual physio overrides ───────────────────────────────────────────────────
# Participants whose alignment or physio exclusion has been confirmed manually.
# Columns:
#   id               — participant ID
#   ses              — session (1 or 2)
#   override_onset_s — use this onset instead of trigger/recovery (NA = no override)
#   exclude_physio   — if TRUE, treat physio as unavailable for this session
#   note             — reason
#
# Applied in the main loop AFTER alignment recovery, overriding the automatic
# result where specified.
physio_overrides <- data.frame(
  id             = c(13081L, 13081L),
  ses            = c(1L,     2L),
  override_onset_s = c(2211.622, NA_real_),  # ses1: use trigger; ses2: N/A
  exclude_physio = c(FALSE,  TRUE),           # ses2: belt flatlined before task
  note           = c(
    "Trigger onset used; ses1 fully precedes belt flatline at t~3300s",
    "Belt flatlined ~14s after ses1 ended; ses2 task window entirely within flatline"
  ),
  stringsAsFactors = FALSE
)

# ID mismatch fix: 14963's physio file was saved under 14962
# Copy once so the pipeline finds the correct .rds by participant ID.
rds_14963 <- file.path(rds_dir, "14963.rds")
rds_14962 <- file.path(rds_dir, "14962.rds")
if (!file.exists(rds_14963) && file.exists(rds_14962)) {
  file.copy(rds_14962, rds_14963)
  message("Copied 14962.rds -> 14963.rds (ID mismatch fix)")
}


# ============================================================
#  compute_actual_q()
#
#  safe_decimate() stages through factors <= 13, so the actual
#  decimation ratio differs from q when q > 13.
#  For q=80: stages [13, 6] -> actual ratio = 78.
#  Effective SR = 2000/78 = 25.641 Hz, not 25 Hz.
#  Passing the corrected fs to run_pipeline ensures the time
#  axis spans the true recording duration.
# ============================================================
compute_actual_q <- function(q) {
  remaining <- as.integer(q)
  actual    <- 1L
  while (remaining > 1L) {
    step      <- min(remaining, 13L)
    actual    <- actual * step
    remaining <- remaining %/% step
    if (remaining <= 1L) break
  }
  actual
}


# ============================================================
#  load_participant_physio()
#
#  Tries to load a participant's respiratory signal from a
#  pre-computed .rds file (downsampled to 25 Hz, created by
#  Intero2025_BeltQualityScreen.R).  Falls back to reading
#  the raw .acq file via checkParticipantFiles() if no .rds
#  exists.
#
#  Returns a standardised list:
#    $signal         — numeric vector (respiratory signal)
#    $fs             — effective sampling rate (Hz)
#    $start_times_s  — session start times in recording-absolute
#                      seconds (NULL if unavailable)
#    $abcode         — trigger QC code
#    $n_triggers     — session-start trigger count
#    $side           — "L" or "R"
#    $belt_quality   — "good"/"degraded"/"unusable"/NA
#    $physio_ok      — logical (FALSE if file missing/unreadable)
#    $source         — "rds" or "acq"
#    $contamination_note — character or NULL
# ============================================================
load_participant_physio <- function(currentId, condLookup, fileList,
                                    physioPath, bioread, beltScreen,
                                    rds_dir,
                                    expectedLogs         = 2,
                                    expectedTriggerVal_R = 1,
                                    expectedTriggerVal_L = 16) {

  # Belt quality from screen (look up by id)
  bq_row       <- beltScreen[beltScreen$id == currentId, ]
  belt_quality <- if (nrow(bq_row) > 0) bq_row$quality[1] else NA_character_

  rds_path <- file.path(rds_dir, paste0(currentId, ".rds"))

  # ------------------------------------------------------------------
  # PATH A: Load from .rds
  # ------------------------------------------------------------------
  if (file.exists(rds_path)) {
    rds <- tryCatch(readRDS(rds_path),
                    error = function(e) {
                      message(sprintf("  [WARN] RDS load failed for %s: %s",
                                      currentId, e$message))
                      NULL
                    })

    if (!is.null(rds) && !is.null(rds$signal)) {

      # Correct for safe_decimate staging mismatch.
      # safe_decimate(x, 80) actually decimates by 78 (stages: 13*6),
      # giving an effective SR of 2000/78 = 25.641 Hz, not 25 Hz.
      # Using the nominal 25 Hz inflates trough times by ~2.5%,
      # accumulating to ~30 s of drift at t=1200s and causing
      # alignment recovery to find the wrong session onset.
      # We compute the corrected fs here and pass it to run_pipeline.
      was_trimmed  <- !is.null(rds$trim_offset_s)
      native_fs    <- if (!is.null(rds$native_fs)) rds$native_fs else 2000
      q_nominal    <- floor(native_fs / 25)
      q_actual     <- compute_actual_q(q_nominal)
      corrected_fs <- native_fs / q_actual   # e.g. 2000/78 = 25.641 Hz

      # Convert start_indices to recording-absolute seconds.
      # Untrimmed: start_indices are in native-SR samples → divide by native_fs.
      # Trimmed: start_indices were computed as round(native_samp / q_nominal),
      #   so they index the downsampled signal → divide by corrected_fs.
      start_times_s <- if (!is.null(rds$start_indices) &&
                           length(rds$start_indices) > 0) {
        if (was_trimmed) {
          rds$start_indices / corrected_fs   # ds samples → seconds
        } else {
          rds$start_indices / native_fs      # native samples → seconds
        }
      } else NULL

      message(sprintf(
        "  [RDS] Loaded %s.rds | corrected_fs=%.3fHz (nominal %.0fHz) | %.1fs | belt: %s | %s",
        currentId, corrected_fs, rds$fs, length(rds$signal) / corrected_fs,
        if (is.na(belt_quality)) "?" else belt_quality,
        if (was_trimmed) "trimmed" else "full"))

      return(list(
        signal             = rds$signal,
        fs                 = corrected_fs,       # corrected for staging mismatch
        start_times_s      = start_times_s,
        abcode             = rds$abcode,
        n_triggers         = rds$n_triggers,
        side               = rds$side,
        belt_quality       = belt_quality,
        physio_ok          = TRUE,
        source             = "rds",
        contamination_note = rds$contamination_note
      ))
    }
  }

  # ------------------------------------------------------------------
  # PATH B: Fall back to reading the raw .acq file
  # ------------------------------------------------------------------
  message(sprintf("  [ACQ] No RDS for %s — reading raw .acq file", currentId))

  checkResults <- tryCatch(
    checkParticipantFiles(
      currentId, condLookup, fileList, physioPath, bioread,
      expectedLogs         = expectedLogs,
      expectedTriggerVal_R = expectedTriggerVal_R,
      expectedTriggerVal_L = expectedTriggerVal_L
    ),
    error = function(e) {
      message(paste("  [ERROR] checkParticipantFiles failed:", e$message))
      NULL
    }
  )

  if (is.null(checkResults) || is.null(checkResults$breath_data)) {
    return(list(
      signal             = NULL,
      fs                 = NA_real_,
      start_times_s      = NULL,
      abcode             = if (!is.null(checkResults)) checkResults$abcode else NA,
      n_triggers         = 0L,
      side               = NA_character_,
      belt_quality       = belt_quality,
      physio_ok          = FALSE,
      source             = "acq",
      contamination_note = NULL
    ))
  }

  start_times_s <- if (!is.null(checkResults$startIndices))
    checkResults$startIndices / checkResults$SR else NULL

  return(list(
    signal             = checkResults$breath_data,
    fs                 = checkResults$SR,
    start_times_s      = start_times_s,
    abcode             = checkResults$abcode,
    n_triggers         = checkResults$nTriggers,
    side               = checkResults$side,
    belt_quality       = belt_quality,
    physio_ok          = !checkResults$abnormal,
    source             = "acq",
    contamination_note = NULL
  ))
}


# Main QC loop ----------------------------------------------------
runQCLoop <- function(idList, longData, condLookup, fileList,
                      physioPath, bioread, resultsPath,
                      beltScreen, rds_dir) {

  basePlotDir <- file.path(resultsPath, "qc_plots")
  if (!dir.exists(basePlotDir)) dir.create(basePlotDir, recursive = TRUE)

  trialTable     <- data.frame()
  alignmentTable <- data.frame()

  for (thisId in seq_along(idList)) {
    currentId <- idList[thisId]

    plotDir <- file.path(resultsPath, "qc_plots", currentId)
    if (!dir.exists(plotDir)) dir.create(plotDir, recursive = TRUE)

    message(paste0("\n========== Processing P#: ", currentId,
                   " (", thisId, "/", length(idList), ") =========="))

    # ------------------------------------------------------------------
    # 1. LOAD PHYSIO (RDS preferred, .acq fallback)
    # ------------------------------------------------------------------
    physio <- tryCatch(
      load_participant_physio(
        currentId, condLookup, fileList, physioPath, bioread,
        beltScreen, rds_dir
      ),
      error = function(e) {
        message(paste("  [ERROR] load_participant_physio failed:", e$message))
        NULL
      }
    )

    if (is.null(physio) || !physio$physio_ok || is.null(physio$signal)) {
      trialTable <- rbind(trialTable, data.frame(
        id = currentId, trial_num = NA, run = NA,
        first_condition = NA, condition = NA, salience = NA, delta = NA,
        abcode = if (!is.null(physio)) physio$abcode else NA,
        physio_ok = FALSE, n_logs = NA, n_triggers = 0L,
        trial_available = FALSE, n_breaths = NA, correct_breaths = NA,
        mean_breath_rate_bpm = NA, correlation = NA,
        lag_samples = NA, lag_seconds = NA, lag_flag = NA,
        total_abs_error = NA, mae = NA, n_missing_breaths = NA,
        direction_correct = NA, observed_dur_change = NA,
        dur_b1 = NA, dur_b2 = NA, dur_b3 = NA, dur_b4 = NA,
        dur_b1_vs_b4 = NA, total_observed_dur = NA, within_trial_dur_sd = NA,
        belt_quality = if (!is.null(physio)) physio$belt_quality else NA,
        physio_source = if (!is.null(physio)) physio$source else NA,
        qc_note = if (is.null(physio)) "load_participant_physio crashed"
                  else "No physio signal available"
      ))
      next
    }

    nativeSR      <- physio$fs     # 25 Hz if from RDS, 2000 Hz if from ACQ
    abcode        <- physio$abcode
    physio_ok     <- physio$physio_ok
    n_triggers    <- physio$n_triggers
    belt_quality  <- physio$belt_quality

    # ------------------------------------------------------------------
    # 2. PREPROCESS FULL WAVEFORM
    #    run_pipeline() downsamples internally; if signal is already at
    #    25 Hz (from RDS), the downsample step auto-skips (q < 2).
    # ------------------------------------------------------------------
    pipelineResult <- NULL

    if (!is.null(physio$signal)) {
      # Clip movement / belt-removal artifacts before filtering.
      # Large transient spikes (e.g. belt being taken off) pass through the
      # bandpass filter and are detected as false troughs, inflating per-trial
      # breath counts and distorting the cost landscape.
      # Clip to [0.5th, 99.5th] percentile — preserves all real breathing
      # variation while removing extreme outliers (identical to Python prototype).
      signal_clipped <- pmax(
        pmin(physio$signal,
             quantile(physio$signal, 0.995, na.rm = TRUE)),
        quantile(physio$signal, 0.005, na.rm = TRUE))

      pipelineResult <- tryCatch(
        run_pipeline(signal_clipped, nativeSR,
                     bp_hi            = 0.4,   # Tightened from 1.0 Hz: suppresses 2×
                                               # harmonic at ~0.5 Hz that caused
                                               # spurious peak detections. Validated
                                               # by sensitivity sweep (N=21, 1480
                                               # trials): over-detection 18.3%→6.4%,
                                               # median r .668→.711 (2026-04).
                     detection_method = "prominence",
                     min_prominence   = 0.15,
                     min_dist_s       = 1,
                     detect_hp_on     = FALSE),
        error = function(e) {
          message(paste("  [ERROR] run_pipeline failed:", e$message))
          NULL
        }
      )
    }

    effectiveSR     <- if (!is.null(pipelineResult)) pipelineResult$final_fs  else nativeSR
    processedSignal <- if (!is.null(pipelineResult)) pipelineResult$final_signal else NULL
    processedTime   <- if (!is.null(pipelineResult)) pipelineResult$final_time   else NULL

    if (!is.null(pipelineResult)) {
      tryCatch({
        plotPipelineFile <- file.path(plotDir,
                                      paste0("P", currentId, "_Preprocessing.png"))
        plot_pipeline(pipelineResult, plot_file = plotPipelineFile,
                      width = 14, height = 18)
      }, error = function(e)
        message(paste0("  [WARN] Pipeline plot failed: ", e$message)))
    }

    # ------------------------------------------------------------------
    # 3. PARTICIPANT TRIAL DATA
    # ------------------------------------------------------------------
    thisData          <- longData[longData$id == currentId, ]
    thisData$trialNum <- seq_len(nrow(thisData))
    nTrials           <- nrow(thisData)

    firstCondition <- if ("firstCondition" %in% names(thisData))
      thisData$firstCondition[1] else NA

    # ------------------------------------------------------------------
    # 2b. ALIGNMENT RECOVERY
    # ------------------------------------------------------------------
    alignmentRow <- data.frame(
      id                   = currentId,
      first_condition      = firstCondition,
      belt_quality         = belt_quality,
      physio_source        = physio$source,
      contamination_note   = if (!is.null(physio$contamination_note))
        physio$contamination_note else "",
      est_onset_ses1_s     = NA_real_,
      est_onset_ses2_s     = NA_real_,
      ambiguity_ses1       = NA_real_,
      ambiguity_ses2       = NA_real_,
      n_exp_troughs_ses1   = NA_integer_,
      n_exp_troughs_ses2   = NA_integer_,
      n_matched_ses1       = NA_integer_,
      n_matched_ses2       = NA_integer_,
      mae_ses1             = NA_real_,
      mae_ses2             = NA_real_,
      trigger_onset_ses1_s = NA_real_,
      trigger_onset_ses2_s = NA_real_,
      offset_error_ses1_s  = NA_real_,
      offset_error_ses2_s  = NA_real_,
      recovery_note        = "",
      onset_source_ses1    = NA_character_,
      onset_source_ses2    = NA_character_
    )

    if (!is.null(pipelineResult) && nrow(thisData) > 0) {

      run1_data <- thisData[thisData$ses == 1, ]
      run2_data <- thisData[thisData$ses == 2, ]

      # Trigger-based onsets in recording-absolute seconds
      trigger_onsets <- physio$start_times_s

      # Test-phase data for this participant — adds ~8×5 expected troughs
      # to the tail of each session, substantially anchoring the cost
      # landscape for participants without triggers (abcode = 0).
      test1_data <- if (exists("longTest") && nrow(longTest) > 0)
        longTest[longTest$id == currentId & longTest$ses == 1, ] else NULL
      test2_data <- if (exists("longTest") && nrow(longTest) > 0)
        longTest[longTest$id == currentId & longTest$ses == 2, ] else NULL

      recovery <- tryCatch(
        recover_run_alignment(
          pipeline_trough_times = pipelineResult$trough_times,
          recording_duration_s  = max(pipelineResult$final_time),
          run1_trial_data       = if (!is.null(firstCondition) &&
                                      !is.na(firstCondition) &&
                                      firstCondition == "Breath" &&
                                      nrow(run1_data) > 0) run1_data else NULL,
          run2_trial_data       = if (nrow(run2_data) > 0) run2_data else NULL,
          run1_test_data        = if (!is.null(test1_data) &&
                                      nrow(test1_data) > 0) test1_data else NULL,
          run2_test_data        = if (!is.null(test2_data) &&
                                      nrow(test2_data) > 0) test2_data else NULL,
          first_condition       = if (!is.null(firstCondition) &&
                                      !is.na(firstCondition))
            firstCondition else "Breath",
          visual_session_span_s = if (!is.null(firstCondition) &&
                                      !is.na(firstCondition) &&
                                      firstCondition == "Visual" &&
                                      nrow(run1_data) > 0)
            max(run1_data$trial.stopped, na.rm = TRUE) else NULL,
          # Trigger-based ses1 onset for Visual lower-bound sharpening
          trigger_onset_ses1_s  = if (!is.null(trigger_onsets) &&
                                       length(trigger_onsets) >= 1)
            trigger_onsets[1] else NULL,
          belt_quality          = belt_quality,
          STARTDUR              = STARTDUR,
          NUMBREATHS            = NUMBREATHS,
          min_gap_s             = 120
        ),
        error = function(e) {
          message(paste0("  [WARN] recover_run_alignment failed: ", e$message))
          NULL
        }
      )

      if (!is.null(recovery)) {
        alignmentRow$est_onset_ses1_s   <- recovery$t1
        alignmentRow$est_onset_ses2_s   <- recovery$t2
        alignmentRow$ambiguity_ses1     <- recovery$ambiguity1
        alignmentRow$ambiguity_ses2     <- recovery$ambiguity2
        alignmentRow$n_exp_troughs_ses1 <- recovery$n_exp1
        alignmentRow$n_exp_troughs_ses2 <- recovery$n_exp2
        alignmentRow$n_matched_ses1     <- recovery$n_matched1
        alignmentRow$n_matched_ses2     <- recovery$n_matched2
        alignmentRow$mae_ses1           <- recovery$mae1
        alignmentRow$mae_ses2           <- recovery$mae2
        alignmentRow$recovery_note      <- paste(recovery$notes, collapse = " | ")

        if (!is.null(trigger_onsets) && length(trigger_onsets) >= 1)
          alignmentRow$trigger_onset_ses1_s <- trigger_onsets[1]
        if (!is.null(trigger_onsets) && length(trigger_onsets) >= 2)
          alignmentRow$trigger_onset_ses2_s <- trigger_onsets[2]

        alignmentRow$offset_error_ses1_s <-
          alignmentRow$est_onset_ses1_s - alignmentRow$trigger_onset_ses1_s
        alignmentRow$offset_error_ses2_s <-
          alignmentRow$est_onset_ses2_s - alignmentRow$trigger_onset_ses2_s

        tryCatch({
          plot_alignment_cost(
            recovery,
            participant_id = currentId,
            plot_file = file.path(plotDir,
                                  paste0("P", currentId, "_AlignmentRecovery.png"))
          )
        }, error = function(e)
          message(paste0("  [WARN] Alignment plot failed: ", e$message)))

      }
    }

    # ------------------------------------------------------------------
    # 4. TRIAL LOOP
    # ------------------------------------------------------------------
    participantRows <- vector("list", nTrials)

    # Run onset times in recording-absolute seconds.
    # Priority: trigger-based > alignment recovery > NA.
    trigger_onsets <- physio$start_times_s
    runOnsetSec    <- c(NA_real_, NA_real_)

    for (run_i in 1:2) {
      has_trigger <- !is.null(trigger_onsets) && length(trigger_onsets) >= run_i
      if (has_trigger) {
        runOnsetSec[run_i] <- trigger_onsets[run_i]
        message(sprintf("  Run %d onset: %.2f s (trigger)", run_i, runOnsetSec[run_i]))
        if (run_i == 1) alignmentRow$onset_source_ses1 <- "trigger"
        else            alignmentRow$onset_source_ses2 <- "trigger"
      } else {
        est <- if (run_i == 1) alignmentRow$est_onset_ses1_s
               else            alignmentRow$est_onset_ses2_s
        if (!is.na(est)) {
          runOnsetSec[run_i] <- est
          message(sprintf("  Run %d onset: %.2f s (recovery estimate)", run_i, runOnsetSec[run_i]))
          if (run_i == 1) alignmentRow$onset_source_ses1 <- "recovery"
          else            alignmentRow$onset_source_ses2 <- "recovery"
        } else {
          message(sprintf("  Run %d onset: unavailable", run_i))
          if (run_i == 1) alignmentRow$onset_source_ses1 <- "unavailable"
          else            alignmentRow$onset_source_ses2 <- "unavailable"
        }
      }
    }

    # ── Apply manual overrides ─────────────────────────────────────────────
    p_overrides <- physio_overrides[physio_overrides$id == currentId, ]
    if (nrow(p_overrides) > 0) {
      for (ov_i in seq_len(nrow(p_overrides))) {
        ov      <- p_overrides[ov_i, ]
        run_i   <- ov$ses

        if (ov$exclude_physio) {
          # Mark this session's physio as excluded
          runOnsetSec[run_i] <- NA_real_
          message(sprintf("  [OVERRIDE] ses%d physio EXCLUDED: %s",
                          run_i, ov$note))

        } else if (!is.na(ov$override_onset_s)) {
          # Replace onset with manually specified value
          runOnsetSec[run_i] <- ov$override_onset_s
          if (run_i == 1) alignmentRow$onset_source_ses1 <- "manual_override"
          else            alignmentRow$onset_source_ses2 <- "manual_override"
          message(sprintf("  [OVERRIDE] ses%d onset set to %.2f s: %s",
                          run_i, ov$override_onset_s, ov$note))
        }
      }
    }

    # Overview figure saved here — AFTER runOnsetSec is fully populated
    # (trigger-based and/or recovery-based onsets both resolved).
    if (!is.null(pipelineResult)) {
      tryCatch({
        plot_alignment_overview(
          processedSignal  = processedSignal,
          processedTime    = processedTime,
          trough_times     = pipelineResult$trough_times,
          recovery         = recovery,
          run1_trial_data  = if (!is.null(run1_data) && nrow(run1_data) > 0)
                               run1_data else NULL,
          run2_trial_data  = if (!is.null(run2_data) && nrow(run2_data) > 0)
                               run2_data else NULL,
          run1_test_data   = normalise_test_data(test1_data),
          run2_test_data   = normalise_test_data(test2_data),
          runOnsetSec      = runOnsetSec,
          first_condition  = if (!is.null(firstCondition) && !is.na(firstCondition))
                               firstCondition else "Breath",
          participant_id   = currentId,
          LAG              = LAG,
          STARTDUR         = STARTDUR,
          NUMBREATHS       = NUMBREATHS,
          save_path        = file.path(plotDir,
                              paste0("P", currentId, "_AlignmentOverview.png"))
        )
      }, error = function(e)
        message(paste0("  [WARN] Alignment overview failed: ", e$message)))
    }

    for (thisTrial in seq_len(nTrials)) {

      run <- if (thisTrial <= 40) 1 else 2

      trialRow <- data.frame(
        id              = currentId,
        trial_num       = thisTrial,
        run             = run,
        first_condition = firstCondition,
        condition       = NA, salience = NA, delta = NA,
        abcode          = abcode,
        physio_ok       = physio_ok,
        n_logs          = NA,
        n_triggers      = n_triggers,
        belt_quality    = belt_quality,
        physio_source   = physio$source,
        trial_available = FALSE,
        n_breaths            = NA, correct_breaths = NA,
        mean_breath_rate_bpm = NA,
        correlation          = NA, lag_samples = NA, lag_seconds = NA,
        lag_flag        = NA,  # TRUE when |lag_seconds| > 1.0s: first-peak
                               # detection failed within trial (participant
                               # late-starting, missed breath, or poor onset
                               # recovery). 90th pct of |lag| for correct-
                               # breath trials = 1.01s (validated 2026-04).
                               # Use as exclusion criterion for paced trials.
        total_abs_error      = NA, mae = NA, n_missing_breaths = NA,
        direction_correct = NA,  # TRUE when observed breath durations change
                                  # in the expected direction on change trials
                                  # (delta != 0). Compares mean duration of
                                  # breaths 3-4 vs breaths 1-2: sign must match
                                  # sign of delta (positive = slower = longer).
                                  # NA for NoChange trials (delta == 0).
        observed_dur_change = NA, # mean(breath 3-4) - mean(breath 1-2), seconds.
                                  # NA for NoChange trials.
        dur_b1 = NA, dur_b2 = NA, dur_b3 = NA, dur_b4 = NA,
                                  # Individual detected breath durations (s).
                                  # NA when that breath was not detected.
                                  # dur_b1 doubles as baseline check: compare
                                  # against STARTDUR (4s) in analysis.
        dur_b1_vs_b4 = NA,        # dur_b4 - dur_b1 (seconds). Captures full arc
                                  # of change; better suited to Low-salience trials
                                  # where change is gradual across all 4 breaths.
                                  # Positive = slower; negative = faster.
                                  # NA when either breath 1 or 4 undetected.
        total_observed_dur = NA,  # sum(dur_b1:dur_b4) — belt-measured total trial
                                  # duration (s). Compare against expected total
                                  # (sum of expectedDurations). NA if any of the
                                  # 4 breaths undetected (requires all 4).
        within_trial_dur_sd = NA, # SD of the 4 detected breath durations within
                                  # the trial (s). On NoChange trials this is a
                                  # noise floor: low = stable pacing, high = drift.
                                  # NA if fewer than 2 breaths detected.
        qc_note         = ""
      )

      thisTrialData <- thisData[thisData$trialNum == thisTrial, ]

      if (nrow(thisTrialData) == 0) {
        trialRow$qc_note <- "Trial not found in longData"
        participantRows[[thisTrial]] <- trialRow
        next
      }

      trialRow$condition <- if ("Condition" %in% names(thisTrialData)) thisTrialData$Condition[1] else NA
      trialRow$salience  <- if ("Salience"  %in% names(thisTrialData)) thisTrialData$Salience[1]  else NA
      trialRow$delta     <- if ("Change"    %in% names(thisTrialData)) thisTrialData$Change[1]    else NA

      sal   <- trialRow$salience
      delta <- trialRow$delta

      if (is.null(processedSignal)) {
        trialRow$qc_note <- "No processed physio data available"
        participantRows[[thisTrial]] <- trialRow
        next
      }

      if (is.na(runOnsetSec[run])) {
        trialRow$qc_note <- "No run onset available (no trigger or recovery estimate)"
        participantRows[[thisTrial]] <- trialRow
        next
      }

      # 4b. EXTRACT TRIAL SIGNAL
      trialStartTime <- thisTrialData$trial.started
      trialStopTime  <- thisTrialData$trial.stopped
      startSec       <- runOnsetSec[run] + LAG + trialStartTime
      stopSec        <- runOnsetSec[run] + LAG + trialStopTime

      trialSignal <- tryCatch({
        t0          <- processedTime[1]
        startProcIx <- max(1L, min(length(processedTime),
                                   as.integer(round((startSec - t0) * effectiveSR)) + 1L))
        stopProcIx  <- max(1L, min(length(processedTime),
                                   as.integer(round((stopSec  - t0) * effectiveSR)) + 1L))
        if (startProcIx >= stopProcIx)
          stop(sprintf("Degenerate window [%.3f, %.3f] s", startSec, stopSec))
        processedSignal[startProcIx:stopProcIx]
      }, error = function(e) {
        message(paste0("  [Trial ", thisTrial, "] Signal extraction failed: ", e$message))
        NULL
      })

      if (is.null(trialSignal)) {
        trialRow$qc_note <- "Signal extraction failed"
        participantRows[[thisTrial]] <- trialRow
        next
      }

      trialRow$trial_available <- TRUE

      # 4c. ANALYZE RESPIRATION
      analyzeResults <- tryCatch(
        analyze_respiration(
          pipeline_trough_times = pipelineResult$trough_times,
          pipeline_peak_times   = pipelineResult$peak_times,
          trial_start_s         = startSec,
          trial_stop_s          = stopSec,
          sampling_rate         = effectiveSR,
          expected_breaths      = 4
        ),
        error = function(e) {
          message(paste0("  [Trial ", thisTrial, "] analyze_respiration failed: ", e$message))
          NULL
        }
      )

      if (!is.null(analyzeResults)) {
        trialRow$n_breaths       <- analyzeResults$n_breaths_detected
        trialRow$correct_breaths <- analyzeResults$n_breaths_detected == 4
      } else {
        trialRow$qc_note <- paste(trialRow$qc_note, "| analyze_respiration failed")
      }

      # 4c(ii). LOCAL RETRY
      if (!is.null(analyzeResults) &&
          analyzeResults$n_breaths_detected < 4 &&
          !is.null(trialSignal)) {

        augmented <- tryCatch(
          augment_trial_extrema(
            trial_signal          = trialSignal,
            trial_start_s         = startSec,
            pipeline_peak_times   = pipelineResult$peak_times,
            pipeline_trough_times = pipelineResult$trough_times,
            SR                    = effectiveSR,
            amplitude_min         = 0.1,
            expected_breaths      = 4
          ),
          error = function(e) {
            message(paste0("  [Trial ", thisTrial, "] Local retry failed: ", e$message))
            NULL
          }
        )

        if (!is.null(augmented) &&
            (augmented$n_added_peaks > 0 || augmented$n_added_troughs > 0)) {

          analyzeResults2 <- tryCatch(
            analyze_respiration(
              pipeline_trough_times = augmented$trough_times,
              pipeline_peak_times   = augmented$peak_times,
              trial_start_s         = startSec,
              trial_stop_s          = stopSec,
              sampling_rate         = effectiveSR,
              expected_breaths      = 4
            ),
            error = function(e) NULL
          )

          if (!is.null(analyzeResults2) &&
              analyzeResults2$n_breaths_detected > analyzeResults$n_breaths_detected) {
            analyzeResults           <- analyzeResults2
            trialRow$n_breaths       <- analyzeResults$n_breaths_detected
            trialRow$correct_breaths <- analyzeResults$n_breaths_detected == 4
            trialRow$qc_note <- paste(trialRow$qc_note,
                                      sprintf("| local retry +%d breath(s)",
                                              augmented$n_added_peaks +
                                                augmented$n_added_troughs))
          }
        }
      }

      # 4c(iii). MEAN BREATHING RATE
      if (!is.null(analyzeResults) && length(analyzeResults$trough_times) >= 2) {
        ibi_s <- diff(analyzeResults$trough_times)
        trialRow$mean_breath_rate_bpm <- 60 / mean(ibi_s)
      }

      # 4d. EXPECTED SIGNAL
      expectedResults <- NULL
      if (!is.null(sal) && !is.null(delta) && !is.na(sal) && !is.na(delta)) {
        expectedResults <- tryCatch(
          getExpectedSignal(sal, delta, effectiveSR, NUMBREATHS, STARTDUR),
          error = function(e) {
            message(paste0("  [Trial ", thisTrial, "] getExpectedSignal failed: ", e$message))
            NULL
          }
        )
      }

      # 4e. ALIGN SIGNALS
      alignResults <- NULL
      if (!is.null(expectedResults) && !is.null(analyzeResults)) {
        obs_peak_times_s <- analyzeResults$peak_times +
          (analyzeResults$expanded_start_s - startSec)

        alignResults <- tryCatch(
          alignSignals(trialSignal, expectedResults$expectedSignal,
                       effectiveSR,
                       peak_times_s = obs_peak_times_s,
                       STARTDUR     = STARTDUR,
                       show_plots   = FALSE),
          error = function(e) {
            message(paste0("  [Trial ", thisTrial, "] alignSignals failed: ", e$message))
            NULL
          }
        )

        if (!is.null(alignResults)) {
          trialRow$correlation <- alignResults$best_cor
          trialRow$lag_samples <- alignResults$lag_samples
          trialRow$lag_seconds <- alignResults$lag_s
          trialRow$lag_flag    <- !is.na(alignResults$lag_s) &&
                                  abs(alignResults$lag_s) > 1.0
        } else {
          trialRow$qc_note <- paste(trialRow$qc_note, "| alignSignals failed")
        }
      }

      # 4f. COMPARE DURATIONS
      if (!is.null(expectedResults)) {
        if (!is.null(analyzeResults)) {
          compareResults <- tryCatch(
            compareDurations(analyzeResults$durations,
                             expectedResults$expectedDurations,
                             trough_times = analyzeResults$trough_times),
            error = function(e) {
              message(paste0("  [Trial ", thisTrial, "] compareDurations failed: ", e$message))
              NULL
            }
          )

          if (!is.null(compareResults)) {
            trialRow$total_abs_error   <- compareResults$total_absolute_error
            trialRow$mae               <- compareResults$mae
            trialRow$n_missing_breaths <- compareResults$n_missing

            # 4f(ii). PER-BREATH DURATIONS AND DIRECTIONAL METRICS
            # Extract individual detected durations for breaths 1–4 and
            # compute two change indices:
            #   observed_dur_change: mean(b3,b4) - mean(b1,b2)
            #     → better power (2 breaths each); works for both salience types
            #   dur_b1_vs_b4: b4 - b1
            #     → captures full arc; better for Low-salience where change is
            #       gradual across all breaths; noisier (1 breath each side)
            #
            # Both are positive for slower (longer durations), negative for faster.
            # NA when the relevant breaths were not detected.
            comp <- compareResults$comparison

            # Store individual breath durations
            for (bn in 1:4) {
              col_name <- paste0("dur_b", bn)
              val <- comp$duration_seconds_analyzed[comp$breath_number == bn]
              trialRow[[col_name]] <- if (length(val) == 1 && !is.na(val)) val
                                      else NA_real_
            }

            # dur_b1_vs_b4: always computed regardless of delta
            b1 <- trialRow$dur_b1
            b4 <- trialRow$dur_b4
            if (!is.na(b1) && !is.na(b4))
              trialRow$dur_b1_vs_b4 <- b4 - b1

            # total_observed_dur: sum of all 4 breath durations.
            # NA if any breath undetected — requires a complete trial.
            all_durs <- c(trialRow$dur_b1, trialRow$dur_b2,
                          trialRow$dur_b3, trialRow$dur_b4)
            if (!any(is.na(all_durs)))
              trialRow$total_observed_dur <- sum(all_durs)

            # within_trial_dur_sd: breath-to-breath variability within trial.
            # On NoChange trials this is a noise floor for pacing stability.
            # On change trials it conflates noise with the intended signal, so
            # interpret via the nochange_dur_sd summary column.
            n_detected <- sum(!is.na(all_durs))
            if (n_detected >= 2)
              trialRow$within_trial_dur_sd <- sd(all_durs, na.rm = TRUE)

            # observed_dur_change and direction_correct: change trials only
            if (!is.na(delta) && delta != 0) {
              dur_12 <- mean(c(trialRow$dur_b1, trialRow$dur_b2), na.rm = TRUE)
              dur_34 <- mean(c(trialRow$dur_b3, trialRow$dur_b4), na.rm = TRUE)
              if (!is.nan(dur_12) && !is.nan(dur_34)) {
                obs_change <- dur_34 - dur_12
                trialRow$direction_correct   <- sign(obs_change) == sign(delta)
                trialRow$observed_dur_change <- obs_change
              }
            }
          } else {
            trialRow$qc_note <- paste(trialRow$qc_note, "| compareDurations failed")
          }
        }
      } else if (!is.na(sal)) {
        trialRow$qc_note <- paste(trialRow$qc_note, "| Missing sal/delta")
      }

      # 4g. SAVE RESPIRATION PLOT
      if (!is.null(analyzeResults)) {
        tryCatch({
          plotFile <- file.path(plotDir,
                                paste0("P", currentId, "_trial", thisTrial, ".png"))
          plot_respiration_analysis(
            processedSignal  = processedSignal,
            processedTime    = processedTime,
            analysis_results = analyzeResults,
            sampling_rate    = effectiveSR,
            expected_signal  = alignResults$adjExpected,
            window_start_s   = if (!is.null(alignResults)) alignResults$window_start_s else NULL,
            window_end_s     = if (!is.null(alignResults)) alignResults$window_end_s   else NULL,
            best_cor         = if (!is.null(alignResults)) alignResults$best_cor       else NULL,
            mae              = trialRow$mae,
            save_path        = plotFile,
            width = 10, height = 5,
            save_plots = TRUE, show_plots = FALSE
          )
        }, error = function(e)
          message(paste0("  [Trial ", thisTrial, "] Plot failed: ", e$message)))
      }

      trialRow$qc_note <- trimws(gsub("^\\| | \\|$", "", trialRow$qc_note))
      participantRows[[thisTrial]] <- trialRow

    } # end trial loop

    trialTable     <- rbind(trialTable, do.call(rbind, participantRows))
    alignmentTable <- rbind(alignmentTable, alignmentRow)

  } # end participant loop

  list(trialTable = trialTable, alignmentTable = alignmentTable)
}


# Run -------------------------------------------------------------
qcOutput <- runQCLoop(
  idList      = idList,
  longData    = longData,
  condLookup  = condLookup,
  fileList    = fileList,
  physioPath  = physioPath,
  bioread     = bioread,
  resultsPath = resultsPath,
  beltScreen  = beltScreen,
  rds_dir     = rds_dir
)

qcResults      <- qcOutput$trialTable
alignmentTable <- qcOutput$alignmentTable


# Summary ---------------------------------------------------------
safe_mean   <- function(x, ...) if (all(is.na(x))) NA_real_ else mean(x, ...)
safe_median <- function(x, ...) if (all(is.na(x))) NA_real_ else median(x, ...)

# pct_direction_correct: % of change trials where direction was correct
pct_direction_correct_fn <- function(dc, delta) {
  dc_change <- dc[!is.na(delta) & delta != 0]
  if (length(dc_change) == 0 || all(is.na(dc_change))) NA_real_
  else mean(dc_change, na.rm = TRUE) * 100
}

# delta_change_cor: Pearson r between delta and dur_b1_vs_b4 for a subset.
# Uses all available trials (including NoChange, delta==0) unless filtered.
# Returns NA when fewer than 3 complete pairs exist.
delta_change_cor <- function(delta, b1v4) {
  ok <- !is.na(delta) & !is.na(b1v4)
  if (sum(ok) < 3) NA_real_
  else cor(delta[ok], b1v4[ok])
}

qcSummary <- qcResults %>%
  group_by(id, run, first_condition, belt_quality, physio_source) %>%
  dplyr::summarise(
    n_trials                 = n(),
    n_available              = sum(trial_available,         na.rm = TRUE),
    pct_correct_breaths      = safe_mean(correct_breaths,   na.rm = TRUE) * 100,
    median_breath_rate       = safe_median(mean_breath_rate_bpm, na.rm = TRUE),
    median_correlation       = safe_median(correlation,     na.rm = TRUE),
    median_total_error       = safe_median(total_abs_error, na.rm = TRUE),
    median_mae               = safe_median(mae,             na.rm = TRUE),
    median_lag               = safe_median(lag_seconds,     na.rm = TRUE),
    n_lag_flagged            = sum(lag_flag,                na.rm = TRUE),
    pct_lag_flagged          = safe_mean(lag_flag,          na.rm = TRUE) * 100,
    pct_direction_correct    = pct_direction_correct_fn(direction_correct, delta),
    # ── Condition-stratified delta ~ observed-change correlations ──────────
    # Each r is Pearson correlation between delta and dur_b1_vs_b4 (b4 - b1)
    # within the condition subset. Higher r = belt signal tracks the intended
    # manipulation more faithfully.
    # Salience labels: "High" / "Low"; direction inferred from sign of delta.
    r_delta_change_HiAcc = delta_change_cor(
      delta[salience == "High" & delta > 0],
      dur_b1_vs_b4[salience == "High" & delta > 0]),
    r_delta_change_HiDec = delta_change_cor(
      delta[salience == "High" & delta < 0],
      dur_b1_vs_b4[salience == "High" & delta < 0]),
    r_delta_change_LoAcc = delta_change_cor(
      delta[salience == "Low"  & delta > 0],
      dur_b1_vs_b4[salience == "Low"  & delta > 0]),
    r_delta_change_LoDec = delta_change_cor(
      delta[salience == "Low"  & delta < 0],
      dur_b1_vs_b4[salience == "Low"  & delta < 0]),
    r_delta_change_all   = delta_change_cor(delta, dur_b1_vs_b4),
    # ── NoChange noise floor ──────────────────────────────────────────────
    # median within-trial breath SD on NoChange trials (delta == 0).
    # Low = stable pacing; high = participant not entrained.
    # Uncontaminated by the intended manipulation signal.
    median_nochange_dur_sd = safe_median(
      within_trial_dur_sd[!is.na(delta) & delta == 0], na.rm = TRUE),
    # ── Total duration tracking ───────────────────────────────────────────
    # Median ratio of observed to expected total trial duration.
    # Values near 1 = participant matched the full trial duration.
    # Expected total = sum of expected breath durations for that trial's
    # salience/delta combination (stored in expectedResults inside the loop
    # but not currently exported; median_total_error captures the same
    # information via MAE, so this is supplementary).
    median_total_observed_dur = safe_median(total_observed_dur, na.rm = TRUE),
    n_flagged            = sum(qc_note != "",           na.rm = TRUE),
    .groups = "drop"
  )

goodSelector <- !is.na(qcSummary$pct_correct_breaths) &
  qcSummary$pct_correct_breaths >= 90
goodOnes     <- qcSummary[goodSelector, ]

median(goodOnes$median_correlation, na.rm = TRUE)
median(goodOnes$median_mae,         na.rm = TRUE)
median(goodOnes$median_lag,         na.rm = TRUE)

t <- table(goodOnes$id, goodOnes$run)
colSums(t)

list_of_sheets <- list(
  "FullResults"       = qcResults,
  "ResultsSummary"    = qcSummary,
  "GoodBreaths"       = goodOnes,
  "AlignmentRecovery" = alignmentTable
)
write_xlsx(list_of_sheets, qcFile)
