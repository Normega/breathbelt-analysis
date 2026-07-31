# ============================================================
#  breath_pipeline.R
#  Preprocesses a respiratory signal through a configurable
#  5-step pipeline and detects breath peaks + trial onset.
#
#  run_pipeline() accepts a raw signal vector and its native
#  sampling rate — it does NOT load files itself. Load your
#  .acq file and extract the channel you want beforehand
#  (e.g. via checkParticipantFiles), then pass the data here.
#
#  Usage:
#    source("breath_pipeline.R")
#    result <- run_pipeline(signal_vector, native_fs)
#    plot_pipeline(result)
#
#  Utility (to inspect channel names/indices before loading):
#    list_channels("path/to/file.acq")
# ============================================================

library(signal)
library(ggplot2)
library(patchwork)


# ============================================================
#  Signal processing helpers
# ============================================================

apply_butter <- function(x, fs, cutoff_hz, order = 2, type = "low") {
  nyq <- fs / 2
  W   <- min(abs(cutoff_hz) / nyq, 0.99)
  bf  <- signal::butter(order, W, type = type)
  as.numeric(signal::filtfilt(bf, x))
}

safe_decimate <- function(x, q) {
  if (q <= 1) return(x)
  remaining <- q
  while (remaining > 1) {
    step      <- min(remaining, 13)
    x         <- as.numeric(signal::decimate(x, step))
    remaining <- remaining %/% step
    if (remaining <= 1) break
  }
  x
}

remove_baseline_median <- function(x, fs, window_s = 60) {
  hw <- max(1, floor(window_s * fs / 2))
  n  <- length(x)
  baseline <- vapply(seq_len(n), function(i) {
    median(x[max(1, i - hw):min(n, i + hw)], na.rm = TRUE)
  }, numeric(1))
  x - baseline
}

smooth_gaussian <- function(x, fs, fwhm_ms = 40) {
  sigma_samp <- (fwhm_ms / 1000) / (2 * sqrt(2 * log(2))) * fs
  hw   <- max(1, ceiling(3 * sigma_samp))
  kern <- dnorm(seq(-hw, hw), mean = 0, sd = sigma_samp)
  kern <- kern / sum(kern)
  result <- as.numeric(stats::filter(x, kern, sides = 2))
  na_idx <- which(is.na(result))
  if (length(na_idx) > 0) result[na_idx] <- x[na_idx]
  result
}

smooth_ma <- function(x, k) {
  result <- as.numeric(stats::filter(x, rep(1/k, k), sides = 2))
  na_idx <- which(is.na(result))
  if (length(na_idx) > 0) result[na_idx] <- x[na_idx]
  result
}

zscore <- function(x) {
  mu <- mean(x, na.rm = TRUE); s <- sd(x, na.rm = TRUE)
  if (s == 0) return(x - mu)
  (x - mu) / s
}

# ============================================================
#  walk_to_extremum
#
#  Refines detected peak/trough positions by walking each
#  index to the nearest true local maximum (for peaks) or
#  minimum (for troughs) on the signal.
#
#  Starting from each detected index, the algorithm expands
#  outward sample-by-sample up to walk_max_samp in each
#  direction, and returns the index of the highest (peak) or
#  lowest (trough) value found in that neighbourhood.
#
#  This corrects the small timing offsets that arise when the
#  zero-crossing segmentation bounds a segment slightly off
#  from the true extremum — the detected index is the argmax
#  within the segment, which may not be the signal maximum if
#  the segment boundary cuts the breath cycle early or late.
#
#  Arguments:
#    x             — the signal to search (z-scored, cur_sig)
#    indices       — integer vector of initial positions
#    seek_max      — TRUE for peaks, FALSE for troughs
#    walk_max_samp — maximum samples to walk in each direction
#
#  Returns a refined integer vector of the same length.
# ============================================================
walk_to_extremum <- function(x, indices, seek_max, walk_max_samp) {
  if (length(indices) == 0) return(indices)
  n <- length(x)
  vapply(indices, function(i) {
    lo  <- max(1L,  i - walk_max_samp)
    hi  <- min(n,   i + walk_max_samp)
    seg <- x[lo:hi]
    offset <- if (seek_max) which.max(seg) else which.min(seg)
    lo + offset - 1L
  }, integer(1))
}

