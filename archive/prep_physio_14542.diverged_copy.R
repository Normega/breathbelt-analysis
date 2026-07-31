# prep_physio_14542.R
#
# Extracts and time-locks respiration data for participant 14542.
# Produces one RDS per participant containing:
#   - BioPac breath signal (Ch0, right seat) downsampled to 25 Hz
#   - BioPac HR derived signal (Ch13, right seat) downsampled to 250 Hz
#   - Wireless belt accel: raw x/y/z + vector magnitude + mlr-wide-lp estimate,
#     both reconstructed to per-sample timestamps and interpolated to 25 Hz grid
#   - Per-trial epochs with belt + BioPac segments time-locked to BioPac
#     trial-start trigger (val=250, code 10), with condition_onset_ms from
#     belt_trials used as baseline->condition boundary (BioPac code 11 / val=251
#     was removed from the experiment to reduce animation lag)
#   - Alignment diagnostics: per-trial BioPac<->belt offset and linear drift fit
#
# Alignment strategy:
#   BioPac has no absolute epoch clock. Alignment uses BioPac trial-start
#   triggers (val=250) matched by order to belt_trials$trial_onset_ms.
#   A linear drift correction is fit across all 34 triggers (empirically ~384ms
#   total drift over the session). Each trial segment is extracted using the
#   BioPac trigger sample directly as the zero point, avoiding accumulated error.
#
# MLR-wide-lp reconstruction:
#   The winning model label (mlr-wide-lp) is stored in belt_sessions but
#   calibration weights are not exported. Weights are re-fit here using the
#   pre-baseline accel data (phase == "baseline") regressed onto the BioPac
#   breath signal interpolated to the same 25 Hz grid. Wide bandpass = 0.05-1.0
#   Hz; LP post-smooth = 0.6 Hz. Comparison against vector magnitude allows
#   evaluation of whether MLR adds meaningful convergence with the BioPac signal.
#
# ── File conventions ──────────────────────────────────────────────────────────
# ACQ filename: L<leftID>_<rightID>.acq  (no R prefix on right ID in this study)
#   Left seat  = absent participant (16549) -> Ch0 Breath1, Ch2 Heart1 (blank)
#   Right seat = participant 14542          -> Ch0 Breath1, Ch13 Human Heart Rate
#   NOTE: channel assignment differs from 05_prep_physio.R precedent; this
#   study uses computed HR (Ch13/Ch15) not raw ECG (Ch2/Ch3).
# Trigger encoding: Biopac_Right, shift=1 (code sent as-is)
#   val=240 = line clear (baseline); val=250 = trial start; val=252 = trial end
#   val=251 (condition onset) absent -- use condition_onset_ms from belt_trials

# ── Set Up ────────────────────────────────────────────────────────────────────
packages <- c("tidyverse", "signal", "reticulate", "zoo")
new_packages <- packages[!sapply(packages, requireNamespace, quietly = TRUE)]
if (length(new_packages)) install.packages(new_packages)
options(readr.show_col_types = FALSE)
for (thispack in packages) {
  library(thispack, character.only = TRUE, quietly = TRUE, verbose = FALSE)
}

# ── Paths (adjust to local layout) ───────────────────────────────────────────
DATA_DIR   <- "data"          # directory containing all input files
OUTPUT_DIR <- "output"        # where the RDS will be written
dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

ACQ_FILE      <- file.path(DATA_DIR, "L16549_14542.acq")
ACCEL_FILE    <- file.path(DATA_DIR, "14542_session1_accel.csv")
TRIALS_FILE   <- file.path(DATA_DIR, "belt_trials.csv")
SESSIONS_FILE <- file.path(DATA_DIR, "belt_sessions.csv")
OUTPUT_FILE   <- file.path(OUTPUT_DIR, "14542_physio.rds")

PID <- "14542"

# ── Constants ─────────────────────────────────────────────────────────────────
BIOPAC_HZ    <- 2000L    # raw BioPac sample rate
RESP_HZ      <- 25L      # target respiration rate
CARD_HZ      <- 250L     # target cardiac rate
ACCEL_HZ_NOM <- 200L     # nominal belt accel rate (actual ~203 Hz; use for grid)
SAMPLES_PER_PACKET <- 36L
MS_PER_SAMPLE      <- 1000 / ACCEL_HZ_NOM  # 5 ms

