# 01_batch_prep.R
#
# Task 3: run the corrected preprocessing pipeline across the pilot sample.
#
# Produces one RDS per participant in Analysis/output/, carrying signals and
# timing only. NO agreement quantity is computed here. See the disclosure block
# at the top of R/prep_physio.R.
#
# Usage:  Rscript scripts/01_batch_prep.R            # all pilot participants
#         Rscript scripts/01_batch_prep.R 14542      # one participant

# Set Up ---------
## Load libraries ---------
packages <- c("tidyverse", "signal", "reticulate", "zoo")
new_packages <- packages[!sapply(packages, requireNamespace, quietly = TRUE)]
if (length(new_packages)) install.packages(new_packages, repos = "https://cloud.r-project.org")
options(readr.show_col_types = FALSE)
for (thispack in packages) {
  library(thispack, character.only = TRUE, quietly = TRUE, verbose = FALSE)
}

## Paths ---------
BASE_DIR <- file.path("I:", "Shared drives", "Behavioral Interoception",
                      "Summer2026_CompareBelts")
PATHS <- list(
  acq_dir    = file.path(BASE_DIR, "Data", "acq_physio"),
  bt_dir     = file.path(BASE_DIR, "Data", "bt_physio"),
  tables_dir = file.path(BASE_DIR, "Data", "tables"),
  output_dir = file.path(BASE_DIR, "Analysis", "output")
)

for (f in c("seatmap.R", "acq_io.R", "trials.R", "pacer.R", "calibration.R", "prep_physio.R")) {
  source(file.path(BASE_DIR, "R", f))
}

## The pilot sample ---------
# Fixed in advance, per Section 1.7. Eighteen participants with an accelerometer
# CSV, an ACQ file, Block 3 and Block 4 trial records, and a recorded
# phase3_end_ms. 998877 is a test account and is excluded.
#
# DO NOT EXTEND THIS LIST after variance output has been seen. Participants
# recovered later join the confirmatory sample and contribute at the
# pre-specified interim re-estimation, not here.
PILOT_IDS <- c("3997", "9082", "9085", "13738", "14425", "14542", "14677",
               "14701", "16117", "16753", "16807", "17446", "17704", "17734",
               "17755", "17758", "17788", "17896")

args <- commandArgs(trailingOnly = TRUE)
ids  <- if (length(args)) args else PILOT_IDS

# Run ---------
belt_sessions <- readr::read_csv(file.path(PATHS$tables_dir, "belt_sessions.csv"))
belt_trials   <- readr::read_csv(file.path(PATHS$tables_dir, "belt_trials.csv"))
seat_map      <- suppressWarnings(build_seat_map(PATHS$acq_dir))

message("Preprocessing ", length(ids), " participant(s).\n")
results <- lapply(ids, function(pid) {
  tryCatch(
    { r <- prep_one(pid, seat_map, belt_sessions, belt_trials, PATHS,
                    quiet = length(ids) > 1L)
      # Deliberately keeps no calibration values. They are whitelisted, but the
      # extraction script reports their distribution; a batch driver has no
      # reason to accumulate eighteen individual figures.
      list(pid = pid, ok = TRUE, flags = r$flags) },
    error = function(e) {
      message("[", pid, "] FAILED: ", conditionMessage(e))
      list(pid = pid, ok = FALSE, flags = conditionMessage(e))
    })
})

# Report ---------
# Deliberately reports only provenance and quality flags. Calibration fit and
# the belt-to-pacer offset are whitelisted nuisance parameters, but their DISTRIBUTION is
# reported by the extraction script, not here, so nothing per-participant is
# printed beyond what is needed to see that a run succeeded.
ok <- vapply(results, `[[`, logical(1), "ok")
message("\n", sum(ok), "/", length(ok), " succeeded.")
if (any(!ok)) {
  message("\nFailed:")
  for (r in results[!ok]) message("  ", r$pid, ": ", r$flags)
}
flagged <- Filter(function(r) r$ok && length(r$flags), results)
if (length(flagged)) {
  message("\nFlagged but retained (Section 5.2 flags, it does not exclude):")
  for (r in flagged) for (f in r$flags) message("  ", r$pid, ": ", f)
}
message("\nNext: scripts/02_estimate_variance_components.R. Read only its report.")