# ============================================================
#  find_extrema()  — Khodadad (2018) zero-crossing method
#
#  Implements the respiratory extrema detection described in:
#    Khodadad et al. (2018) Physiol. Meas. 39(9):094001
#  and used as the default in NeuroKit2.
#
#  Algorithm (three steps):
#
#  1. SEGMENTATION VIA ZERO CROSSINGS
#     Find every sample where the signal crosses zero (rising or
#     falling). Between each consecutive pair of crossings, there
#     is exactly one half-cycle: search that segment for its
#     maximum (peak, in the positive half) or minimum (trough, in
#     the negative half). This guarantees one extremum per
#     half-cycle by construction — no `min_dist` refractory
#     period needed, and no double-peaks within a cycle.
#
#  2. AMPLITUDE OUTLIER REMOVAL
#     For each extremum compute the vertical distance to its two
#     adjacent neighbours (|x[extremum_k] - x[extremum_{k±1}]|).
#     Remove any extremum whose minimum adjacent distance is below
#     amplitude_min × mean(all adjacent distances).  Default
#     amplitude_min = 0.3 eliminates cardiac contamination and
#     noise spikes without touching real breath cycles.
#
#  3. SPLIT INTO PEAKS AND TROUGHS
#     After bandpass filtering and z-scoring, peaks lie in the
#     positive half of the signal and troughs in the negative
#     half.  Simply assign x[i] > 0 → peak, x[i] ≤ 0 → trough.
#     enforce_alternation() is kept as a safety net but should
#     rarely fire.
#
#  Parameters
#    x             — numeric vector (z-scored, bandpass filtered)
#    amplitude_min — fraction of mean amplitude below which an
#                    extremum is discarded as noise  (default 0.3)
#
#  Returns list(peaks, troughs) of 1-based sample indices.
# ============================================================
find_extrema <- function(x, amplitude_min = 0.3) {
  n <- length(x)

  # ---- Step 1: zero-crossing segmentation ----
  # Strict sign comparisons, same as NeuroKit2.
  # Samples exactly equal to zero are treated as positive (> 0 is FALSE),
  # meaning a sample at 0.000 is on the "small" side of the crossing.
  greater <- x > 0
  smaller <- x < 0

  risex <- which(smaller[-n] & greater[-1])  # start of upward crossing
  fallx <- which(greater[-n] & smaller[-1])  # start of downward crossing

  if (length(risex) == 0 || length(fallx) == 0) {
    message("  find_extrema: no zero crossings found — signal may be flat or not centred")
    return(list(peaks = integer(0), troughs = integer(0)))
  }

  # Determine which crossing type comes first so we know whether to expect
  # a peak or a trough in the first segment.
  start_type <- if (risex[1] < fallx[1]) "rise" else "fall"

  allx <- sort(c(risex, fallx))
  n_segs <- length(allx) - 1L

  if (n_segs < 1L) return(list(peaks = integer(0), troughs = integer(0)))

  extrema <- integer(n_segs)
  for (k in seq_len(n_segs)) {
    beg <- allx[k]
    end <- allx[k + 1L]
    seg <- x[beg:end]

    # Odd-numbered segments (k = 1, 3, 5, …):
    #   start_type == "rise" → first segment is positive half → seek maximum (peak)
    #   start_type == "fall" → first segment is negative half → seek minimum (trough)
    # Even segments: the opposite.
    seek_max <- xor(k %% 2L == 1L, start_type == "fall")
    extreme   <- if (seek_max) which.max(seg) else which.min(seg)
    extrema[k] <- beg + extreme - 1L
  }

  # ---- Step 2: amplitude outlier removal ----
  if (length(extrema) >= 2L) {
    # Vertical distances between adjacent extrema
    vert_dist <- abs(diff(x[extrema]))       # length = n_ext - 1
    mean_dist <- mean(vert_dist)

    n_ext  <- length(extrema)
    # For each extremum, minimum of its two neighbouring vertical distances
    min_adj <- numeric(n_ext)
    min_adj[1L] <- vert_dist[1L]
    if (n_ext > 2L)
      min_adj[2L:(n_ext - 1L)] <- pmin(vert_dist[-n_ext + 1L], vert_dist[-1L])
    min_adj[n_ext] <- vert_dist[n_ext - 1L]

    keep    <- min_adj >= amplitude_min * mean_dist
    extrema <- extrema[keep]

    n_removed <- sum(!keep)
    if (n_removed > 0L)
      message(sprintf("  find_extrema: removed %d low-amplitude extrema (< %.0f%% of mean)",
                      n_removed, amplitude_min * 100))
  }

  if (length(extrema) == 0L)
    return(list(peaks = integer(0), troughs = integer(0)))

  # ---- Step 3: split into peaks and troughs by sign ----
  # After z-scoring, peaks lie above zero (positive half of the signal)
  # and troughs lie below zero.
  peaks   <- extrema[x[extrema] >  0]
  troughs <- extrema[x[extrema] <= 0]

  list(peaks = as.integer(peaks), troughs = as.integer(troughs))
}

# ============================================================
#  find_extrema_prominence()  — prominence + distance method
#
#  Alternative to the Khodadad zero-crossing method. Does not
#  rely on zero crossings at all — instead finds every local
#  maximum in the signal, computes each peak's prominence, and
#  keeps only those that are sufficiently prominent and far
#  enough apart. Troughs are found the same way on the inverted
#  signal.
#
#  PROMINENCE of a peak is the minimum vertical drop required
#  to descend from the peak to any higher ground on either
#  side — i.e. how much it stands out from surrounding valleys.
#  It is invariant to baseline drift, which is why it is
#  superior to amplitude-relative-to-zero thresholding for
#  belt signals.
#
#  Algorithm:
#    1. Find all local maxima (both neighbours strictly lower).
#    2. Compute prominence for each via the standard left/right
#       base algorithm (matches MATLAB findpeaks behaviour).
#    3. Remove any peak with prominence < min_prominence.
#    4. Iteratively remove the least prominent peak that is
#       within min_dist_samp of a more prominent neighbour,
#       until no two peaks are too close (greedy by prominence,
#       same strategy as MATLAB MinPeakDistance).
#    5. Invert signal and repeat for troughs.
#
#  Arguments:
#    x              — z-scored signal (numeric vector)
#    min_dist_samp  — minimum samples between peaks
#    min_prominence — minimum prominence (in signal units)
#                     Default 0.5 works well for z-scored data.
#
#  Returns list(peaks, troughs) of 1-based sample indices.
# ============================================================
compute_prominence <- function(x, peak_idx) {
  # For each peak, prominence = peak_height - max(left_base, right_base)
  # where left_base  = min(x) between the peak and the nearest higher peak to the left
  #       right_base = min(x) between the peak and the nearest higher peak to the right
  n   <- length(x)
  np  <- length(peak_idx)
  if (np == 0) return(numeric(0))

  prom <- numeric(np)
  for (i in seq_len(np)) {
    pi  <- peak_idx[i]
    ph  <- x[pi]

    # Left base: scan left until we find a sample higher than ph or hit edge
    left_min <- if (i == 1L) {
      min(x[1:pi])
    } else {
      # nearest higher peak to the left
      higher_left <- peak_idx[seq_len(i - 1L)][x[peak_idx[seq_len(i - 1L)]] >= ph]
      if (length(higher_left) > 0L) {
        left_bound <- max(higher_left)
        min(x[left_bound:pi])
      } else {
        min(x[1:pi])
      }
    }

    # Right base: scan right until we find a sample higher than ph or hit edge
    right_min <- if (i == np) {
      min(x[pi:n])
    } else {
      higher_right <- peak_idx[(i + 1L):np][x[peak_idx[(i + 1L):np]] >= ph]
      if (length(higher_right) > 0L) {
        right_bound <- min(higher_right)
        min(x[pi:right_bound])
      } else {
        min(x[pi:n])
      }
    }

    prom[i] <- ph - max(left_min, right_min)
  }
  prom
}