# BioPac trigger values (Biopac_Right, shift=1)
TRIG_TRIAL_START <- 250L
TRIG_TRIAL_END   <- 252L
TRIG_CLEAR       <- 240L

# Bandpass specs for wide model: 0.05–1.0 Hz
WIDE_BP_LOW  <- 0.05
WIDE_BP_HIGH <- 1.00
LP_CUTOFF    <- 0.60     # post-smooth for mlr-wide-lp

# ── Helpers ───────────────────────────────────────────────────────────────────

# Integer-factor decimation (keep every Nth sample, matching 05_prep_physio.R)
.downsample <- function(x, factor) x[seq(1L, length(x), by = as.integer(factor))]

# Zero-phase Butterworth filter via signal::filtfilt
.butter_filter <- function(x, low, high, hz, order = 4L) {
  nyq <- hz / 2
  bf  <- signal::butter(order, c(low / nyq, high / nyq), type = "pass")
  signal::filtfilt(bf, x)
}

.butter_lp <- function(x, cutoff, hz, order = 4L) {
  nyq <- hz / 2
  bf  <- signal::butter(order, cutoff / nyq, type = "low")
  signal::filtfilt(bf, x)
}

# Extract trigger onsets: sample index + time + code (from 05_prep_physio.R)
.trigger_onsets <- function(trig, hz) {
  prev <- c(0L, trig[-length(trig)])
  idx  <- which(prev == 0L & trig != 0L)
  data.frame(sample_idx = idx, time_sec = idx / hz, code = trig[idx])
}

# Reconstruct per-sample timestamps from BLE packet timestamps.
# packet_timestamp is the epoch ms of the LAST sample in the packet.
# Back-assign SAMPLES_PER_PACKET samples at MS_PER_SAMPLE intervals.
.reconstruct_timestamps <- function(df) {
  df |>
    dplyr::group_by(packet_timestamp) |>
    dplyr::mutate(
      n_in_packet = dplyr::n(),
      sample_ms   = packet_timestamp - (n_in_packet - 1 - sample_index) * MS_PER_SAMPLE
    ) |>
    dplyr::ungroup()
}

# ── Step 1: Load tabular data ─────────────────────────────────────────────────
message("Loading tabular data...")

belt_sessions <- readr::read_csv(SESSIONS_FILE, show_col_types = FALSE) |>
  dplyr::filter(participant_id == PID)

belt_trials <- readr::read_csv(TRIALS_FILE, show_col_types = FALSE) |>
  dplyr::filter(participant_id == PID) |>
  dplyr::arrange(trial_onset_ms)

session_start_epoch_ms <- belt_sessions$session_start_epoch_ms[1]
message(sprintf("  Session start epoch: %s ms", session_start_epoch_ms))
message(sprintf("  Trials: %d (phase2=%d, phase3=%d)",
                nrow(belt_trials),
                sum(belt_trials$phase == 2),
                sum(belt_trials$phase == 3)))

# ── Step 2: Load BioPac ───────────────────────────────────────────────────────
message("Loading BioPac ACQ...")

if (!reticulate::py_module_available("bioread")) {
  message("  Installing bioread...")
  reticulate::py_install("bioread", pip = TRUE)
}
bioread <- reticulate::import("bioread")

acq     <- bioread$read_file(ACQ_FILE)
raw_hz  <- as.integer(acq$samples_per_second)
dur_sec <- length(acq$channels[[1]]$data) / raw_hz

# Right-seat channels (participant 14542):
#   Ch0  = Breath 1 (stretch belt, right seat)
#   Ch12 = Experiment Triggers
#   Ch13 = Human Heart Rate (right seat computed HR)
#   Ch15 = Respiration Rate (right seat computed resp rate)
#   Ch1/Ch3/Ch14/Ch16 = left seat (absent, blank/noise)
breath_raw <- as.numeric(acq$channels[[1]]$data)   # Ch0, 0-indexed
hr_raw     <- as.numeric(acq$channels[[14]]$data)  # Ch13
trig_raw   <- as.integer(round(as.numeric(acq$channels[[13]]$data)))  # Ch12

message(sprintf("  Duration: %.1f min | Breath std: %.3f | HR mean: %.1f",
                dur_sec / 60, sd(breath_raw), mean(hr_raw[hr_raw > 0])))

