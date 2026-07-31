# =============================================================
#  Intero2025_RespirationFunctions.R
#  Within-trial respiratory analysis, plotting, alignment, QC.
#
#  Preprocessing (filtering, downsampling, normalisation) is
#  handled upstream by run_pipeline() in breath_pipeline.R.
#  Functions here expect a pre-processed signal at whatever
#  effective sample rate run_pipeline() produced.
# =============================================================


# -------------------------------------------------------------
#  analyze_respiration
#
#  Derives observed breath durations for a single trial using
#  peak and trough data pre-computed by run_pipeline() on the
#  full waveform.
#
#  Algorithm:
#   1. Filter pipeline troughs to the trial window.
#   2. If fewer than 5, synthesise a trough at the window edge where
#      there is a peak between that edge and the nearest real trough
#      (i.e. the edge sits inside an unclosed breath cycle).
#      START edge: add trial_start if a peak precedes the first trough.
#      END edge:   add trial_stop  if a peak follows  the last  trough.
#   3. Expanded trial window = time of outermost included trough.
#   4. Filter pipeline peaks to the expanded window.
#   5. Compute breath durations as diff(trough_abs) — this works
#      correctly for real troughs and synthetic edge troughs alike.
#   6. n_breaths = n_troughs - 1.
#
#  All times in the return value are local (seconds from
#  expanded_start_s) so they align with the plot signal slice.
#
#  Arguments:
#    pipeline_trough_times — pipelineResult$trough_times
#    pipeline_peak_times   — pipelineResult$peak_times
#    trial_start_s         — trial start in recording seconds
#    trial_stop_s          — trial stop  in recording seconds
#    sampling_rate         — pipelineResult$final_fs
#    expected_breaths      — expected breaths per trial (for QC)
# -------------------------------------------------------------
analyze_respiration <- function(pipeline_trough_times,
                                pipeline_peak_times,
                                trial_start_s,
                                trial_stop_s,
                                sampling_rate    = 25,
                                expected_breaths = 4,
                                pad_s            = 1) {

  # Padded search window — peaks and troughs are searched in a wider
  # window so that events just outside the nominal trial boundary are
  # not missed.  Timing outputs (trough_times, peak_times) remain in
  # their original recording-absolute coordinates.
  search_start <- trial_start_s - pad_s
  search_stop  <- trial_stop_s  + pad_s

  # 1. Troughs within the padded window
  in_window  <- pipeline_trough_times >= search_start &
                pipeline_trough_times <= search_stop
  trough_abs <- pipeline_trough_times[in_window]

  # 2. If still < 5 troughs, synthesise at the window edge where needed.
  #
  #    A synthetic trough is added at the window edge only when there is
  #    a peak between that edge and the nearest real trough — i.e. the
  #    edge sits inside a breath cycle whose boundary falls outside the
  #    window.  In that case the window edge is a principled proxy for
  #    the missing trough (the pacer always starts/ends at a trough).
  #
  #    START edge: is there a peak between trial_start_s and the first
  #                trough in the window (or the end of the window if no
  #                trough exists)?  If yes → synthesise trough at start.
  #    END edge:   is there a peak between the last trough in the window
  #                (or the start if no trough exists) and trial_stop_s?
  #                If yes → synthesise trough at end.

  # Peaks that fall inside the padded window
  peaks_in_window <- pipeline_peak_times[
    pipeline_peak_times >= search_start &
    pipeline_peak_times <= search_stop
  ]

  # --- START edge ---
  if (length(trough_abs) < 5 && length(peaks_in_window) > 0) {
    first_peak <- peaks_in_window[1]
    no_trough_before_first_peak <- !any(
      pipeline_trough_times >= search_start &
      pipeline_trough_times <  first_peak
    )
    if (no_trough_before_first_peak) {
      trough_abs <- c(trial_start_s, trough_abs)
      message(sprintf("    Synthesised trough at trial start (%.3f s)", trial_start_s))
    }
  }

  # --- END edge ---
  if (length(trough_abs) < 5 && length(peaks_in_window) > 0) {
    last_peak <- peaks_in_window[length(peaks_in_window)]
    no_trough_after_last_peak <- !any(
      pipeline_trough_times >  last_peak &
      pipeline_trough_times <= search_stop
    )
    if (no_trough_after_last_peak) {
      trough_abs <- c(trough_abs, trial_stop_s)
      message(sprintf("    Synthesised trough at trial end   (%.3f s)", trial_stop_s))
    }
  }

  # 3. Expanded window spans the outermost included troughs, but is
  #    guaranteed to be at least as wide as the nominal trial window
  #    so the expected signal overlay always fits in the plot.
  expanded_start_s <- if (length(trough_abs) > 0) min(trough_abs) else trial_start_s
  expanded_stop_s  <- if (length(trough_abs) > 0) max(trough_abs) else trial_stop_s

  # Floor: never clip before trial_stop_s so the expected waveform always
  # fits — detection gaps should not shorten the visible window.
  expanded_stop_s  <- max(expanded_stop_s, trial_stop_s)

  # 4. Local trough times (relative to expanded_start_s)
  trough_times_local <- trough_abs - expanded_start_s

  # 5. Filter peaks to expanded window and make local
  in_peak_window <- pipeline_peak_times >= expanded_start_s &
                    pipeline_peak_times <= expanded_stop_s
  peak_times_local <- pipeline_peak_times[in_peak_window] - expanded_start_s

  # 6. Breath durations — computed directly from trough timing.
  #    diff(trough_abs) gives the duration of each breath between consecutive
  #    troughs, including synthetic edge troughs (which contribute real
  #    durations: trial_start → first_trough, last_trough → trial_stop).
  breath_durations_vec <- if (length(trough_abs) >= 2) diff(trough_abs) else numeric(0)

  durations <- data.frame(
    breath_number    = seq_along(breath_durations_vec),
    duration_seconds = breath_durations_vec
  )

  list(
    durations          = durations,
    trough_times       = trough_times_local,   # local seconds (from expanded_start_s)
    peak_times         = peak_times_local,      # local seconds (from expanded_start_s)
    n_breaths_detected = length(trough_abs) - 1,
    n_troughs_detected = length(trough_abs),
    expected_breaths   = expected_breaths,
    sampling_rate      = sampling_rate,
    trial_start_s      = trial_start_s,         # nominal trial start (recording seconds)
    expanded_start_s   = expanded_start_s,      # recording seconds (≤ trial_start_s)
    expanded_stop_s    = expanded_stop_s         # recording seconds
  )
}