find_local_maxima <- function(x) {
  n <- length(x)
  if (n < 3L) return(integer(0))
  # A local max: strictly greater than both neighbours
  which(x[-c(1L, n)] > x[-c(n - 1L, n)] &
        x[-c(1L, n)] > x[-c(1L, 2L)]) + 1L
}


find_extrema_prominence <- function(x,
                                    min_dist_samp  = 50L,   # ~2s at 25 Hz
                                    min_prominence = 0.5) {
  n <- length(x)

  # ---- Peaks --------------------------------------------------
  pk_all  <- find_local_maxima(x)

  if (length(pk_all) >= 2L) {
    prom_all <- compute_prominence(x, pk_all)

    # 1. Prominence filter
    keep   <- prom_all >= min_prominence
    pk_all <- pk_all[keep]
    prom_all <- prom_all[keep]

    # 2. Distance filter: iteratively remove least prominent peak
    #    that is within min_dist_samp of a more prominent neighbour
    if (length(pk_all) >= 2L) {
      repeat {
        dists    <- diff(pk_all)
        too_close <- which(dists < min_dist_samp)
        if (length(too_close) == 0L) break
        # For each too-close pair, mark the less prominent for removal
        to_remove <- integer(0)
        for (tc in too_close) {
          if (prom_all[tc] <= prom_all[tc + 1L])
            to_remove <- c(to_remove, tc)
          else
            to_remove <- c(to_remove, tc + 1L)
        }
        to_remove <- unique(to_remove)
        pk_all    <- pk_all[-to_remove]
        prom_all  <- prom_all[-to_remove]
      }
    }
  }

  # ---- Troughs: invert and repeat -----------------------------
  xi      <- -x
  tr_all  <- find_local_maxima(xi)

  if (length(tr_all) >= 2L) {
    prom_tr <- compute_prominence(xi, tr_all)

    keep    <- prom_tr >= min_prominence
    tr_all  <- tr_all[keep]
    prom_tr <- prom_tr[keep]

    if (length(tr_all) >= 2L) {
      repeat {
        dists     <- diff(tr_all)
        too_close <- which(dists < min_dist_samp)
        if (length(too_close) == 0L) break
        to_remove <- integer(0)
        for (tc in too_close) {
          if (prom_tr[tc] <= prom_tr[tc + 1L])
            to_remove <- c(to_remove, tc)
          else
            to_remove <- c(to_remove, tc + 1L)
        }
        to_remove <- unique(to_remove)
        tr_all    <- tr_all[-to_remove]
        prom_tr   <- prom_tr[-to_remove]
      }
    }
  }

  if (length(pk_all) > 0L)
    message(sprintf("  find_extrema_prominence: %d peaks, %d troughs (min_prom=%.2f, min_dist=%d samp)",
                    length(pk_all), length(tr_all), min_prominence, min_dist_samp))
  else
    message("  find_extrema_prominence: no peaks found — try lowering min_prominence")

  list(peaks   = as.integer(pk_all),
       troughs = as.integer(tr_all))
}


# -------------------------------------------------------------
#  enforce_alternation
#
#  Given peak and trough index vectors (into the same signal),
#  merge them into a time-ordered sequence and remove any run of
#  consecutive same-type events, keeping only the most extreme
#  (highest peak, lowest trough) from each run.
#
#  Returns a list with cleaned $peaks and $troughs index vectors.
# -------------------------------------------------------------
enforce_alternation <- function(peaks, troughs) {
  if (length(peaks) == 0 && length(troughs) == 0)
    return(list(peaks = peaks, troughs = troughs))

  # Build combined event table: index and type ("peak"/"trough")
  events <- rbind(
    if (length(peaks)   > 0) data.frame(idx = peaks,   type = "peak",   stringsAsFactors = FALSE),
    if (length(troughs) > 0) data.frame(idx = troughs, type = "trough", stringsAsFactors = FALSE)
  )
  events <- events[order(events$idx), ]

  # Walk through and collapse consecutive same-type runs.
  # Selection rule:
  #   - Consecutive troughs → keep the one closest in time to the NEXT peak
  #   - Consecutive peaks   → keep the one closest in time to the NEXT trough
  # If there is no next opposite event (end of recording), fall back to
  # keeping the last event in the run (closest to whatever comes after).
  keep <- logical(nrow(events))
  i    <- 1L
  while (i <= nrow(events)) {
    # Find end of this same-type run
    j <- i
    while (j < nrow(events) && events$type[j + 1L] == events$type[i]) j <- j + 1L

    if (i == j) {
      # Single event — always keep
      keep[i] <- TRUE
    } else {
      # Run of same-type events i:j
      # Next opposite event is at j+1 (if it exists)
      if (j < nrow(events)) {
        next_idx  <- events$idx[j + 1L]   # sample index of next opposite event
        run_idxs  <- events$idx[i:j]
        distances <- abs(run_idxs - next_idx)
        best      <- i - 1L + which.min(distances)
      } else {
        # No next opposite — keep the last in the run
        best <- j
      }
      keep[best] <- TRUE
    }

    i <- j + 1L
  }

  events_clean <- events[keep, ]
  list(
    peaks   = events_clean$idx[events_clean$type == "peak"],
    troughs = events_clean$idx[events_clean$type == "trough"]
  )
}


find_first_trial_onset <- function(peaks, time_vec,
                                   min_breath_sec = 3.5, run_length = 4) {
  if (length(peaks) < run_length + 1) return(NULL)
  intervals <- diff(time_vec[peaks])
  slow <- intervals >= min_breath_sec
  win  <- run_length - 1
  for (i in seq_len(length(slow) - win + 1))
    if (all(slow[i:(i + win - 1)]))
      return(list(onset_time = time_vec[peaks[i]],
                  peak_start = peaks[i], run_start = i))
  NULL
}


# ============================================================
#  Utility: list all channels in an .acq file
#  (Requires reticulate + bioread to be loaded by the caller)
# ============================================================
list_channels <- function(acq_file) {
  if (!exists("bioread")) stop("bioread must be imported before calling list_channels()")
  dat <- bioread$read_file(acq_file)
  cat(sprintf("%-4s %-30s %-10s %-10s\n", "Idx", "Name", "Units", "fs (Hz)"))
  cat(strrep("-", 60), "\n")
  for (i in seq_along(dat$channels)) {
    ch <- dat$channels[[i]]
    cat(sprintf("%-4d %-30s %-10s %-10.1f\n",
                i,
                tryCatch(as.character(ch$name),  error = function(e) "?"),
                tryCatch(as.character(ch$units), error = function(e) "?"),
                tryCatch(as.numeric(ch$samples_per_second), error = function(e) NA)))
  }
  invisible(dat)
}


