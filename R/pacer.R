# pacer.R
#
# Analytic reconstruction of the visual pacer, and the calibration fit window.
#
# The pacer is deterministic but is NOT recorded: `pacer_radius` is a column in
# every accelerometer CSV and is empty in every row. It is reconstructed here
# from the software's own formula so that calibration weights can be fitted
# against it rather than against the stretch belt, which would be circular.
#
# Mirrors radlab BreathBelt/breathUtils.js (commit 98b2dca):
#
#   getPacerRadius(t, startMs, periodMs)
#     = (1 - Math.cos(2 * Math.PI * (t - startMs) / periodMs)) / 2
#
# Sourced by scripts/; declares no packages and installs nothing.


# ── Pacer waveform ────────────────────────────────────────────────────────────

# Pacer radius, normalised 0 to 1. 0 is fully exhaled, 1 is peak inhale.
#
# Phase convention matters and is easy to get backwards. At t == start_ms the
# radius is 0, i.e. `start_ms` is a TROUGH, which is also how breath onset is
# defined (Section 4.2). Reconstruct as -cos, never as sin. Getting this wrong
# inverts the sign of every calibration weight while leaving |r| unchanged, so
# it fails silently.
#
# Note (1 - cos(x))/2 == 0.5 - 0.5*cos(x): a DC offset plus a single cosine at
# exactly 1/period_ms. After band-passing removes the DC term this is a pure
# sinusoid at the commanded period, as the pre-registration states.
pacer_radius <- function(t_ms, start_ms, period_ms) {
  stopifnot(is.numeric(t_ms), length(period_ms) == 1L, period_ms > 0)
  (1 - cos(2 * pi * (t_ms - start_ms) / period_ms)) / 2
}

# Two-phase trial pacer: `n_base_breaths` at base_period_ms, then the remainder
# at changed_period_ms. The condition boundary is re-anchored, so the waveform
# is continuous in value (both segments are at a trough there) but not in
# derivative.
#
# Mirrors getPacerRadiusForTrial. Trigger code 11 (condition onset) is defined
# in the software but never emitted, so this boundary is computed rather than
# measured, and inherits any jitter in the trial-start code.
pacer_radius_trial <- function(t_ms, trial_start_ms, base_period_ms,
                               changed_period_ms, n_base_breaths = 2L) {
  boundary <- trial_start_ms + n_base_breaths * base_period_ms
  ifelse(
    t_ms <= boundary,
    pacer_radius(t_ms, trial_start_ms, base_period_ms),
    pacer_radius(t_ms, boundary,       changed_period_ms)
  )
}


# ── Pacer overshoot ───────────────────────────────────────────────────────────
#
# THE PACER DOES NOT RUN AT ITS NOMINAL PERIOD.
#
# Both CalibrationScreen and useTrialRunner drive the pacer as
#
#     for (i = 0; i < n; i++) await startBreath(periodMs)
#
# and useBreathCycle.startBreath RE-ANCHORS the cycle clock on every call:
#
#     cycleStartRef.current = performance.now()
#     return new Promise(r => setTimeout(r, durationMs))
#
# setTimeout fires no earlier than durationMs and usually later, and because each
# cycle restarts its clock when the previous promise resolves, the overshoot
# ACCUMULATES rather than averaging out. The pacer is therefore a sequence of
# independently anchored cycles, not the single continuous sinusoid that
# getPacerRadius assumes. The software's own fitBestModel makes the same
# assumption, so live calib_fit_r values are degraded too.
#
# The overshoot is MEASURABLE from recorded timing alone. A trial is
# n_base breaths at base_period plus n_cond at condition_period, so
#
#     trial_end - trial_onset = nominal + (n_base + n_cond) * delta
#
# giving delta directly. This uses only trial timing metadata: no outcome
# quantity is involved.
#
# Measured for 14542: delta = 276 ms per breath (SD 109 across 34 trials),
# consistent across all three conditions. Reconstructing calibration at the
# resulting 4276 ms rather than 4000 ms raises the fit from r = 0.42 to 0.58 and
# moves the estimated device lag from an implausible -240 ms to -80 ms.

# Per-breath pacer overshoot, in ms, estimated from recorded trial durations.
estimate_pacer_overshoot <- function(trials, n_breaths = 4L,
                                     n_base = 2L, base_period_ms = 4000) {
  need <- c("trial_onset_ms", "trial_end_ms", "breath_period_ms")
  if (!all(need %in% names(trials))) {
    stop("estimate_pacer_overshoot needs columns: ", paste(need, collapse = ", "))
  }
  dur     <- trials$trial_end_ms - trials$trial_onset_ms
  nominal <- n_base * base_period_ms +
             (n_breaths - n_base) * trials$breath_period_ms
  delta   <- (dur - nominal) / n_breaths
  delta   <- delta[is.finite(delta)]
  if (!length(delta)) stop("No usable trial durations for overshoot estimation.")
  list(
    delta_ms   = stats::median(delta),   # median: robust to a stalled trial
    delta_sd   = stats::sd(delta),
    n_trials   = length(delta),
    delta_mean = mean(delta)
  )
}