# -------------------------------------------------------------
#  plot_respiration_analysis
#
#  Plots the respiratory signal clipped to the alignment window
#  (the span of the peak-anchored expected waveform), with the
#  expected overlay (dotted grey), observed peaks (red) and
#  troughs (green) restricted to the same window.
#
#  Coordinate frames:
#    recording-absolute : seconds in pipelineResult time axis
#    trial frame        : seconds from trial_start_s (= trialSignal t=0)
#    local/plot frame   : seconds from plot_start (window_start_s in trial frame)
#
#  Arguments:
#    processedSignal   — pipelineResult$final_signal (full recording)
#    processedTime     — pipelineResult$final_time   (full recording)
#    analysis_results  — output of analyze_respiration()
#    sampling_rate     — pipelineResult$final_fs
#    expected_signal   — alignResults$adjExpected (trial frame, t=0 at trial_start_s)
#    window_start_s    — alignResults$window_start_s (trial frame; NULL → full trough window)
#    window_end_s      — alignResults$window_end_s   (trial frame; NULL → full trough window)
#    best_cor          — alignResults$best_cor
#    save_path / width / height / save_plots / show_plots — as before
# -------------------------------------------------------------
plot_respiration_analysis <- function(processedSignal,
                                      processedTime,
                                      analysis_results,
                                      sampling_rate    = 25,
                                      expected_signal  = NULL,
                                      window_start_s   = NULL,
                                      window_end_s     = NULL,
                                      best_cor         = NULL,
                                      mae              = NULL,
                                      save_path        = NULL,
                                      width            = 10,
                                      height           = 5,
                                      save_plots       = TRUE,
                                      show_plots       = FALSE) {
  library(ggplot2)

  trial_start    <- analysis_results$trial_start_s    # recording-absolute
  expanded_start <- analysis_results$expanded_start_s # recording-absolute

  # Determine plot window in recording-absolute seconds.
  # window_start_s / window_end_s are in trial frame (t=0 = trial_start_s).
  use_align_window <- !is.null(window_start_s) && !is.na(window_start_s) &&
                      !is.null(window_end_s)   && !is.na(window_end_s)

  if (use_align_window) {
    plot_start_abs <- trial_start + window_start_s
    plot_end_abs   <- trial_start + window_end_s
  } else {
    plot_start_abs <- expanded_start
    plot_end_abs   <- analysis_results$expanded_stop_s
  }

  # If an expected signal is provided, ensure the plot window is always
  # wide enough to show it in full — detection gaps should never clip
  # the expected waveform overlay.
  if (!is.null(expected_signal) && length(expected_signal) > 0) {
    exp_end_abs <- trial_start + (length(expected_signal) - 1L) / sampling_rate
    plot_end_abs <- max(plot_end_abs, exp_end_abs)
  }

  # Slice the full recording to the plot window
  win_idx <- processedTime >= plot_start_abs & processedTime <= plot_end_abs
  sig  <- processedSignal[win_idx]
  time <- processedTime[win_idx] - plot_start_abs   # local seconds (t=0 at plot_start_abs)

  if (length(sig) == 0) {
    warning("plot_respiration_analysis: no samples in window — skipping plot")
    return(invisible(NULL))
  }

  df <- data.frame(time = time, signal = sig)

  # Trough and peak markers are in expanded_start frame; convert to plot frame.
  marker_offset <- expanded_start - plot_start_abs

  troughs_df <- data.frame(time = analysis_results$trough_times + marker_offset)
  troughs_df <- troughs_df[troughs_df$time >= min(time) & troughs_df$time <= max(time), ,
                            drop = FALSE]
  if (nrow(troughs_df) > 0)
    troughs_df$value <- approx(time, sig, xout = troughs_df$time, rule = 2)$y

  peaks_df <- data.frame(time = analysis_results$peak_times + marker_offset)
  peaks_df  <- peaks_df[peaks_df$time >= min(time) & peaks_df$time <= max(time), ,
                         drop = FALSE]
  if (nrow(peaks_df) > 0)
    peaks_df$value <- approx(time, sig, xout = peaks_df$time, rule = 2)$y

  mae_label <- if (!is.null(mae) && !is.na(mae))
    sprintf("  |  MAE = %.3fs", mae) else ""

  p <- ggplot(df, aes(x = time, y = signal)) +
    geom_line(color = "blue", linewidth = 0.8) +
    theme_minimal() +
    labs(title = sprintf("Respiration Analysis  [%d breaths detected]%s",
                         analysis_results$n_breaths_detected, mae_label),
         x = "Time (seconds)", y = "Respiration Signal")

  # Expected overlay: adjExpected is in trial frame (t=0 at trial_start_s).
  # Convert to plot frame: plot_t = trial_t - window_start_s
  if (!is.null(expected_signal) && length(expected_signal) > 0) {
    exp_trial_t <- (seq_along(expected_signal) - 1L) / sampling_rate
    exp_plot_t  <- exp_trial_t - (if (use_align_window) window_start_s else
                                    (expanded_start - trial_start))

    obs_range <- range(sig, na.rm = TRUE)
    exp_range <- range(expected_signal, na.rm = TRUE)
    exp_scaled <- if (diff(exp_range) > 0)
      (expected_signal - exp_range[1]) / diff(exp_range) * diff(obs_range) + obs_range[1]
    else
      rep(mean(obs_range), length(expected_signal))

    df_exp <- data.frame(time = exp_plot_t, signal = exp_scaled)
    # When an alignment window is active, clip the overlay to that window
    # so padding values outside the aligned region are never shown.
    # Without a window, show the full expected waveform.
    if (use_align_window)
      df_exp <- df_exp[df_exp$time >= 0 & df_exp$time <= (window_end_s - window_start_s), ,
                       drop = FALSE]
    if (nrow(df_exp) > 0)
      p <- p + geom_line(data = df_exp, aes(x = time, y = signal),
                         color = "grey40", linewidth = 0.7, linetype = "dotted")
  }

  if (nrow(peaks_df) > 0)
    p <- p + geom_point(data = peaks_df, aes(x = time, y = value),
                        color = "red", size = 3, shape = 19)

  if (nrow(troughs_df) > 0)
    p <- p + geom_point(data = troughs_df, aes(x = time, y = value),
                        color = "darkgreen", size = 3, shape = 19)

  if (save_plots && !is.null(save_path))
    ggsave(filename = save_path, plot = p, width = width, height = height, dpi = 120)

  if (show_plots) return(p)
}