# Extract trigger onsets
events <- .trigger_onsets(trig_raw, raw_hz)
trial_start_events <- dplyr::filter(events, code == TRIG_TRIAL_START)

message(sprintf("  Trigger events: %d total | val=250 (trial start): %d | val=252 (trial end): %d",
                nrow(events),
                nrow(trial_start_events),
                sum(events$code == TRIG_TRIAL_END)))

# The first val=250 is from the test cascade (t~61s); skip it
cascade_cutoff_s <- 100
trial_start_events <- dplyr::filter(trial_start_events, time_sec > cascade_cutoff_s)
message(sprintf("  Real trial-start triggers (post-cascade): %d", nrow(trial_start_events)))

if (nrow(trial_start_events) != nrow(belt_trials)) {
  warning(sprintf("Trigger count (%d) != belt_trials rows (%d) -- check alignment",
                  nrow(trial_start_events), nrow(belt_trials)))
}

# Downsample BioPac signals
breath_ds <- .downsample(breath_raw, raw_hz / RESP_HZ)
hr_ds     <- .downsample(hr_raw,     raw_hz / CARD_HZ)

# ── Step 3: Alignment -- BioPac triggers <-> belt trial_onset_ms ──────────────
message("Computing BioPac <-> belt alignment...")

# Match by order. BioPac time is seconds from recording start; convert to ms.
# belt_trials$trial_onset_ms is ms from session_start_epoch_ms.
n_trials <- min(nrow(trial_start_events), nrow(belt_trials))

alignment <- data.frame(
  trial_idx       = seq_len(n_trials),
  phase           = belt_trials$phase[seq_len(n_trials)],
  trial_number    = belt_trials$trial_number[seq_len(n_trials)],
  biopac_s        = trial_start_events$time_sec[seq_len(n_trials)],
  biopac_sample   = trial_start_events$sample_idx[seq_len(n_trials)],
  belt_onset_ms   = belt_trials$trial_onset_ms[seq_len(n_trials)],
  belt_onset_epoch_ms = session_start_epoch_ms + belt_trials$trial_onset_ms[seq_len(n_trials)],
  condition_onset_ms  = belt_trials$condition_onset_ms[seq_len(n_trials)],
  trial_end_ms        = belt_trials$trial_end_ms[seq_len(n_trials)]
) |>
  dplyr::mutate(
    biopac_ms      = biopac_s * 1000,
    # offset: how many ms to add to BioPac ms to get belt epoch ms
    offset_ms      = belt_onset_epoch_ms - biopac_ms
  )

# Fit linear drift: offset drifts across trials due to clock divergence
drift_fit <- lm(offset_ms ~ trial_idx, data = alignment)
alignment <- alignment |>
  dplyr::mutate(
    offset_corrected_ms = predict(drift_fit, newdata = alignment),
    residual_ms         = offset_ms - offset_corrected_ms
  )

message(sprintf("  Clock drift: %.1f ms over %d trials (%.2f ms/trial)",
                coef(drift_fit)[2] * (n_trials - 1), n_trials, coef(drift_fit)[2]))
message(sprintf("  Residuals after linear correction: mean=%.1f ms, sd=%.1f ms, max=%.1f ms",
                mean(alignment$residual_ms),
                sd(alignment$residual_ms),
                max(abs(alignment$residual_ms))))

# ── Step 4: Load and reconstruct belt accel timestamps ────────────────────────
message("Loading belt accel CSV...")

accel_raw <- readr::read_csv(ACCEL_FILE, show_col_types = FALSE) |>
  dplyr::mutate(
    x = as.numeric(x),
    y = as.numeric(y),
    z = as.numeric(z),
    sample_index = as.integer(sample_index),
    packet_timestamp = as.numeric(packet_timestamp)
  )

message(sprintf("  Rows: %d | Phases: %s",
                nrow(accel_raw),
                paste(sort(unique(accel_raw$phase)), collapse = ", ")))

# Reconstruct per-sample timestamps (packet_timestamp = last sample in packet)
accel_raw <- .reconstruct_timestamps(accel_raw)

# Vector magnitude
accel_raw <- accel_raw |>
  dplyr::mutate(magnitude = sqrt(x^2 + y^2 + z^2))

# ── Step 5: Interpolate belt accel to uniform 25 Hz grid ─────────────────────
message("Interpolating belt accel to uniform 25 Hz grid...")

