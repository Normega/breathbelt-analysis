# prep_physio.R
#
# Per-participant preprocessing: time-lock the BioPac stretch belt and the Polar
# H10 accelerometer onto a common 25 Hz grid, and fit the accelerometer's
# breathing transformation against the RECONSTRUCTED PACER.
#
# Entry point is prep_one(pid, ...). Batch driver is scripts/01_batch_prep.R.
#
# ── DISCLOSURE CONTROL ────────────────────────────────────────────────────────
#
# THIS SCRIPT COMPUTES NO AGREEMENT QUANTITY, AND MUST NOT.
#
# The version this replaces computed a per-trial correlation between the
# accelerometer reconstruction and the BioPac breath signal (`r_mlr_vs_biopac`),
# stored it per trial and in an `r_summary` table, and PRINTED its mean, SD and
# median to the console on every run.
#
# That is a between-device correlation. Section 1.7 blocks "any agreement
# coefficient" and "any correlation" because they are H2, H5 and H7 test
# statistics. Running the old script across the 18 pilot participants would have
# printed device-agreement statistics to the terminal and destroyed the internal
# pilot protection permanently, with no way to undo it.
#
# Both are removed. The RDS carries signals and timing only. Agreement is
# computed downstream, in the confirmatory analysis, after the pre-registration
# is locked.
#
# The one sanctioned exception is the BioPac-target sensitivity fit described in
# Section 5.1, which necessarily correlates the two devices. It is OFF by default
# and must never be enabled while the internal pilot protection is live.
#
# Requires: tidyverse, signal, reticulate, zoo.
# Sourced by scripts/; installs nothing.


RESP_HZ <- 25L      # target respiration rate
CARD_HZ <- 250L     # target cardiac rate

# Event codes (see CONTEXT.md). Decoded values, not raw channel values.
CODE_SESSION_START <- 1L
CODE_TRIAL_START   <- 10L
CODE_TRIAL_END     <- 12L


# ── Helpers ───────────────────────────────────────────────────────────────────

.msg <- function(...) message("  ", sprintf(...))

# Apply a fitted calibration to a full session of raw axes.
apply_calibration <- function(x, y, z, fit, hz) {
  b  <- CALIB_BANDS[[fit$band]]
  xf <- bp_filter(x, b["low"], b["high"], hz)
  yf <- bp_filter(y, b["low"], b["high"], hz)
  zf <- bp_filter(z, b["low"], b["high"], hz)
  pred <- fit$bias + fit$weights[1] * xf + fit$weights[2] * yf + fit$weights[3] * zf
  if (isTRUE(fit$smooth)) pred <- lp_filter(pred, hz = hz)
  list(pred = pred, x_bp = xf, y_bp = yf, z_bp = zf)
}


# ── prep_one ──────────────────────────────────────────────────────────────────