# -------------------------------------------------------------
#  calculate_resp_freq_fft
# -------------------------------------------------------------
calculate_resp_freq_fft <- function(breath_data, sampling_rate = 25) {
  breath_detrended <- breath_data - mean(breath_data)
  fft_result       <- fft(breath_detrended)
  psd              <- abs(fft_result)^2
  n                <- length(breath_data)
  freqs            <- (0:(n - 1)) * sampling_rate / n
  valid_range      <- freqs >= 0.1 & freqs <= 0.5
  dominant_freq    <- freqs[valid_range][which.max(psd[valid_range])]
  dominant_freq * 60
}


# -------------------------------------------------------------
#  getExpectedSignal
#  Builds an idealised breath waveform for a trial given its
#  salience and delta parameters. Normalised to ±1 to match the
#  z-scored pipeline signal. Uses the native SR because
#  alignSignals works on the raw-SR signal.
# -------------------------------------------------------------
getExpectedSignal <- function(sal, delta, SR, NUMBREATHS, STARTDUR) {
  changeVal    <- 1 + delta
  changeAmount <- changeVal ^ (1 / (NUMBREATHS - 1))

  if (delta == 0) {
    expected <- rep(STARTDUR, NUMBREATHS)
  } else {
    if (sal == "Low") {
      expected <- c(
        STARTDUR,
        STARTDUR * changeAmount,
        STARTDUR * (changeAmount ^ 2),
        STARTDUR * (changeAmount ^ 3)
      )
    } else {
      expected <- c(
        STARTDUR,
        STARTDUR,
        STARTDUR * (1 + delta),
        STARTDUR * (1 + delta)
      )
    }
  }

  amplitude <- 1  # signal is z-scored; normalise expected to ±1
  segments  <- vector("list", length(expected))

  for (thisBreath in seq_along(expected)) {
    duration <- expected[thisBreath]
    n_samps  <- round(SR * duration)
    # Exclude the right endpoint (t = duration) so consecutive segments
    # don't share a duplicate zero at their join.
    # The final segment keeps its endpoint so the waveform ends at sin=0.
    if (thisBreath < length(expected)) {
      t <- seq(0, duration, length.out = n_samps + 1L)[seq_len(n_samps)]
    } else {
      t <- seq(0, duration, length.out = n_samps + 1L)
    }
    segments[[thisBreath]] <- amplitude * sin(2 * pi * (1 / duration) * t + 3 * pi / 2)
  }
  expectedSignal <- unlist(segments)

  expectedDurations <- data.frame(
    breath_number    = seq_along(expected),
    duration_seconds = expected
  )

  list(expectedDurations = expectedDurations,
       expectedSignal    = expectedSignal)
}


