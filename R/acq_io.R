# acq_io.R
#
# Reading BioPac .acq files, decimation, and accelerometer timestamp
# reconstruction. Everything here is I/O and resampling; nothing computes an
# outcome.
#
# Requires: reticulate (for the Python `bioread` package), signal.
# Sourced by scripts/; installs nothing.


# ── BioPac .acq ───────────────────────────────────────────────────────────────

# Point reticulate at an interpreter that actually has bioread.
#
# Left to itself, reticulate provisions an ephemeral uv-managed Python with only
# numpy, then fails on bioread. Honour RETICULATE_PYTHON if the caller set it,
# otherwise take the first interpreter on a short candidate list that can import
# bioread. This must run BEFORE any other reticulate call binds an interpreter.
.bind_python <- function() {
  if (nzchar(Sys.getenv("RETICULATE_PYTHON"))) return(invisible(NULL))
  cands <- c(Sys.which("python"), Sys.which("python3"),
             "C:/Python313/python.exe", "C:/Python312/python.exe")
  cands <- unique(cands[nzchar(cands) & file.exists(cands)])
  for (py in cands) {
    ok <- suppressWarnings(system2(py, c("-c", shQuote("import bioread")),
                                   stdout = NULL, stderr = NULL)) == 0L
    if (ok) { Sys.setenv(RETICULATE_PYTHON = py); return(invisible(py)) }
  }
  invisible(NULL)
}

.bioread <- local({
  cached <- NULL
  function() {
    if (is.null(cached)) {
      .bind_python()
      if (!reticulate::py_module_available("bioread")) {
        stop("Python module `bioread` is not available. Install it with:\n",
             "  reticulate::py_install(\"bioread\", pip = TRUE)")
      }
      cached <<- reticulate::import("bioread")
    }
    cached
  }
})

# Read an .acq and return channels keyed by name, plus the raw rate.
#
# Channels are addressed BY NAME throughout. Slot index is not used: the
# template defines a fixed 17-channel layout, and named lookup survives a
# reordering that positional indexing would silently misread.
read_acq <- function(path) {
  if (!file.exists(path)) stop("No such .acq file: ", path)
  acq   <- .bioread()$read_file(path)
  names <- vapply(acq$channels, function(ch) ch$name, character(1))
  hz    <- vapply(acq$channels, function(ch) as.numeric(ch$samples_per_second),
                  numeric(1))
  if (length(unique(hz)) != 1L) {
    stop("Channels have mixed sample rates: ", paste(unique(hz), collapse = ", "),
         ". The pipeline assumes one rate for the whole file.")
  }
  list(
    get = function(nm) {
      i <- which(names == nm)
      if (length(i) != 1L) {
        stop("Expected exactly one channel named '", nm, "', found ", length(i),
             ". Channels present: ", paste(names, collapse = ", "))
      }
      as.numeric(acq$channels[[i]]$data)
    },
    names    = names,
    hz       = hz[1],
    n_sample = length(acq$channels[[1]]$data),
    file     = path
  )
}


# ── Decimation ────────────────────────────────────────────────────────────────

# Factorise q into stages of at most `max_stage`, largest first.
.decimation_stages <- function(q, max_stage = 10L) {
  q <- as.integer(q); stages <- integer(0)
  for (f in c(10L, 9L, 8L, 7L, 6L, 5L, 4L, 3L, 2L)) {
    while (q %% f == 0L && f <= max_stage) { stages <- c(stages, f); q <- q %/% f }
  }
  if (q != 1L) stop("Decimation factor has a prime factor above ", max_stage,
                    "; remaining: ", q)
  stages
}

