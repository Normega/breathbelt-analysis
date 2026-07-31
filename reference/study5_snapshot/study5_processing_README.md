# Study 5 Physiological Processing Pipeline

This folder contains the R scripts that process raw physiological recordings
and PsychoPy/Qualtrics data for Study 5 into the analysis-ready files used by
the main analysis pipeline.

## What is and is not in this folder

**Included (scripts only):**
- All processing and analysis scripts for Study 5

**Not included (archived on OSF at [FILL BEFORE SUBMISSION]):**
- Raw BIOPAC `.acq` physiological recordings (`data/Physio/`)
- Intermediate `.RDS` objects (`results/heartRDS/`, `results/rds/`)
- QC plot directories (`results/*_qc/`)
- Raw PsychoPy output files (`data/Behaviour/`)
- Raw Qualtrics export (`data/InteroceptionSummer2025_Qualtrics.xlsx`)

Scripts can be reviewed for pipeline logic without the raw data.
Full execution requires the OSF data archive.

## Path configuration

Every script has a `ROOT_DIR` block at the top (first ~15 lines). By default,
`ROOT_DIR <- "."` assumes the script is run from the **repository root**:

```r
if (!exists("ROOT_DIR")) ROOT_DIR <- "."
```

If running from inside `study5_processing/`, change to `ROOT_DIR <- ".."`.

## Script execution order

Run scripts in this order for a full pipeline from raw data to analysis inputs:

| Step | Script | Input | Output |
|---|---|---|---|
| 1 | `Intero2025_PrepQualtrics.R` | Qualtrics `.xlsx` | `questionnaireFile.csv` |
| 2 | `Intero2025_PrepPsychopy.R` | PsychoPy `.csv` files | `dataFile.csv`, `testFile.csv`, `hrReport.csv` |
| 3 | `Intero2025_InitializePhysio.R` | `dataFile.csv` | Environment setup |
| 4 | `Intero2025_BeltQualityScreen.R` | `.acq` files | `qcFile.xlsx` |
| 5 | `Intero2025_TrimContaminatedPhysio.R` | `.acq` files, `qcFile.xlsx` | Trimmed `.acq` files |
| 6 | `Intero2025_AlignmentRecovery.R` | `.acq` files | Session onset times in `qcFile.xlsx` |
| 7 | `Intero2025_AlignmentValidation.R` | `qcFile.xlsx` | Alignment QC plots |
| 8 | `Intero2025_BehaviourLedBreathAnalysis.R` | `.acq` files, `qcFile.xlsx` | `breathAdherence.csv` per participant |
| 9 | `Intero2025_BreathingAdherence.R` | RDS outputs from step 8 | `study5_summary.csv` (belt features) |
| 10 | `Intero2025_CreateCardiacRDS.R` | `.acq` files | `.RDS` files per participant |
| 11 | `Intero2025_HeartbeatDetection.R` | `.RDS` files, `hrReport.csv` | `heartbeat_detection_results.xlsx` |
| 12 | `analysis_study5.R` | All processed outputs | Summary statistics and figures |

`breath_pipeline.R` and `Intero2025_RespirationFunctions.R` are utility
libraries sourced automatically by other scripts; do not run them directly.

## Key pipeline notes

- **Effective sampling rate**: BIOPAC decimation produces 25.641 Hz (not 25.0 Hz);
  this is expected and accounted for throughout.
- **Session onset recovery**: Digital triggers are available for 39% of sessions;
  the remainder use a template-based alignment algorithm (see `Intero2025_AlignmentRecovery.R`).
- **Participant exceptions**: P14963's physio file is saved under ID 14962;
  P13081 has a manual onset override and Session 2 excluded; 9 participants
  have no physio file (IDs: 4327, 4582, 4597, 5170, 9361, 13048, 13675, 14395, 16510).
- **200ms respiratory lag**: Applied to respiratory windows only; not applied to
  cardiac (HBD) windows.

## Dependencies

```r
install.packages(c(
  "readxl", "writexl", "ggplot2", "ggeffects", "ggforce", "GGally", "ggpubr",
  "patchwork", "corrplot", "psych", "lme4", "lmerTest",
  "tidyverse", "tidyr", "stringr", "signal", "pracma", "tseries", "reticulate"
))
reticulate::py_install("bioread")   # for reading .acq files
```