#' @param pid            participant ID, character
#' @param seat_map       from build_seat_map()
#' @param belt_sessions  full sessions table
#' @param belt_trials    full trials table
#' @param paths          list(acq_dir, bt_dir, output_dir)
#' @param sensitivity    fit the BioPac-target model as well. MUST stay FALSE
#'                       while the internal pilot protection is live: it
#'                       computes a between-device correlation.
#' @param write          write the RDS
prep_one <- function(pid, seat_map, belt_sessions, belt_trials, paths,
                     sensitivity = FALSE, write = TRUE) {
  pid <- as.character(pid)
  message("[", pid, "] preprocessing")
  flags <- character(0)
  add_flag <- function(f) flags <<- c(flags, f)

  # -- 1. Session and trial records -------------------------------------------
  idcol <- if ("participant_external_id" %in% names(belt_sessions))
    "participant_external_id" else "participant_id"
  sess <- belt_sessions[as.character(belt_sessions[[idcol]]) == pid, , drop = FALSE]
  if (nrow(sess) != 1L) {
    stop("Participant ", pid, ": expected exactly one session row, found ", nrow(sess))
  }
  tri <- belt_trials[as.character(belt_trials[[idcol]]) == pid, , drop = FALSE]
  tri <- tri[order(tri$trial_onset_ms), , drop = FALSE]
  if (!nrow(tri)) stop("Participant ", pid, ": no trial records.")
  session_start_epoch_ms <- as.numeric(sess$session_start_epoch_ms[1])

  # -- 2. Seat and rig, resolved independently --------------------------------
  acq_path <- resolve_participant(pid, seat_map)$acq_file
  acq      <- read_acq(acq_path)
  trig_raw <- acq$get(TRIGGER_CHANNEL)

  rig_obs <- rig_from_trigger_codes(trig_raw)
  rec <- reconcile_session(pid, seat_map,
                           trigger_device = as.character(sess$trigger_device[1]),
                           observed_codes = NULL)
  rig  <- if (!is.na(rig_obs)) rig_obs else rec$rig
  seat <- rec$seat
  if (is.na(rig)) stop("Participant ", pid, ": could not identify the trigger rig.")
  if (!is.na(rig_obs) && !identical(rig_obs, as.character(sess$trigger_device[1]))) {
    add_flag(sprintf("trigger_device=%s but recorded codes say %s",
                     sess$trigger_device[1], rig_obs))
  }
  if (!identical(unname(c(Biopac_Left = "LEFT", Biopac_Right = "RIGHT")[rig]), seat)) {
    # Not an error. 14425 genuinely sat in the left seat while the right computer
    # ran the session. The seat picks the respiration channel, the rig picks the
    # code encoding, and they are allowed to differ.
    add_flag(sprintf("seat=%s but rig=%s (participant sat in one seat, other computer ran the session)",
                     seat, rig))
  }
  chans <- SEAT_CHANNELS[[seat]]
  .msg("seat=%s rig=%s -> %s / %s", seat, rig, chans[["breath"]], chans[["heart"]])

  breath_raw <- acq$get(chans[["breath"]])
  hr_raw     <- acq$get(chans[["heart"]])
  raw_hz     <- acq$hz

  # Guard against reading a vacant seat. An occupied channel exceeds a vacant one
  # by about three orders of magnitude, so this is unambiguous.
  if (stats::sd(breath_raw) < 0.01) {
    stop("Participant ", pid, ": respiration channel ", chans[["breath"]],
         " has SD ", signif(stats::sd(breath_raw), 3),
         ", which is a vacant seat. Seat resolution is wrong.")
  }

  # -- 3. Triggers ------------------------------------------------------------
  events <- decode_triggers(trig_raw, raw_hz, rig)
  events <- drop_pre_session(events, CODE_SESSION_START)   # removes the setup cascade
  starts <- events[events$code == CODE_TRIAL_START, , drop = FALSE]
  ends   <- events[events$code == CODE_TRIAL_END,   , drop = FALSE]
  .msg("events after cascade: %d | trial starts: %d | trial ends: %d",
       nrow(events), nrow(starts), nrow(ends))

  if (nrow(starts) != nrow(tri)) {
    stop("Participant ", pid, ": ", nrow(starts), " trial-start triggers but ",
         nrow(tri), " trial records. Alignment would be silently wrong.")
  }
  if (nrow(starts) != nrow(ends)) {
    add_flag(sprintf("%d trial starts vs %d trial ends", nrow(starts), nrow(ends)))
  }
  # Block codes may repeat: 3997 emitted code 7 twice. Report, do not fail.
  dup_block <- setdiff(events$code[duplicated(events$code)], c(CODE_TRIAL_START, CODE_TRIAL_END))
  if (length(dup_block)) add_flag(paste("repeated block code(s):", paste(sort(unique(dup_block)), collapse = ",")))

  # -- 4. Decimate ------------------------------------------------------------
  breath_ds <- decimate_safe(breath_raw, decimation_factor(raw_hz, RESP_HZ))
  hr_ds     <- decimate_safe(hr_raw,     decimation_factor(raw_hz, CARD_HZ))

  # -- 5. Accelerometer -------------------------------------------------------
  accel_file <- list.files(paths$bt_dir,
                           pattern = paste0("^", pid, "_session\\d+_accel\\.csv$"),
                           full.names = TRUE)
  if (length(accel_file) != 1L) {
    stop("Participant ", pid, ": expected one accel CSV, found ", length(accel_file))
  }
  accel <- readr::read_csv(accel_file, show_col_types = FALSE)
  accel <- reconstruct_accel_times(accel)

  grid_ms <- seq(min(accel$sample_ms), max(accel$sample_ms), by = 1000 / RESP_HZ)
  grid <- data.frame(
    epoch_ms = grid_ms,
    x = interp_to_grid(accel$sample_ms, accel$x, grid_ms),
    y = interp_to_grid(accel$sample_ms, accel$y, grid_ms),
    z = interp_to_grid(accel$sample_ms, accel$z, grid_ms)
  )

  # -- 6. Alignment -----------------------------------------------------------
  align <- data.frame(
    trial_idx     = seq_len(nrow(tri)),
    phase         = tri$phase,
    trial_number  = tri$trial_number,
    biopac_s      = starts$time_sec,
    biopac_sample = starts$sample_idx,
    belt_onset_ms = tri$trial_onset_ms,
    condition_onset_ms = tri$condition_onset_ms,
    trial_end_ms  = tri$trial_end_ms
  )
  align$belt_onset_epoch_ms <- session_start_epoch_ms + align$belt_onset_ms
  align$biopac_ms <- align$biopac_s * 1000
  align$offset_ms <- align$belt_onset_epoch_ms - align$biopac_ms

  drift <- stats::lm(offset_ms ~ trial_idx, data = align)
  align$offset_corrected_ms <- stats::predict(drift, newdata = align)
  align$residual_ms <- align$offset_ms - align$offset_corrected_ms
  resid_sd <- stats::sd(align$residual_ms)
  .msg("drift %.0f ms over %d trials | residual SD %.1f ms",
       stats::coef(drift)[2] * (nrow(align) - 1), nrow(align), resid_sd)

  # BioPac onto the accelerometer grid, using the drift fit extrapolated to the
  # pre-trial period so calibration and Block 2 are covered.
  offset0 <- stats::predict(drift, newdata = data.frame(trial_idx = 0))
  biopac_epoch_ms_ds <- seq(0, length(breath_ds) - 1) / RESP_HZ * 1000 + offset0
  grid$biopac_breath <- interp_to_grid(biopac_epoch_ms_ds, breath_ds, grid$epoch_ms)

  # -- 7. Calibration against the reconstructed pacer -------------------------
  #
  # The pacer overshoots its nominal period (see R/pacer.R). The overshoot is
  # measured from this participant's own recorded trial durations, which is
  # timing metadata, not an outcome, and applied to the calibration pacer too.
  over    <- estimate_pacer_overshoot(tri)
  eff_per <- CALIB_PERIOD_MS + over$delta_ms
  .msg("pacer overshoot %.0f ms/breath (SD %.0f, n=%d) -> effective period %.0f ms",
       over$delta_ms, over$delta_sd, over$n_trials, eff_per)
  if (over$delta_ms > 600 || over$delta_ms < -50) {
    add_flag(sprintf("implausible pacer overshoot %.0f ms/breath", over$delta_ms))
  }

  chk    <- check_calib_window(accel$phase, accel$sample_ms, pid, period_ms = eff_per)
  anchor <- calib_anchor_ms(accel$phase, accel$sample_ms)
  win    <- calib_fit_window(anchor, period_ms = eff_per)
  .msg("calib_breathe spans %.0f ms; fitting %.0f ms (%.0f ms is model fitting, discarded)",
       chk$span_ms, chk$paced_ms, chk$overrun_ms)

  cal_mask <- grid$epoch_ms >= win[["start_ms"]] & grid$epoch_ms <= win[["end_ms"]]
  fit <- fit_calibration(grid[cal_mask, c("epoch_ms", "x", "y", "z")] |>
                           stats::setNames(c("t_ms", "x", "y", "z")),
                         anchor_ms = anchor, period_ms = eff_per,
                         hz = RESP_HZ, target = "pacer", pid = pid)
  if (!is.na(fit$calib_flag)) add_flag(fit$calib_flag)
  if (fit$calib_lag_ms < 0 || fit$calib_lag_ms > 1000) {
    add_flag(sprintf("device lag %.0f ms outside the expected 0 to 1000 ms range",
                     fit$calib_lag_ms))
  }
  .msg("model=%s r=%.3f (lag-corrected %.3f) lag=%.0f ms margin=%.3f",
       fit$calib_model_label, fit$mlr_r_calib, fit$mlr_r_calib_lagcorr,
       fit$calib_lag_ms, fit$model_margin)

  applied <- apply_calibration(grid$x, grid$y, grid$z, fit, RESP_HZ)
  grid$x_bp <- applied$x_bp; grid$y_bp <- applied$y_bp; grid$z_bp <- applied$z_bp
  grid$mlr_pred <- applied$pred
  grid$mlr_lp   <- if (isTRUE(fit$smooth)) applied$pred else lp_filter(applied$pred, hz = RESP_HZ)

  # -- 8. Sensitivity fit (OFF by default; see the disclosure block) ----------
  fit_biopac <- NULL
  if (isTRUE(sensitivity)) {
    warning("Participant ", pid, ": the BioPac-target sensitivity fit computes a ",
            "between-device correlation. This must not run while the internal ",
            "pilot protection is live.", call. = FALSE)
    b2 <- accel$sample_ms[accel$phase == "baseline"]
    m  <- grid$epoch_ms >= min(b2) & grid$epoch_ms <= max(b2)
    fit_biopac <- fit_calibration(
      grid[m, c("epoch_ms", "x", "y", "z")] |> stats::setNames(c("t_ms", "x", "y", "z")),
      anchor_ms = anchor, period_ms = CALIB_PERIOD_MS, hz = RESP_HZ,
      target = "biopac", biopac = grid$biopac_breath[m], pid = pid)
  }

  # -- 9. Assemble ------------------------------------------------------------
  #
  # NO agreement quantity appears below. No per-trial belt-versus-BioPac
  # correlation, no r_summary. See the disclosure block at the top.
  out <- list(
    participant_id         = pid,
    session_start_epoch_ms = session_start_epoch_ms,
    biopac = list(
      breath_25hz = breath_ds, hr_250hz = hr_ds,
      events = events, trial_starts = starts,
      hz_breath = RESP_HZ, hz_hr = CARD_HZ, raw_hz = raw_hz,
      acq_file = basename(acq_path), seat = seat, rig = rig,
      breath_channel = chans[["breath"]], heart_channel = chans[["heart"]]
    ),
    belt = list(
      accel_grid = grid,
      hz         = RESP_HZ,
      # Fields the extraction script requires. It hard-fails without them.
      calib_target      = fit$calib_target,
      calib_model_label = fit$calib_model_label,
      calib_lag_ms      = fit$calib_lag_ms,
      mlr_r_calib       = fit$mlr_r_calib,
      # Additions, see docs/discrepancies.md C5 and C6.
      mlr_r_calib_lagcorr = fit$mlr_r_calib_lagcorr,
      model_margin        = fit$model_margin,
      calib_flag          = fit$calib_flag,
      all_model_r         = fit$all_model_r,
      bias = fit$bias, weights = fit$weights,
      band = fit$band, smooth = fit$smooth,
      calib_anchor_ms = anchor, calib_window_ms = win,
      pacer_overshoot_ms = over$delta_ms, pacer_overshoot_sd = over$delta_sd,
      calib_period_effective_ms = eff_per,
      calib_overrun_ms = chk$overrun_ms,
      sensitivity_biopac = fit_biopac
    ),
    alignment = list(
      trial_table    = align,
      drift_fit      = drift,
      drift_ms_total = unname(stats::coef(drift)[2] * (nrow(align) - 1)),
      residual_sd_ms = resid_sd          # required by the extraction script
    ),
    flags = flags,
    provenance = list(
      prepped_at = as.character(Sys.time()),
      radlab_commit = "98b2dca",
      accel_ms_per_sample = ACCEL_MS_PER_SAMPLE,
      filter_order = CALIB_ORDER, pad_sec = CALIB_PAD_SEC
    )
  )

  if (length(flags)) for (f in flags) .msg("FLAG: %s", f)
  if (write) {
    dir.create(paths$output_dir, recursive = TRUE, showWarnings = FALSE)
    f <- file.path(paths$output_dir, paste0(pid, "_physio.rds"))
    saveRDS(out, f); .msg("wrote %s", basename(f))
  }
  invisible(out)
}