# Uniform grid in epoch ms covering full session
grid_interval_ms <- 1000 / RESP_HZ   # 40 ms
t_start <- min(accel_raw$sample_ms)
t_end   <- max(accel_raw$sample_ms)
time_grid_ms <- seq(t_start, t_end, by = grid_interval_ms)

# Interpolate each axis + magnitude onto uniform grid
# Use zoo::na.approx via approx for cleanliness
.interp_to_grid <- function(t_orig, y_orig, t_grid) {
  approx(t_orig, y_orig, xout = t_grid, method = "linear", rule = 2)$y
}

accel_grid <- data.frame(
  epoch_ms  = time_grid_ms,
  x         = .interp_to_grid(accel_raw$sample_ms, accel_raw$x,         time_grid_ms),
  y         = .interp_to_grid(accel_raw$sample_ms, accel_raw$y,         time_grid_ms),
  z         = .interp_to_grid(accel_raw$sample_ms, accel_raw$z,         time_grid_ms),
  magnitude = .interp_to_grid(accel_raw$sample_ms, accel_raw$magnitude, time_grid_ms)
)

# ── Step 6: Bandpass filter axes for MLR fitting (wide: 0.05-1.0 Hz) ─────────
message("Applying wide bandpass filter to belt accel (0.05-1.0 Hz)...")

accel_grid <- accel_grid |>
  dplyr::mutate(
    x_bp = .butter_filter(x, WIDE_BP_LOW, WIDE_BP_HIGH, RESP_HZ),
    y_bp = .butter_filter(y, WIDE_BP_LOW, WIDE_BP_HIGH, RESP_HZ),
    z_bp = .butter_filter(z, WIDE_BP_LOW, WIDE_BP_HIGH, RESP_HZ)
  )

# Also bandpass magnitude for reference
accel_grid <- accel_grid |>
  dplyr::mutate(mag_bp = .butter_filter(magnitude, WIDE_BP_LOW, WIDE_BP_HIGH, RESP_HZ))

# ── Step 7: Fit MLR weights on baseline period ────────────────────────────────
message("Fitting MLR weights on baseline period...")

# Interpolate BioPac breath signal to 25 Hz epoch ms grid
biopac_time_ms <- seq(0, length(breath_raw) - 1) / raw_hz * 1000
# Convert to epoch ms using linear drift-corrected offset at trial 1
# For the baseline (pre-trial), use offset at trial_idx=0 (extrapolate fit)
offset_at_baseline <- predict(drift_fit, newdata = data.frame(trial_idx = 0))
biopac_epoch_ms <- biopac_time_ms + offset_at_baseline

# Downsample BioPac to 25 Hz for regression
breath_ds_full <- .downsample(breath_raw, raw_hz / RESP_HZ)
biopac_epoch_ms_ds <- biopac_epoch_ms[seq(1, length(biopac_epoch_ms), by = raw_hz / RESP_HZ)]

# Interpolate BioPac breath onto the accel grid
biopac_on_grid <- approx(biopac_epoch_ms_ds, breath_ds_full,
                          xout = accel_grid$epoch_ms,
                          method = "linear", rule = 2)$y
accel_grid$biopac_breath <- biopac_on_grid

# Identify baseline samples on the accel grid
# Baseline phase in accel_raw covers phase == "baseline"
baseline_epoch_range <- accel_raw |>
  dplyr::filter(phase == "baseline") |>
  dplyr::summarise(t_min = min(sample_ms), t_max = max(sample_ms))

baseline_mask <- accel_grid$epoch_ms >= baseline_epoch_range$t_min &
                 accel_grid$epoch_ms <= baseline_epoch_range$t_max

message(sprintf("  Baseline samples for MLR fit: %d (%.1f s)",
                sum(baseline_mask), sum(baseline_mask) / RESP_HZ))

# Fit MLR: BioPac breath ~ x_bp + y_bp + z_bp (no intercept forced, let lm add it)
mlr_data <- accel_grid[baseline_mask, ]
mlr_fit  <- lm(biopac_breath ~ x_bp + y_bp + z_bp, data = mlr_data)
mlr_r    <- cor(mlr_data$biopac_breath, fitted(mlr_fit))

message(sprintf("  MLR calibration R = %.3f (cf. stored calib_fit_r = 0.518)", mlr_r))

# Apply MLR weights to full grid
accel_grid$mlr_pred <- predict(mlr_fit, newdata = accel_grid)