# ============================================================
#  run_pipeline()
#
#  Mandatory:
#    signal  — numeric vector of the raw respiratory signal
#    fs      — native sampling rate of `signal` in Hz
#
#  All other arguments have sensible defaults and can be
#  overridden at call time.
# ============================================================
run_pipeline <- function(
    # --- Mandatory ---
    signal,
    fs,

    # --- A: Downsample ---
    ds_on         = TRUE,
    target_fs     = 25,     # Hz

    # --- B: Bandpass filter (0.05–1 Hz, 2nd-order Butterworth) ---
    #   Lower cutoff removes baseline wander; upper cutoff removes
    #   high-frequency noise above the respiratory band.
    #   Consensus standard (Khodadad 2018 / NeuroKit2): 0.05–3 Hz.
    #   Tightened upper cutoff to 1 Hz here because paced breathing
    #   at ~0.25 Hz has no meaningful signal above 1 Hz.
    bp_on         = TRUE,
    bp_lo         = 0.05,   # Hz  lower cutoff
    bp_hi         = 1.0,    # Hz  upper cutoff
    bp_order      = 2,

    # --- C: Z-score normalisation ---
    #   Applied to the full recording so peak/trough detection
    #   thresholds (threshold = 0 → below/above the mean) are stable.
    norm_on       = TRUE,

    # --- Peak / extrema detection ---
    min_dist_s    = 2,      # minimum inter-peak interval (s); used only as a post-hoc
                            # sanity check — the zero-crossing method normally makes
                            # this unnecessary, but it can catch grossly mislabelled
                            # cycles in very noisy recordings
    amplitude_min = 0.3,    # Khodadad amplitude_min: extrema with vertical distance to
                            # nearest neighbour < (amplitude_min × mean distance) are
                            # discarded as noise.  0.3 is the NeuroKit2 default.
    slow_breath_s = 3.5,    # inter-peak interval (s) counted as a slow paced breath

    # --- Detection high-pass (Stage D_smooth) ---
    # A tighter high-pass applied to a detection-only copy of the signal.
    # Motivation: slow baseline drift (below or near the 0.05 Hz bandpass
    # cutoff) shifts zero crossings late — the downward crossing of a
    # drifting signal occurs later than it should, extending the positive
    # half-cycle and causing the argmax to land consistently after the
    # true breath peak.  A higher HP cutoff (0.1-0.15 Hz, period 7-10s)
    # re-centres each local segment so zero crossings accurately divide
    # breath cycles.  Peak/trough POSITIONS come from this copy; signal
    # VALUES for all analysis still come from the z-scored Stage C signal.
    detect_hp_hz  = 0.15,  # Hz  — HP cutoff for detection copy (try 0.1-0.15)
    detect_hp_on  = TRUE,  # FALSE reverts to running find_extrema on z-scored signal
    enforce_alt_on = TRUE, # FALSE skips enforce_alternation (useful for diagnostics)

    # --- Peak/trough walking ---
    # After initial detection on det_sig, each extremum is refined by
    # searching a small neighbourhood on cur_sig (the z-scored signal)
    # for the true local maximum/minimum.  walk_samp controls how many
    # samples either side are searched.  At 25 Hz, walk_samp = 10 means
    # ±0.4 s — enough to catch typical detection offsets without risk of
    # jumping to an adjacent breath.
    walk_samp     = 10L,   # samples either side to search (0 = disabled)
    walk_on       = TRUE,  # FALSE disables walking entirely

    # --- Detection method ---
    # "zero_crossing"  — Khodadad (2018) method (original)
    # "prominence"     — local maxima + prominence + min distance (new)
    detection_method = "prominence",
    min_prominence   = 0.5  # prominence threshold for "prominence" method
                            # (signal units after z-scoring; 0.5 works well)
) {

  signal <- as.numeric(signal)
  n      <- length(signal)
  t      <- seq(0, (n - 1) / fs, length.out = n)

  message(sprintf("  run_pipeline: %.0f Hz | %s samples | %.1f s",
                  fs, format(n, big.mark = ","), t[n]))

  # Stages stored as named list of (signal, time, fs, label)
  stages  <- list()
  stages[["0_raw"]] <- list(signal = signal, time = t, fs = fs, label = "Raw (native)")
  cur_sig <- signal
  cur_t   <- t
  cur_fs  <- fs

  # ---- A: Downsample -------------------------------------------
  # signal::decimate includes an internal Chebyshev anti-alias filter,
  # so no separate LP pass is needed before decimation.
  if (ds_on) {
    q <- floor(cur_fs / target_fs)
    if (q >= 2) {
      message(sprintf("  A: Downsample %.0f -> %.1f Hz (q=%d)", cur_fs, cur_fs / q, q))
      cur_sig <- tryCatch(
        safe_decimate(cur_sig, q),
        error = function(e) { warning("Decimation failed: ", e$message); cur_sig }
      )
      cur_fs <- cur_fs / q
      cur_t  <- seq(t[1], t[length(t)], length.out = length(cur_sig))
      stages[["A_ds"]] <- list(signal = cur_sig, time = cur_t, fs = cur_fs,
                                label  = sprintf("A: Downsampled to %.1f Hz", cur_fs))
    } else {
      message(sprintf("  A: Downsample skipped (fs %.1f already near target)", cur_fs))
    }
  } else {
    message("  A: Downsample OFF")
  }

  # ---- B: Bandpass filter 0.05–1 Hz ----------------------------
  # Single 2nd-order Butterworth bandpass — consensus standard for
  # respiratory belt signals (Khodadad 2018, adopted by NeuroKit2).
  # Lower cutoff removes baseline wander; upper cutoff removes noise
  # above the respiratory band (paced breathing ≈ 0.25 Hz).
  if (bp_on) {
    message(sprintf("  B: Bandpass %.3f–%.1f Hz (order %d)", bp_lo, bp_hi, bp_order))
    cur_sig <- tryCatch({
      nyq <- cur_fs / 2
      W   <- c(min(bp_lo / nyq, 0.99), min(bp_hi / nyq, 0.99))
      bf  <- signal::butter(bp_order, W, type = "pass")
      as.numeric(signal::filtfilt(bf, cur_sig))
    }, error = function(e) { warning("Bandpass filter failed: ", e$message); cur_sig })
    stages[["B_bp"]] <- list(signal = cur_sig, time = cur_t, fs = cur_fs,
                              label  = sprintf("B: Bandpass %.3f–%.1f Hz", bp_lo, bp_hi))
  } else {
    message("  B: Bandpass OFF")
  }

  # ---- C: Z-score normalisation --------------------------------
  # Normalises the full recording so peak/trough detection thresholds
  # (threshold = 0 → events below/above signal mean) are scale-stable.
  if (norm_on) {
    message("  C: Z-score normalisation")
    cur_sig <- zscore(cur_sig)
    stages[["C_norm"]] <- list(signal = cur_sig, time = cur_t, fs = cur_fs,
                                label  = "C: Z-scored")
  } else {
    message("  C: Normalisation OFF")
  }

  # ---- D: Extrema detection — Khodadad (2018) method -------------
  # Step 1: zero-crossing segmentation + argmax/argmin per segment
  # Step 2: amplitude outlier removal (amplitude_min fraction of mean)
  # Step 3: sign-based peak/trough split
  # enforce_alternation() is a safety net; should rarely change anything.
  message(sprintf("  D: Khodadad extrema detection (amplitude_min = %.2f)", amplitude_min))

  # ---- D_smooth: additional HP on z-scored signal for detection only ----
  # Removes slow drift that shifts zero crossings late, causing consistently
  # late peak/trough detection.  Positions found on det_sig; values read
  # from cur_sig (z-scored, Stage C).
  if (detect_hp_on) {
    det_sig <- tryCatch({
      message(sprintf("  D_smooth: additional HP at %.2f Hz for extrema detection",
                      detect_hp_hz))
      apply_butter(cur_sig, cur_fs, detect_hp_hz, order = 2, type = "high")
    }, error = function(e) {
      warning("Detection HP filter failed — using z-scored signal: ", e$message)
      cur_sig
    })
    stages[["D_smooth"]] <- list(signal = det_sig, time = cur_t, fs = cur_fs,
                                  label = sprintf("D_smooth: HP %.2f Hz (detection only)",
                                                  detect_hp_hz))
  } else {
    det_sig <- cur_sig
  }

  raw_ext     <- if (detection_method == "prominence") {
    message(sprintf("  D: Prominence-based detection (min_prom=%.2f, min_dist=%.1fs)",
                    min_prominence, min_dist_s))
    find_extrema_prominence(det_sig,
                            min_dist_samp  = round(min_dist_s * cur_fs),
                            min_prominence = min_prominence)
  } else {
    message(sprintf("  D: Khodadad zero-crossing detection (amplitude_min=%.2f)", amplitude_min))
    find_extrema(det_sig, amplitude_min = amplitude_min)
  }
  raw_peaks   <- raw_ext$peaks
  raw_troughs <- raw_ext$troughs

  stages[["D_ext"]] <- list(signal = cur_sig, time = cur_t, fs = cur_fs,
                             label  = sprintf("D: %s detection",
                                              if (detection_method == "prominence")
                                                "Prominence" else "Zero-crossing"),
                             peaks  = raw_peaks, troughs = raw_troughs)

  # ---- Walking refinement: snap each detection to the true local extremum ----
  # find_extrema locates extrema on det_sig (the HP-filtered detection copy).
  # Those positions are used as starting points to search cur_sig (z-scored)
  # for the true local maximum/minimum within a small neighbourhood.
  if (walk_on && walk_samp > 0L) {
    walk_samp  <- as.integer(walk_samp)
    raw_peaks   <- walk_to_extremum(cur_sig, raw_peaks,   seek_max = TRUE,
                                    walk_max_samp = walk_samp)
    raw_troughs <- walk_to_extremum(cur_sig, raw_troughs, seek_max = FALSE,
                                    walk_max_samp = walk_samp)
    message(sprintf("  D_walk: peaks/troughs walked up to ±%d samples (%.2f s) on z-scored signal",
                    walk_samp, walk_samp / cur_fs))
  }

  # Post-hoc minimum interval check.
  # With zero-crossing segmentation this should never be needed, but
  # it catches pathological cases (e.g. extreme noise causing very fast
  # spurious crossings).
  if (min_dist_s > 0 && length(raw_peaks) >= 2) {
    min_samp <- round(min_dist_s * cur_fs)
    keep_pk  <- c(TRUE, diff(raw_peaks) >= min_samp)
    n_dropped <- sum(!keep_pk)
    if (n_dropped > 0)
      message(sprintf("    Post-hoc interval check: dropped %d peaks closer than %.1f s",
                      n_dropped, min_dist_s))
    raw_peaks <- raw_peaks[keep_pk]
  }
  if (min_dist_s > 0 && length(raw_troughs) >= 2) {
    min_samp  <- round(min_dist_s * cur_fs)
    keep_tr   <- c(TRUE, diff(raw_troughs) >= min_samp)
    n_dropped <- sum(!keep_tr)
    if (n_dropped > 0)
      message(sprintf("    Post-hoc interval check: dropped %d troughs closer than %.1f s",
                      n_dropped, min_dist_s))
    raw_troughs <- raw_troughs[keep_tr]
  }

  alt <- if (enforce_alt_on) {
    enforce_alternation(raw_peaks, raw_troughs)
  } else {
    list(peaks = raw_peaks, troughs = raw_troughs)
  }
  clean_peaks   <- alt$peaks
  clean_troughs <- alt$troughs
  message(sprintf("    Peaks:   %d raw -> %d after alternation", length(raw_peaks),   length(clean_peaks)))
  message(sprintf("    Troughs: %d raw -> %d after alternation", length(raw_troughs), length(clean_troughs)))

  stages[["D_ext"]] <- list(signal = cur_sig, time = cur_t, fs = cur_fs,
                             label  = sprintf("D: %s (final, after alternation)",
                                              if (detection_method == "prominence")
                                                "Prominence" else "Zero-crossing"),
                             peaks  = clean_peaks, troughs = clean_troughs)


  # Use the alternation-cleaned peaks/troughs from stage D as final output.
  peaks   <- clean_peaks
  troughs <- clean_troughs
  message(sprintf("  Final peaks: %d   Final troughs: %d", length(peaks), length(troughs)))

  intervals_df <- if (length(peaks) >= 2) {
    data.frame(
      peak_num    = seq_len(length(peaks) - 1),
      peak_time_s = cur_t[peaks[-length(peaks)]],
      interval_s  = diff(cur_t[peaks]),
      slow        = diff(cur_t[peaks]) >= slow_breath_s
    )
  } else data.frame()

  trough_times <- cur_t[troughs]

  # breath_duration[i] = time in seconds from trough i to trough i+1.
  # Same length as trough_times; last element is NA (no next trough).
  breath_duration <- if (length(troughs) >= 2) {
    c(diff(trough_times), NA_real_)
  } else {
    rep(NA_real_, length(troughs))
  }

  # ---- Onset detection -----------------------------------------
  onset <- find_first_trial_onset(peaks, cur_t, min_breath_sec = slow_breath_s)
  if (!is.null(onset)) {
    message(sprintf("  Onset: %.3f s (peak #%d)", onset$onset_time, onset$peak_start))
  } else {
    message("  No onset found — try lowering slow_breath_s or adjusting pipeline.")
  }

  list(
    stages          = stages,
    final_signal    = cur_sig,
    final_time      = cur_t,
    final_fs        = cur_fs,
    peaks           = peaks,
    peak_times      = cur_t[peaks],
    troughs         = troughs,
    trough_times    = trough_times,
    breath_duration = breath_duration,
    intervals       = intervals_df,
    onset           = onset,
    slow_breath_s   = slow_breath_s
  )
}