# Effective condition boundary within a trial, accounting for overshoot.
# The software records condition_onset_ms as exactly trial start + 8000 ms, which
# ignores the overshoot on the two baseline breaths and is therefore early.
condition_boundary_ms <- function(trial_start_ms, delta_ms,
                                  n_base = 2L, base_period_ms = 4000) {
  trial_start_ms + n_base * (base_period_ms + delta_ms)
}


# ── Calibration window ────────────────────────────────────────────────────────

CALIB_N_CYCLES     <- 4L      # hard-coded loop in CalibrationScreen.jsx.
                              # NOT constants.js CALIB_CYCLES, which is 3 and
                              # is dead code, read by nothing.
CALIB_PERIOD_MS    <- 4000    # BASE_BREATH_SPEED_S * 1000
CALIB_PACED_MS     <- CALIB_N_CYCLES * CALIB_PERIOD_MS   # 16000 NOMINAL only;
# the realised duration is CALIB_N_CYCLES * (CALIB_PERIOD_MS + delta). Pass the
# measured effective period to calib_fit_window() rather than relying on this.

# Estimate the wall-clock instant the pacer animation began.
#
# The software captures `calibStartMs <- Date.now()` in the same tick it starts
# the animation and calls beginCalibCollection(), but does NOT persist it. It has
# to be recovered from the accelerometer phase labels.
#
# The phase tag is applied per packet, and packets carry 36 samples spanning
# about 177 ms, so the calib_fixation -> calib_breathe boundary brackets the true
# onset to within roughly one packet. Taking the midpoint of that bracket halves
# the worst-case error to about +/- 88 ms rather than accepting a one-sided bias
# of up to 177 ms from using the first calib_breathe sample alone.
#
# Residual anchor error is not separable from true device lag using the
# calibration block alone: both shift the pacer against the accelerometer. The
# lag search absorbs it, which means `calib_lag_ms` carries roughly +/- 88 ms of
# anchor uncertainty on top of genuine transduction delay. Recorded as a
# limitation rather than silently ignored.
calib_anchor_ms <- function(phase, t_ms) {
  stopifnot(length(phase) == length(t_ms))
  fix <- t_ms[phase == "calib_fixation"]
  brt <- t_ms[phase == "calib_breathe"]
  if (!length(brt)) stop("No calib_breathe samples: cannot anchor the pacer.")
  first_breathe <- min(brt)
  if (!length(fix)) {
    warning("No calib_fixation samples; anchoring on first calib_breathe sample ",
            "(one-sided bias of up to one packet, about 177 ms).")
    return(first_breathe)
  }
  last_fixation <- max(fix[fix < first_breathe])
  (last_fixation + first_breathe) / 2
}

# Fit window as c(start_ms, end_ms).
#
# The `calib_breathe` phase label OVERRUNS the actual pacing. There is no
# calib_fitting label, so samples collected while fitBestModel() runs stay tagged
# calib_breathe. Measured for 14542: 19,101 ms of label against 16,000 ms of
# pacing, an overrun of 3.1 s. For contrast the `baseline` block overruns its
# nominal 120,000 ms by only 401 ms, so this is not packet granularity.
#
# Fitting across the whole label would regress roughly 16% unpaced breathing
# against a pacer that is not running, degrading the fit in a participant-specific
# way. That is precisely the variance the between-participant SD is meant to
# measure, so it would not merely add noise, it would bias the sample size.
calib_fit_window <- function(anchor_ms, period_ms = CALIB_PERIOD_MS,
                             n_cycles = CALIB_N_CYCLES) {
  c(start_ms = anchor_ms, end_ms = anchor_ms + n_cycles * period_ms)
}

# Assert the recorded block is long enough to contain the full paced window, and
# report the overrun so batch runs surface anything anomalous.
check_calib_window <- function(phase, t_ms, pid = NA_character_,
                               period_ms = CALIB_PERIOD_MS,
                               n_cycles  = CALIB_N_CYCLES) {
  brt <- t_ms[phase == "calib_breathe"]
  if (!length(brt)) stop("Participant ", pid, ": no calib_breathe samples.")
  span   <- max(brt) - min(brt)
  needed <- n_cycles * period_ms
  if (span < needed) {
    stop("Participant ", pid, ": calib_breathe spans ", round(span), " ms but ",
         needed, " ms of pacing is required. Calibration was cut short; this ",
         "participant cannot be calibrated against the pacer.")
  }
  list(span_ms = span, paced_ms = needed, overrun_ms = span - needed)
}