# -------------------------------------------------------------
#  alignSignals
#
#  Aligns the expected waveform to the observed signal by
#  anchoring the FIRST EXPECTED PEAK to the FIRST OBSERVED PEAK,
#  then computes a Pearson correlation only within the span of the
#  shifted expected waveform.
#
#  Why this approach?
#    The pacer's timing is well-defined: the first peak of the
#    expected waveform always occurs at STARTDUR/2 seconds
#    (= the halfway point of the first breath, where sin = π/2).
#    Anchoring to the first observed peak removes any latency from
#    the participant's start of the trial, and restricts the
#    correlation window to exactly the expected waveform duration —
#    neither more nor less signal is included.
#
#  Arguments:
#    signal        — observed signal for the trial (numeric vector)
#    expectedSignal— idealised waveform from getExpectedSignal()
#    SR            — samples per second
#    peak_times_s  — observed peak times in seconds, relative to
#                    the start of `signal` (element 1 = t=0).
#                    If NULL or empty, the signal maximum is used.
#    show_plots    — legacy; no longer draws plots (plotting is
#                    handled by plot_respiration_analysis)
#
#  Returns a list with:
#    lag_samples     — integer offset (obs_peak_samp - exp_peak_samp)
#    lag_s           — same in seconds
#    best_cor        — Pearson r within the overlap window
#    adjExpected     — expected signal placed into a vector of the
#                      same length as `signal`, padded outside the
#                      window with the trough value (expectedSignal[1])
#    window_start_s  — start of the analysis window (seconds from
#                      start of `signal`)
#    window_end_s    — end   of the analysis window (same reference)
# -------------------------------------------------------------
alignSignals <- function(signal, expectedSignal, SR,
                         peak_times_s = NULL,
                         STARTDUR     = 4,
                         show_plots   = FALSE) {   # show_plots kept for API compatibility

  if (!is.numeric(signal) || !is.numeric(expectedSignal))
    stop("Both signals must be numeric vectors")
  if (length(signal) == 0 || length(expectedSignal) == 0)
    stop("Signals must not be empty")
  if (SR <= 0)
    stop("SR must be a positive number")

  lSignal   <- length(signal)
  lExpected <- length(expectedSignal)

  # ---- First expected peak: analytical position ----
  # The expected waveform is a sine starting at a trough (sin(3π/2) = -1),
  # so the first breath peak always occurs at exactly STARTDUR/2 seconds
  # into the signal, regardless of salience or direction.
  #
  # DO NOT use which.max(expectedSignal): because all breath amplitudes
  # are identical (= 1), which.max finds whichever breath cycle happens
  # to land nearest to sin = 1.0 due to floating-point discretisation of
  # the sine at different periods. For deceleration and NoChange trials
  # this is systematically the LAST breath, not the first — causing the
  # expected overlay to be anchored to the wrong end of the signal, and
  # all but 1–2 breaths fall outside the trial window and are clipped.
  #
  # The correct anchor is always STARTDUR/2 * SR samples from the start.
  first_exp_peak_samp <- round(STARTDUR / 2 * SR) + 1L   # 1-based

  # ---- First observed peak ----
  if (!is.null(peak_times_s) && length(peak_times_s) > 0) {
    # Use the first peak time that falls within the signal window
    valid_peaks <- peak_times_s[peak_times_s >= 0 & peak_times_s <= (lSignal - 1) / SR]
    if (length(valid_peaks) > 0) {
      first_obs_peak_samp <- max(1L, min(lSignal,
                                         round(valid_peaks[1] * SR) + 1L))
    } else {
      first_obs_peak_samp <- which.max(signal)   # fallback
    }
  } else {
    first_obs_peak_samp <- which.max(signal)     # fallback
  }

  # ---- Alignment offset ----
  # Positive shift_samp → expected is delayed relative to observed
  # (observed peak arrived later than the expected peak in the waveform)
  shift_samp <- first_obs_peak_samp - first_exp_peak_samp
  lag_s      <- shift_samp / SR

  # ---- Overlap window ----
  # In observed-signal coordinates, the expected waveform covers:
  #   samples (shift_samp + 1) through (shift_samp + lExpected)
  obs_start <- max(1L,       shift_samp + 1L)
  obs_end   <- min(lSignal,  shift_samp + lExpected)
  exp_start <- max(1L,       1L - shift_samp)
  exp_end   <- min(lExpected, lSignal - shift_samp)

  # Guard: degenerate window
  if (obs_start > obs_end || exp_start > exp_end || (obs_end - obs_start) < 2L) {
    warning("alignSignals: overlap window is empty or too short — returning NA correlation")
    pad_val     <- expectedSignal[1]
    adjExpected <- rep(pad_val, lSignal)
    return(list(lag_samples    = shift_samp,
                lag_s          = lag_s,
                best_cor       = NA_real_,
                adjExpected    = adjExpected,
                window_start_s = NA_real_,
                window_end_s   = NA_real_))
  }

  obs_win <- signal[obs_start:obs_end]
  exp_win <- expectedSignal[exp_start:exp_end]

  # ---- Correlation within window ----
  # Min-max normalise both to [-1, +1] before computing r so that
  # amplitude differences don't affect the shape comparison.
  minmax <- function(x) {
    r <- range(x, na.rm = TRUE)
    if (diff(r) < .Machine$double.eps) return(rep(0, length(x)))
    2 * (x - r[1]) / diff(r) - 1
  }
  best_cor <- cor(minmax(obs_win), minmax(exp_win), use = "complete.obs")

  # ---- adjExpected: expected placed in full signal frame ----
  pad_val     <- expectedSignal[1]   # trough value (sin 3π/2 = -1 * amplitude)
  adjExpected <- rep(pad_val, lSignal)
  adjExpected[obs_start:obs_end] <- exp_win

  window_start_s <- (obs_start - 1L) / SR
  window_end_s   <- (obs_end   - 1L) / SR

  list(
    lag_samples    = shift_samp,
    lag_s          = lag_s,
    best_cor       = best_cor,
    adjExpected    = adjExpected,
    window_start_s = window_start_s,
    window_end_s   = window_end_s
  )
}