# ============================================================
#  plot_pipeline()
#
#  result     — object returned by run_pipeline()
#  plot_file  — path to save PNG, or NULL to display on screen
#  width/height — plot dimensions in inches
# ============================================================
plot_pipeline <- function(result,
                          plot_file = NULL,
                          width     = 14,
                          height    = 18) {

  stages        <- result$stages
  onset         <- result$onset
  peaks         <- result$peaks
  slow_breath_s <- result$slow_breath_s
  final         <- list(signal = result$final_signal, time = result$final_time)

  make_stage_plot <- function(s, show_anchors = FALSE, show_onset = FALSE) {
    df <- data.frame(time = s$time, signal = s$signal)

    p <- ggplot(df, aes(x = time, y = signal)) +
      geom_line(colour = "#2c7be5", linewidth = 0.5) +
      labs(title = s$label, x = "Time (s)", y = NULL) +
      theme_minimal(base_size = 10) +
      theme(plot.title  = element_text(size = 9, face = "bold"),
            axis.text.x = element_text(size = 7),
            axis.text.y = element_text(size = 7),
            plot.margin = margin(4, 8, 4, 8))

    if (show_anchors) {
      # Use per-stage anchor indices if stored (stage F), else use final peaks/troughs
      stg_peaks   <- if (!is.null(s$peaks))   s$peaks   else result$peaks
      stg_troughs <- if (!is.null(s$troughs)) s$troughs else result$troughs
      if (length(stg_peaks) > 0) {
        pk_df <- data.frame(time = s$time[stg_peaks], signal = s$signal[stg_peaks])
        p <- p + geom_point(data = pk_df, aes(x = time, y = signal),
                            colour = "#e63946", size = 2.5, shape = 19)
      }
      if (length(stg_troughs) > 0) {
        tr_df <- data.frame(time = s$time[stg_troughs], signal = s$signal[stg_troughs])
        p <- p + geom_point(data = tr_df, aes(x = time, y = signal),
                            colour = "#2dc653", size = 2.5, shape = 17)
      }
    }

    if (show_onset && !is.null(onset)) {
      p <- p +
        geom_vline(xintercept = onset$onset_time,
                   colour = "darkorange", linewidth = 0.8, linetype = "dashed") +
        annotate("text",
                 x = onset$onset_time, y = max(s$signal, na.rm = TRUE),
                 label = sprintf("onset\n%.2fs", onset$onset_time),
                 hjust = -0.1, vjust = 1, size = 2.8, colour = "darkorange")
    }
    p
  }

  stage_names  <- names(stages)
  anchor_stages <- c("D_smooth", "D_ext")   # show peaks+troughs on these panels
  plots <- lapply(seq_along(stage_names), function(i) {
    s          <- stages[[stage_names[i]]]
    is_final   <- i == length(stage_names)
    show_anch  <- stage_names[i] %in% anchor_stages || is_final
    make_stage_plot(s, show_anchors = show_anch, show_onset = is_final)
  })

  if (nrow(result$intervals) > 0) {
    df_iv <- result$intervals
    p_iv  <- ggplot(df_iv, aes(x = peak_time_s, y = interval_s, colour = slow)) +
      geom_line(colour = "#adb5bd") +
      geom_point(size = 3) +
      scale_colour_manual(values = c("FALSE" = "#2c7be5", "TRUE" = "#e63946"),
                          labels = c("Fast", "Slow (>= threshold)"),
                          name   = NULL) +
      geom_hline(yintercept = slow_breath_s,
                 colour = "darkorange", linetype = "dashed", linewidth = 0.6) +
      labs(title = "Inter-breath intervals  (red = slow paced breath)",
           x = "Breath onset (s)", y = "Interval (s)") +
      theme_minimal(base_size = 10) +
      theme(legend.position = "top",
            plot.title      = element_text(size = 9, face = "bold"))

    if (!is.null(onset))
      p_iv <- p_iv +
        geom_vline(xintercept = onset$onset_time,
                   colour = "darkorange", linewidth = 0.8, linetype = "dashed")

    plots <- c(plots, list(p_iv))
  }

  combined <- patchwork::wrap_plots(plots, ncol = 1)

  if (!is.null(plot_file)) {
    ggsave(plot_file, combined, width = width, height = height, dpi = 120)
    message("Plot saved to: ", plot_file)
  } else {
    print(combined)
  }

  invisible(combined)
}