# Anti-aliased decimation by an integer factor.
#
# WHY NOT STRIDE SAMPLING. The previous pipeline used
# `x[seq(1, length(x), by = factor)]`, which has no low-pass ahead of it, so
# everything above the new Nyquist folds back into the retained band.
#
# Measured on this dataset (2026-07-31, frequencies above 5 Hz only, so no
# respiratory information was examined): the respiration channel is broadband to
# at least 1 kHz with NO analog roll-off near 12.5 Hz, but the content that would
# actually fold into the 0.05 to 1.0 Hz analysis band sits about 57 dB below the
# respiratory band. Stride sampling was therefore harmless in practice, by luck
# of where the noise sits rather than by design.
#
# This removes the dependence on that luck. Decimation runs in stages of at most
# 10 because a single 80-fold IIR stage is numerically poor.
decimate_safe <- function(x, q) {
  q <- as.integer(q)
  if (q == 1L) return(as.numeric(x))
  for (f in .decimation_stages(q)) x <- as.numeric(signal::decimate(x, f))
  as.numeric(x)
}

# Assert an exact integer decimation factor.
#
# The old code wrote `as.integer(raw_hz / RESP_HZ)`, which TRUNCATES. At the
# actual 2000 Hz the factor is exactly 80, but a file recorded at, say, 2048 Hz
# would silently yield 81 and a 25.28 Hz signal labelled 25 Hz. Study 5 hit the
# same class of problem from the other side: it decimated 2000 Hz by 78 and ran
# at 25.641 Hz, so any constant ported from there that is expressed in SAMPLES
# rather than seconds needs rescaling.
decimation_factor <- function(raw_hz, target_hz) {
  q <- raw_hz / target_hz
  if (abs(q - round(q)) > 1e-9) {
    stop("Sample rate ", raw_hz, " Hz is not an integer multiple of the target ",
         target_hz, " Hz (factor ", signif(q, 8), "). Refusing to guess.")
  }
  as.integer(round(q))
}


# ── Accelerometer timestamps ──────────────────────────────────────────────────

# Empirically measured per-sample interval. NOT 1000/200 = 5.000 ms.
#
# The true streaming rate is 203.4 Hz, giving 4.916 ms per sample. The nominal
# 5.000 ms assumption costs 2.9 ms at the start of each 36-sample packet, which
# accumulates into onset-timing error that H2 is directly sensitive to.
ACCEL_MS_PER_SAMPLE   <- 1000 / 203.4
ACCEL_SAMPLES_PER_PKT <- 36L

# Reconstruct per-sample epoch times by back-assigning from the packet timestamp.
#
# The packet timestamp marks the LAST sample in the packet, so sample k of n runs
# (n - 1 - k) intervals earlier. Packets are exactly 36 samples with no
# exceptions, which is asserted rather than assumed.
reconstruct_accel_times <- function(df, ms_per_sample = ACCEL_MS_PER_SAMPLE) {
  stopifnot(all(c("packet_timestamp", "sample_index") %in% names(df)))
  if (max(df$sample_index) >= ACCEL_SAMPLES_PER_PKT) {
    stop("sample_index reaches ", max(df$sample_index),
         "; expected within-packet indices 0 to ", ACCEL_SAMPLES_PER_PKT - 1L,
         ". It may be a global counter, which this reconstruction cannot use.")
  }
  sizes <- table(df$packet_timestamp)
  odd   <- sum(sizes != ACCEL_SAMPLES_PER_PKT)
  if (odd > 0L) {
    warning(odd, " of ", length(sizes), " packets do not contain exactly ",
            ACCEL_SAMPLES_PER_PKT, " samples.", call. = FALSE)
  }
  n_in_packet <- as.integer(sizes[as.character(df$packet_timestamp)])
  df$sample_ms <- df$packet_timestamp -
    (n_in_packet - 1L - df$sample_index) * ms_per_sample
  df
}

# Linear interpolation onto a uniform grid, holding the end values beyond range.
interp_to_grid <- function(t_orig, y_orig, t_grid) {
  stats::approx(t_orig, y_orig, xout = t_grid, method = "linear", rule = 2)$y
}