# -------------------------------------------------------------
#  checkParticipantFiles
#
#  Loads the .acq file, checks logs and triggers, and extracts
#  breath and heart channel data. Returns resp_channel (1 for
#  R-side, 2 for L-side) so the caller can pass it directly to
#  run_pipeline().
#
#  Returns a list with:
#    $resp_channel  — integer, 1 (R) or 2 (L)
#    $breath_data   — raw numeric vector for the whole recording
#    $heart_data    — raw numeric vector for the whole recording
#    $SR            — native sampling rate in Hz
#    $startIndices  — trigger-based start sample indices
#    $abcode        — integer QC code (2=ok, 1=one trigger, 0=no trigger, etc.)
#    $abnormal      — logical, TRUE if any hard problem found
#    $nLogs / $nTriggers — counts for downstream reporting
# -------------------------------------------------------------
checkParticipantFiles <- function(currentId, condLookup, fileList, physioPath, bioread,
                                  expectedLogs         = 2,
                                  expectedTriggerVal_R = 1,
                                  expectedTriggerVal_L = 16) {

  qc <- list(id           = currentId,
             abnormal     = FALSE,
             abcode       = NA,
             notes        = character(0),
             nLogs        = 0,
             firstCond    = NA,
             side         = NA,
             fileName     = NA,
             SR           = NA,
             resp_channel = NA,
             nTriggers    = 0,
             startIndices = NULL,
             breath_data  = NULL,
             heart_data   = NULL)

  flag <- function(msg, abnormal = FALSE) {
    qc$notes <<- c(qc$notes, msg)
    message(msg)
    if (abnormal) qc$abnormal <<- TRUE
  }

  flag(paste0("--- QC Report for Participant: ", currentId, " ---"))

  # 1. BEHAVIORAL LOG FILES ----------------------------------------
  logFileIx <- which(condLookup$id %in% currentId)
  nLogs     <- length(logFileIx)
  qc$nLogs  <- nLogs

  if (nLogs == expectedLogs) {
    flag(paste("LOGS [OK]: Found expected", nLogs, "task file(s)."))
  } else if (nLogs == 0) {
    flag("LOGS [ERROR]: No behavioral log files found.", abnormal = TRUE)
  } else {
    flag(paste("LOGS [WARNING]: Expected", expectedLogs, "log(s), found", nLogs, "."),
         abnormal = TRUE)
    pLogs           <- condLookup[logFileIx, ]
    foundSessions   <- sort(unique(pLogs$ses))
    missingSessions <- setdiff(seq_len(expectedLogs), foundSessions)
    flag(paste("  Sessions found:  ", paste(foundSessions,   collapse = ", ")))
    flag(paste("  Sessions missing:", paste(missingSessions, collapse = ", ")))
  }

  if (nLogs > 0) {
    pLogs        <- condLookup[logFileIx, ]
    firstCond    <- pLogs[pLogs$ses == 1, "currentCondition"]
    qc$firstCond <- if (length(firstCond) > 0) firstCond[[1]] else NA
    flag(paste("  First condition:", qc$firstCond))
  } else {
    flag("  First condition: UNKNOWN (no logs found).", abnormal = TRUE)
  }

  # 2. PHYSIO FILE -------------------------------------------------
  after_L <- grep(paste0("L[^R]*", currentId), fileList)
  after_R <- grep(paste0("R[^L]*", currentId), fileList)

  if (length(after_L) > 0 && length(after_R) > 0) {
    flag("PHYSIO [ERROR]: Files found for BOTH sides — manual review required.",
         abnormal = TRUE)
    qc$abcode <- 99; return(qc)
  } else if (length(after_L) > 1 || length(after_R) > 1) {
    side_label <- if (length(after_L) > 1) "L" else "R"
    flag(paste0("PHYSIO [ERROR]: Multiple ", side_label, "-side files found."),
         abnormal = TRUE)
    qc$abcode <- 98; return(qc)
  } else if (length(after_L) == 1) {
    qc$side <- "L"; qc$fileName <- fileList[after_L]
    flag(paste("PHYSIO [OK]: Left-side file found:", qc$fileName))
  } else if (length(after_R) == 1) {
    qc$side <- "R"; qc$fileName <- fileList[after_R]
    flag(paste("PHYSIO [OK]: Right-side file found:", qc$fileName))
  } else {
    flag("PHYSIO [ERROR]: No physio file found.", abnormal = TRUE)
    qc$abcode <- 0; return(qc)
  }

  # 3. READ PHYSIO FILE --------------------------------------------
  fullFileName <- file.path(physioPath, qc$fileName)
  data <- tryCatch({
    d <- bioread$read_file(fullFileName)
    qc$SR <- as.numeric(d$samples_per_second)
    flag(paste("PHYSIO [OK]: File loaded. SR:", qc$SR, "Hz"))
    d
  }, error = function(e) {
    flag(paste("PHYSIO [ERROR]: Could not read file:", e$message), abnormal = TRUE)
    qc$abcode <<- -1
    NULL
  })

  if (is.null(data)) return(qc)

  # 4. EXTRACT CHANNELS --------------------------------------------
  # R-side: breath = ch1, heart = ch3, trigger value = expectedTriggerVal_R
  # L-side: breath = ch2, heart = ch4, trigger value = expectedTriggerVal_L
  if (qc$side == "R") {
    qc$resp_channel <- 1
    qc$breath_data  <- as.numeric(data$channels[[1]]$data)
    qc$heart_data   <- as.numeric(data$channels[[3]]$data)
    triggerVal      <- expectedTriggerVal_R
  } else {
    qc$resp_channel <- 2
    qc$breath_data  <- as.numeric(data$channels[[2]]$data)
    qc$heart_data   <- as.numeric(data$channels[[4]]$data)
    triggerVal      <- expectedTriggerVal_L
  }

  # 5. TRIGGERS ----------------------------------------------------
  triggers       <- as.numeric(data$channels[[13]]$data)
  idx            <- which(c(TRUE, diff(triggers) != 0) & triggers != 0 &
                            triggers < 136 & triggers >= 1)
  uniqueTriggers <- data.frame(index = idx, value = triggers[idx])
  startTrigger   <- which(uniqueTriggers$value == triggerVal)
  qc$nTriggers   <- length(startTrigger)

  if (qc$nTriggers == 0) {
    flag(paste("TRIGGERS [ERROR]: No valid start triggers (expected:", triggerVal, ")."),
         abnormal = TRUE)
    qc$abcode <- 0
  } else if (qc$nTriggers == expectedLogs) {
    flag(paste("TRIGGERS [OK]: Found", qc$nTriggers, "start trigger(s)."))
    qc$startIndices <- uniqueTriggers[startTrigger, "index"]
    qc$abcode <- 2
  } else if (qc$nTriggers == 1) {
    flag("TRIGGERS [WARNING]: Only 1 of 2 start triggers found.", abnormal = TRUE)
    qc$startIndices <- uniqueTriggers[startTrigger, "index"]
    qc$abcode <- 1
  } else {
    flag(paste("TRIGGERS [WARNING]: Unexpected trigger count:", qc$nTriggers),
         abnormal = TRUE)
    qc$abcode <- 3
  }

  flag(paste0("--- QC Complete | Abnormal: ", qc$abnormal,
              " | Abcode: ", qc$abcode, " ---"))
  return(qc)
}