# ============================================================
#  Outputs available after run_pipeline()
# ============================================================
# result$onset            — list: onset_time (s), peak_start (index in final_signal)
# result$intervals        — data.frame: peak_time_s, interval_s, slow (logical)
# result$peaks            — integer vector of peak indices in final_signal
# result$peak_times       — numeric vector of peak times (s from recording start)
# result$troughs          — integer vector of trough indices in final_signal
# result$trough_times     — numeric vector of trough times (s from recording start)
# result$breath_duration  — numeric vector, same length as trough_times:
#                           time in seconds to the next trough; last element = NA
# result$final_signal     — fully processed signal vector
# result$final_time       — time vector (s) matching final_signal
# result$final_fs         — effective sample rate after downsampling
# result$stages           — named list of signal at each pipeline stage
# result$slow_breath_s    — slow breath threshold used (passed through to plot_pipeline)


# ============================================================
#  assess_belt_quality()
#
#  Assesses raw respiratory belt signal quality before the
#  full pipeline runs. Designed to run immediately after
#  channel extraction in checkParticipantFiles(), on the
#  native-SR signal.
#
#  Strategy:
#    1. Trim the first and last trim_s seconds to exclude
#       belt setup noise and post-session removal artefacts.
#    2. Downsample to target_fs (default 25 Hz) for speed —
#       no information relevant to respiration exists above
#       ~1 Hz, so 2000 Hz arithmetic is never needed here.
#    3. Bandpass filter 0.05–1 Hz (same as pipeline Stage B)
#       to isolate the respiratory band and remove DC offset
#       + high-frequency noise before computing metrics.
#    4. Compute four metrics on the trimmed/filtered signal:
#
#       filtered_iqr     — IQR of the bandpass-filtered signal.
#                          Captures respiratory oscillation
#                          amplitude robustly (IQR is resistant
#                          to movement spikes).
#                          A good signal from this belt has
#                          filtered_iqr ≈ 0.5–1.0 units;
#                          disconnected/loose belts approach 0.
#
#       band_ratio       — Fraction of total bandpass power
#                          (0.05–1 Hz) that falls in the core
#                          respiratory band (0.05–0.5 Hz).
#                          A real breathing signal concentrates
#                          power at ~0.1–0.3 Hz; electronic
#                          noise or movement artefact spreads
#                          power across the full band.
#
#       dominant_freq_hz — Frequency of the spectral peak
#                          within 0.05–0.5 Hz. Should be
#                          ~0.1–0.3 Hz (6–18 breaths/min)
#                          for both resting and paced breathing.
#                          Values far outside this range
#                          suggest noise, not respiration.
#
#       flatline_pct     — Percentage of samples belonging to
#                          runs of >= flatline_run_s consecutive
#                          seconds of near-identical values
#                          (after rounding to 3 decimal places).
#                          High values indicate a stuck or
#                          disconnected sensor.
#
#    5. Assign a provisional quality label using the thresholds
#       in the arguments. These are intentionally conservative
#       starting points — inspect the distribution across all
#       participants before finalising cutoffs.
#
#  Thresholds (validated empirically across N=206 participants):
#    filtered_iqr < iqr_unusable                    → "unusable"
#    filtered_iqr < iqr_degraded  OR
#      dominant_freq_hz outside [freq_lo, freq_hi]  OR
#      flatline_pct > 10                            → "degraded"
#    otherwise                                       → "good"
#
#  NOTE: band_ratio is computed and returned for reference but is NOT
#  used in the quality decision. Empirical validation showed that
#  band_ratio does not discriminate quality categories in this dataset
#  (minimum observed = 0.845; all three quality buckets overlap
#  extensively above 0.84). The parameter band_ratio_min has been
#  removed from the classifier.
#
#  Arguments:
#    signal          — raw numeric vector at native fs
#    fs              — native sampling rate (Hz)
#    trim_s          — seconds to trim from each end (default 120)
#    target_fs       — downsample target before metrics (default 25)
#    bp_lo / bp_hi   — bandpass cutoffs, same as pipeline (Hz)
#    bp_order        — filter order
#    resp_band_hi    — upper edge of "core respiratory" band (Hz)
#    flatline_run_s  — minimum run length to count as flatline (s)
#    iqr_unusable    — IQR below this → "unusable" (default 0.05;
#                      clean bimodal — all unusable near zero, all
#                      good participants exceed 0.23)
#    iqr_degraded    — IQR below this → "degraded" secondary flag
#                      (default 0.20; overlaps with good distribution,
#                      serves as belt-amplitude floor rather than
#                      primary discriminator; catches 1 participant
#                      not already flagged by freq/flatline)
#    freq_lo/freq_hi — dominant freq outside [lo, hi] → "degraded"
#                      (default [0.08, 0.35] Hz; zero good-belt
#                      participants fall below 0.0809 Hz)
#
#  Returns a named list:
#    $quality          — "good" / "degraded" / "unusable"
#    $filtered_iqr     — IQR of bandpass-filtered trimmed signal
#    $band_ratio       — respiratory band power fraction
#    $dominant_freq_hz — peak frequency in resp band (Hz)
#    $flatline_pct     — % of signal in flatline runs
#    $duration_s       — total recording duration (s)
#    $usable_duration_s — duration after trimming (s)
#    $ds_fs            — effective sampling rate after downsample
#    $qc_note          — human-readable note on any flags
#
#  Dependencies: safe_decimate() and apply_butter() from
#    breath_pipeline.R must be loaded before calling this.
# ============================================================