# Apply 0.6 Hz LP post-smooth (the -lp suffix in mlr-wide-lp)
accel_grid$mlr_lp <- .butter_lp(accel_grid$mlr_pred, LP_CUTOFF, RESP_HZ)

# Also LP-smooth magnitude for fair comparison
accel_grid$mag_lp <- .butter_lp(accel_grid$mag_bp, LP_CUTOFF, RESP_HZ)

# ── Step 8: Per-trial epoch extraction ───────────────────────────────────────
message("Extracting per-trial epochs...")

trial_epochs <- vector("list", n_trials)

for (i in seq_len(n_trials)) {
  al <- alignment[i, ]

  # Anchor: BioPac trigger sample for this trial
  # trial_onset = BioPac trigger; condition_onset and trial_end from belt (ms from session_start)
  # Convert belt ms offsets to BioPac sample index using linear drift correction
  biopac_onset_sample  <- al$biopac_sample
  biopac_onset_ms      <- al$biopac_ms

  # Condition onset and trial end in BioPac ms (belt ms relative to session start)
  # Use per-trial drift-corrected offset to convert belt epoch ms -> BioPac ms
  belt_to_biopac_ms <- function(belt_ms_rel) {
    # belt_ms_rel is ms from session_start; convert to absolute epoch, then to BioPac ms
    epoch_ms <- session_start_epoch_ms + belt_ms_rel
    biopac_ms <- epoch_ms - al$offset_corrected_ms
    biopac_ms
  }

  condition_onset_biopac_ms <- belt_to_biopac_ms(al$condition_onset_ms)
  trial_end_biopac_ms       <- belt_to_biopac_ms(al$trial_end_ms)

  # BioPac samples (2000 Hz) for full trial window
  onset_samp <- biopac_onset_sample
  end_samp   <- min(round(trial_end_biopac_ms / 1000 * raw_hz), length(breath_raw))

  # Downsample indices for 25 Hz breath and 250 Hz HR
  resp_onset  <- round(al$biopac_s * RESP_HZ) + 1L
  resp_end    <- min(round(trial_end_biopac_ms / 1000 * RESP_HZ) + 1L, length(breath_ds))
  card_onset  <- round(al$biopac_s * CARD_HZ) + 1L
  card_end    <- min(round(trial_end_biopac_ms / 1000 * CARD_HZ) + 1L, length(hr_ds))

  # Belt accel epochs (epoch ms window)
  belt_onset_epoch  <- al$belt_onset_epoch_ms
  belt_end_epoch    <- session_start_epoch_ms + al$trial_end_ms
  belt_mask         <- accel_grid$epoch_ms >= belt_onset_epoch &
                       accel_grid$epoch_ms <= belt_end_epoch

  # Timing of condition onset relative to trial onset (ms)
  condition_offset_ms <- al$condition_onset_ms - al$belt_onset_ms

  trial_epochs[[i]] <- list(
    participant_id        = PID,
    trial_idx             = i,
    phase                 = al$phase,
    trial_number          = al$trial_number,
    condition             = belt_trials$condition[i],
    log10_mag             = belt_trials$log10_mag[i],
    response              = belt_trials$response[i],
    correct               = belt_trials$correct[i],
    confidence            = belt_trials$confidence[i],
    arousal               = belt_trials$arousal[i],
    condition_offset_ms   = condition_offset_ms,

    # Timing anchors
    biopac_onset_sample   = onset_samp,
    biopac_onset_s        = al$biopac_s,
    alignment_residual_ms = al$residual_ms,

    # BioPac breath segment (25 Hz), time-locked to trial start
    biopac_breath_25hz    = if (resp_onset <= resp_end && resp_end <= length(breath_ds))
                              breath_ds[resp_onset:resp_end] else numeric(0),

    # BioPac HR segment (250 Hz)
    biopac_hr_250hz       = if (card_onset <= card_end && card_end <= length(hr_ds))
                              hr_ds[card_onset:card_end] else numeric(0),

    # Belt accel segment (25 Hz interpolated grid)
    belt_magnitude_25hz   = accel_grid$mag_lp[belt_mask],
    belt_mlr_lp_25hz      = accel_grid$mlr_lp[belt_mask],
    belt_epoch_ms         = accel_grid$epoch_ms[belt_mask],

    # Per-sample time axis relative to trial onset (ms), for belt signal
    belt_t_ms             = accel_grid$epoch_ms[belt_mask] - belt_onset_epoch,

    # Pearson R: belt magnitude vs BioPac breath (interpolated to same grid)
    r_magnitude_vs_biopac = {
      bp_interp <- approx(
        seq_along(breath_ds) / RESP_HZ * 1000,
        breath_ds,
        xout = accel_grid$epoch_ms[belt_mask] - (session_start_epoch_ms + al$belt_onset_ms - al$biopac_ms * 1),
        method = "linear", rule = 2
      )$y
      if (length(bp_interp) > 2 && sd(bp_interp) > 0 && sd(accel_grid$mag_lp[belt_mask]) > 0)
        cor(accel_grid$mag_lp[belt_mask], bp_interp)
      else NA_real_
    },
    r_mlr_vs_biopac = {
      bp_interp <- approx(
        seq_along(breath_ds) / RESP_HZ * 1000,
        breath_ds,
        xout = accel_grid$epoch_ms[belt_mask] - (session_start_epoch_ms + al$belt_onset_ms - al$biopac_ms * 1),
        method = "linear", rule = 2
      )$y
      if (length(bp_interp) > 2 && sd(bp_interp) > 0 && sd(accel_grid$mlr_lp[belt_mask]) > 0)
        cor(accel_grid$mlr_lp[belt_mask], bp_interp)
      else NA_real_
    }
  )
}