# -------------------------------------------------------------
#  augment_trial_extrema
#
#  When analyze_respiration finds fewer than expected_breaths,
#  this function re-runs find_extrema on just the trial signal
#  with a lower amplitude_min to recover peaks/troughs that the
#  global pipeline threshold may have clipped.
#
#  New detections are only accepted if they fall in a gap —
#  i.e. no existing peak/trough lies within `min_gap_s` seconds.
#  This ensures pipeline detections are never overridden or
#  crowded, and the retry can only fill genuinely empty regions.
#
#  Arguments:
#    trial_signal          — processed signal for the trial window
#    trial_start_s         — recording-absolute start of the window
#    pipeline_peak_times   — full-recording peak times (recording-abs s)
#    pipeline_trough_times — full-recording trough times (recording-abs s)
#    SR                    — samples per second
#    amplitude_min         — Khodadad threshold for local retry (default 0.1)
#    min_gap_s             — minimum seconds from any existing detection
#                            for a new one to be accepted (default = SR/2)
#    expected_breaths      — target breath count (default 4)
#
#  Returns a list with:
#    peak_times   — augmented peak times   (recording-abs seconds)
#    trough_times — augmented trough times (recording-abs seconds)
#    n_added_peaks   — count of peaks added
#    n_added_troughs — count of troughs added
# -------------------------------------------------------------
augment_trial_extrema <- function(trial_signal,
                                  trial_start_s,
                                  pipeline_peak_times,
                                  pipeline_trough_times,
                                  SR,
                                  amplitude_min    = 0.1,
                                  min_gap_s        = NULL,
                                  expected_breaths = 4) {

  if (is.null(min_gap_s)) min_gap_s <- 1 / SR * (SR / 2)  # half a second at any SR

  # Run local extrema detection on the trial signal
  local_ext <- find_extrema(trial_signal, amplitude_min = amplitude_min)

  # Convert sample indices to recording-absolute seconds
  # (sample 1 of trial_signal corresponds to trial_start_s)
  local_peak_times   <- trial_start_s + (local_ext$peaks   - 1L) / SR
  local_trough_times <- trial_start_s + (local_ext$troughs - 1L) / SR

  # Helper: keep only times that are at least min_gap_s from all reference times
  filter_new <- function(new_times, ref_times) {
    if (length(new_times) == 0) return(new_times)
    if (length(ref_times)  == 0) return(new_times)
    keep <- sapply(new_times, function(t)
      all(abs(t - ref_times) >= min_gap_s))
    new_times[keep]
  }

  # All existing pipeline times in this window (for gap checking both peaks and troughs
  # against each other to avoid inserting a peak right next to a trough)
  all_existing <- c(pipeline_peak_times, pipeline_trough_times)

  added_peaks   <- filter_new(local_peak_times,   all_existing)
  added_troughs <- filter_new(local_trough_times, all_existing)

  # Merge and sort
  aug_peaks   <- sort(c(pipeline_peak_times,   added_peaks))
  aug_troughs <- sort(c(pipeline_trough_times, added_troughs))

  # Enforce alternation — but ONLY on detections within the trial window.
  # Pipeline detections outside the window (before trial_start_s or after
  # trial_stop_s) would produce zero/negative sample indices when converted
  # via (time - trial_start_s) * SR, corrupting enforce_alternation's logic.
  # Solution: split into in-window and out-of-window, enforce on the former,
  # then recombine.
  trial_stop_s <- trial_start_s + (length(trial_signal) - 1L) / SR

  in_win_peaks   <- aug_peaks[  aug_peaks   >= trial_start_s & aug_peaks   <= trial_stop_s]
  out_win_peaks  <- aug_peaks[!(aug_peaks   >= trial_start_s & aug_peaks   <= trial_stop_s)]
  in_win_troughs <- aug_troughs[aug_troughs >= trial_start_s & aug_troughs <= trial_stop_s]
  out_win_troughs<- aug_troughs[!(aug_troughs >= trial_start_s & aug_troughs <= trial_stop_s)]

  times_to_samp <- function(times) as.integer(round((times - trial_start_s) * SR)) + 1L

  alt <- enforce_alternation(times_to_samp(in_win_peaks),
                             times_to_samp(in_win_troughs))

  # Convert back to recording-absolute seconds and recombine with out-of-window times
  aug_peaks   <- sort(c(out_win_peaks,   trial_start_s + (alt$peaks   - 1L) / SR))
  aug_troughs <- sort(c(out_win_troughs, trial_start_s + (alt$troughs - 1L) / SR))

  n_added_peaks   <- length(aug_peaks)   - length(pipeline_peak_times)
  n_added_troughs <- length(aug_troughs) - length(pipeline_trough_times)

  if (n_added_peaks + n_added_troughs > 0)
    message(sprintf("    Local retry: added %d peak(s), %d trough(s)",
                    n_added_peaks, n_added_troughs))
  else if (n_added_peaks + n_added_troughs < 0)
    message(sprintf("    Local retry: alternation enforcement removed %d event(s)",
                    abs(n_added_peaks + n_added_troughs)))

  list(
    peak_times      = aug_peaks,
    trough_times    = aug_troughs,
    n_added_peaks   = n_added_peaks,
    n_added_troughs = n_added_troughs
  )
}