assess_belt_quality <- function(signal,
                                fs,
                                trim_s          = 120,
                                target_fs       = 25,
                                bp_lo           = 0.05,
                                bp_hi           = 1.0,
                                bp_order        = 2,
                                resp_band_hi    = 0.5,
                                flatline_run_s  = 1.0,
                                iqr_unusable    = 0.05,
                                iqr_degraded    = 0.20,
                                freq_lo         = 0.08,
                                freq_hi         = 0.35) {

  signal <- as.numeric(signal)
  n_total    <- length(signal)
  duration_s <- n_total / fs

  # ------------------------------------------------------------------
  # 1. TRIM first and last trim_s seconds
  # ------------------------------------------------------------------
  trim_samp <- round(trim_s * fs)

  # Safety: if recording is too short to trim by the full amount,
  # fall back to trimming 10% from each end, with a minimum of 30s
  # of usable signal required.
  min_usable_s <- 30
  if (n_total - 2 * trim_samp < min_usable_s * fs) {
    trim_samp <- max(0L, floor((n_total - min_usable_s * fs) / 2))
    message(sprintf(
      "  [BeltQC] Recording too short for %.0fs trim — using %.1fs trim instead",
      trim_s, trim_samp / fs
    ))
  }

  start_idx      <- trim_samp + 1L
  end_idx        <- n_total - trim_samp
  trimmed        <- signal[start_idx:end_idx]
  usable_duration_s <- length(trimmed) / fs

  message(sprintf(
    "  [BeltQC] Recording %.1fs | Trimmed: %.0fs each end | Usable: %.1fs",
    duration_s, trim_s, usable_duration_s
  ))

  # ------------------------------------------------------------------
  # 2. DOWNSAMPLE to target_fs
  #    safe_decimate() handles large decimation factors by staging
  #    through factors <= 13 to avoid filter instability.
  # ------------------------------------------------------------------
  q <- floor(fs / target_fs)
  if (q >= 2) {
    ds_signal <- safe_decimate(trimmed, q)
    ds_fs     <- fs / q
  } else {
    ds_signal <- trimmed
    ds_fs     <- fs
  }

  # ------------------------------------------------------------------
  # 3. BANDPASS FILTER 0.05–1 Hz (identical to pipeline Stage B)
  # ------------------------------------------------------------------
  filtered <- tryCatch({
    nyq <- ds_fs / 2
    W   <- c(min(bp_lo / nyq, 0.99), min(bp_hi / nyq, 0.99))
    bf  <- signal::butter(bp_order, W, type = "pass")
    as.numeric(signal::filtfilt(bf, ds_signal))
  }, error = function(e) {
    message(sprintf("  [BeltQC] Bandpass filter failed: %s", e$message))
    ds_signal
  })

  # ------------------------------------------------------------------
  # 4. COMPUTE METRICS
  # ------------------------------------------------------------------

  # --- 4a. Filtered IQR (amplitude) ---------------------------------
  filtered_iqr <- IQR(filtered, na.rm = TRUE)

  # --- 4b. Spectral band ratio (periodicity) ------------------------
  n_f      <- length(filtered)
  fft_vals <- fft(filtered - mean(filtered, na.rm = TRUE))
  psd      <- (Mod(fft_vals)^2) / n_f

  # Positive frequencies only (indices 1 to floor(n_f/2))
  pos_n      <- floor(n_f / 2)
  freqs_pos  <- (0:(pos_n - 1)) * ds_fs / n_f
  psd_pos    <- psd[seq_len(pos_n)]

  in_resp    <- freqs_pos >= bp_lo  & freqs_pos <= resp_band_hi
  in_total   <- freqs_pos >= bp_lo  & freqs_pos <= bp_hi

  resp_power  <- if (any(in_resp))  sum(psd_pos[in_resp])  else 0
  total_power <- if (any(in_total)) sum(psd_pos[in_total]) else 0
  band_ratio  <- if (total_power > 0) resp_power / total_power else NA_real_

  # --- 4c. Dominant frequency in respiratory band -------------------
  dominant_freq_hz <- if (any(in_resp) && resp_power > 0) {
    freqs_pos[in_resp][which.max(psd_pos[in_resp])]
  } else {
    NA_real_
  }

  # --- 4d. Flatline detection ---------------------------------------
  # Round to 3 dp before rle to treat near-identical values as equal
  # (avoids spurious variation from floating-point noise at low amplitudes)
  flatline_run_samp <- max(1L, round(flatline_run_s * ds_fs))
  rle_result        <- rle(round(filtered, 3))
  flatline_samps    <- sum(rle_result$lengths[rle_result$lengths >= flatline_run_samp])
  flatline_pct      <- 100 * flatline_samps / length(filtered)

  # ------------------------------------------------------------------
  # 5. QUALITY LABEL
  # ------------------------------------------------------------------
  flags    <- character(0)
  quality  <- "good"

  if (!is.na(filtered_iqr) && filtered_iqr < iqr_unusable) {
    quality <- "unusable"
    flags   <- c(flags, sprintf("IQR=%.4f below unusable threshold (%.2f)", filtered_iqr, iqr_unusable))
  } else {
    if (!is.na(filtered_iqr) && filtered_iqr < iqr_degraded)
      flags <- c(flags, sprintf("IQR=%.4f below degraded threshold (%.2f)", filtered_iqr, iqr_degraded))

    if (!is.na(dominant_freq_hz) &&
        (dominant_freq_hz < freq_lo || dominant_freq_hz > freq_hi))
      flags <- c(flags, sprintf("dominant_freq=%.3fHz outside [%.2f, %.2f]Hz",
                                dominant_freq_hz, freq_lo, freq_hi))

    if (flatline_pct > 10)
      flags <- c(flags, sprintf("flatline_pct=%.1f%%", flatline_pct))

    if (length(flags) > 0) quality <- "degraded"
  }

  qc_note <- if (length(flags) > 0) paste(flags, collapse = " | ") else ""

  message(sprintf(
    "  [BeltQC] Quality: %s | IQR=%.4f | BandRatio=%.3f | DomFreq=%.3fHz | Flatline=%.1f%%",
    quality, filtered_iqr,
    if (is.na(band_ratio)) -1 else band_ratio,
    if (is.na(dominant_freq_hz)) -1 else dominant_freq_hz,
    flatline_pct
  ))

  list(
    quality           = quality,
    filtered_iqr      = filtered_iqr,
    band_ratio        = band_ratio,
    dominant_freq_hz  = dominant_freq_hz,
    flatline_pct      = flatline_pct,
    duration_s        = duration_s,
    usable_duration_s = usable_duration_s,
    ds_fs             = ds_fs,
    qc_note           = qc_note
  )
}