message(sprintf("  Extracted %d trial epochs", length(trial_epochs)))

# ── Step 9: Summary correlation comparison ────────────────────────────────────
message("Signal convergence summary (magnitude vs. mlr-wide-lp vs. BioPac):")

r_summary <- data.frame(
  trial_idx   = sapply(trial_epochs, `[[`, "trial_idx"),
  phase       = sapply(trial_epochs, `[[`, "phase"),
  r_magnitude = sapply(trial_epochs, `[[`, "r_magnitude_vs_biopac"),
  r_mlr_lp    = sapply(trial_epochs, `[[`, "r_mlr_vs_biopac")
)

r_summary |>
  tidyr::pivot_longer(cols = c(r_magnitude, r_mlr_lp), names_to = "model", values_to = "r") |>
  dplyr::group_by(model) |>
  dplyr::summarise(
    mean_r  = round(mean(r, na.rm = TRUE), 3),
    sd_r    = round(sd(r, na.rm = TRUE), 3),
    median_r = round(median(r, na.rm = TRUE), 3),
    .groups = "drop"
  ) |>
  print()

# ── Step 10: Save RDS ─────────────────────────────────────────────────────────
message("Saving RDS...")

out <- list(
  participant_id   = PID,
  session_start_epoch_ms = session_start_epoch_ms,

  # BioPac full-session signals
  biopac = list(
    breath_25hz   = breath_ds,
    hr_250hz      = hr_ds,
    events        = events,
    trial_starts  = trial_start_events,
    hz_breath     = RESP_HZ,
    hz_hr         = CARD_HZ,
    raw_hz        = raw_hz,
    duration_sec  = dur_sec,
    acq_file      = basename(ACQ_FILE),
    seat          = "R",
    breath_ch     = 0L,   # 0-indexed
    hr_ch         = 13L
  ),

  # Belt accel full-session (uniform 25 Hz grid)
  belt = list(
    accel_grid    = accel_grid,   # epoch_ms, x/y/z, magnitude, *_bp, mlr_pred, mlr_lp, mag_lp
    hz            = RESP_HZ,
    mlr_fit       = mlr_fit,
    mlr_r_calib   = mlr_r,
    wide_bp_low   = WIDE_BP_LOW,
    wide_bp_high  = WIDE_BP_HIGH,
    lp_cutoff     = LP_CUTOFF
  ),

  # Alignment diagnostics
  alignment = list(
    trial_table   = alignment,
    drift_fit     = drift_fit,
    drift_ms_total = coef(drift_fit)[2] * (n_trials - 1),
    residual_sd_ms = sd(alignment$residual_ms)
  ),

  # Per-trial epochs
  trial_epochs = trial_epochs,

  # Convergence summary
  r_summary = r_summary
)

saveRDS(out, OUTPUT_FILE)
message(sprintf("Saved: %s", OUTPUT_FILE))
message("Done.")