# -------------------------------------------------------------
#  compareDurations
#
#  Matches detected breaths to expected breaths by onset timing
#  rather than by positional index.
#
#  Why timing-based matching?
#    Sequential (positional) matching assumes detected breath k
#    corresponds to expected breath k.  A single missed breath in
#    the middle of a trial shifts every subsequent breath's index,
#    causing all remaining durations to be compared against the
#    wrong expected breath.  This is especially harmful for
#    high-salience trials where the critical change occurs between
#    breaths 2 and 3.
#
#  Algorithm:
#    1. Compute expected breath onset times as cumulative sum of
#       expected durations, anchored to the first detected trough
#       (so overall timing offset doesn't penalise every match).
#    2. Build a cost matrix: |detected_onset[i] - expected_onset[j]|
#    3. Greedy nearest-neighbour assignment: repeatedly pick the
#       minimum-cost unassigned pair until all expected breaths are
#       either matched or declared missing.
#    4. Unmatched expected breaths → NA duration in output.
#
#  Arguments:
#    analyzedDurations — data.frame with columns:
#                          breath_number, duration_seconds
#                        (from analyze_respiration()$durations)
#    expectedDurations — data.frame with columns:
#                          breath_number, duration_seconds
#                        (from getExpectedSignal()$expectedDurations)
#    trough_times      — numeric vector of detected trough onset
#                        times in local seconds
#                        (analyze_respiration()$trough_times)
# -------------------------------------------------------------
compareDurations <- function(analyzedDurations, expectedDurations,
                             trough_times) {

  if (nrow(expectedDurations) != 4)
    stop("expectedDurations must always have exactly 4 breaths.")

  n_detected <- nrow(analyzedDurations)
  n_expected <- nrow(expectedDurations)

  # Expected breath onset times (seconds from trial start).
  # Breath 1 starts at 0, breath k starts at sum of durations 1..(k-1).
  exp_onsets <- c(0, cumsum(expectedDurations$duration_seconds[-n_expected]))

  # Detected breath onset times = trough onset for each breath.
  # trough_times[i] is the start of breath i; there are n_detected + 1
  # troughs for n_detected complete breaths, so use first n_detected.
  det_onsets <- if (length(trough_times) >= n_detected && n_detected > 0)
    trough_times[seq_len(n_detected)]
  else
    numeric(0)

  # Anchor expected onsets to the first detected trough so that
  # a systematic offset (e.g. lag, early/late start) doesn't
  # penalise every breath match.
  if (length(det_onsets) > 0 && length(exp_onsets) > 0)
    exp_onsets_anchored <- exp_onsets + det_onsets[1]
  else
    exp_onsets_anchored <- exp_onsets

  # Greedy nearest-neighbour assignment on the cost matrix.
  # Rows = detected breaths, columns = expected breaths.
  # Returns a vector: matched_exp[i] = expected breath index for
  # detected breath i, or NA if unmatched.
  matched_det  <- rep(NA_integer_, n_detected)   # det → exp
  matched_exp  <- rep(NA_integer_, n_expected)   # exp → det (for output)
  used_det     <- logical(n_detected)
  used_exp     <- logical(n_expected)

  if (n_detected > 0 && n_expected > 0) {
    # Build full cost matrix
    cost <- outer(det_onsets, exp_onsets_anchored,
                  FUN = function(d, e) abs(d - e))

    # Greedily assign minimum-cost pairs
    for (iter in seq_len(min(n_detected, n_expected))) {
      # Mask already-used rows/columns
      cost_masked        <- cost
      cost_masked[used_det, ] <- Inf
      cost_masked[, used_exp] <- Inf

      best <- which(cost_masked == min(cost_masked), arr.ind = TRUE)[1, ]
      i_det <- best[1]; i_exp <- best[2]

      matched_det[i_det] <- i_exp
      matched_exp[i_exp] <- i_det
      used_det[i_det]    <- TRUE
      used_exp[i_exp]    <- TRUE
    }
  }

  # Build output data.frame: one row per expected breath.
  # For each expected breath, look up the matched detected duration.
  out_rows <- lapply(seq_len(n_expected), function(j) {
    exp_breath_num  <- expectedDurations$breath_number[j]
    exp_dur         <- expectedDurations$duration_seconds[j]
    det_idx         <- matched_exp[j]

    if (!is.na(det_idx)) {
      det_dur         <- analyzedDurations$duration_seconds[det_idx]
      det_breath_num  <- analyzedDurations$breath_number[det_idx]
    } else {
      det_dur         <- NA_real_
      det_breath_num  <- NA_integer_
    }

    data.frame(
      breath_number              = exp_breath_num,
      detected_breath_number     = det_breath_num,
      duration_seconds_expected  = exp_dur,
      duration_seconds_analyzed  = det_dur,
      stringsAsFactors           = FALSE
    )
  })

  merged <- do.call(rbind, out_rows)
  merged$error          <- merged$duration_seconds_analyzed - merged$duration_seconds_expected
  merged$absolute_error <- abs(merged$error)

  total_absolute_error <- sum(merged$absolute_error, na.rm = TRUE)
  n_matched            <- sum(!is.na(merged$duration_seconds_analyzed))
  n_missing            <- n_expected - n_matched
  mae                  <- if (n_matched > 0) total_absolute_error / n_matched else NA_real_

  message(paste0("Breaths matched: ", n_matched, "/", n_expected,
                 if (n_missing > 0) paste0("  [", n_missing, " missing]") else "",
                 "  |  Total absolute error: ", round(total_absolute_error, 4), "s",
                 "  |  MAE: ", round(mae, 4), "s"))

  list(comparison           = merged,
       total_absolute_error = total_absolute_error,
       mae                  = mae,
       n_matched            = n_matched,
       n_missing            = n_missing)
}
