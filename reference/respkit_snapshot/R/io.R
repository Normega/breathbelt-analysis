# =====================================================================
#  io.R — serialisation, and a migration path for legacy files
#
#  The serialised form is a plain list with a `schema` field, wrapped in the
#  resp_recording class. It stays readable by base readRDS() with no package
#  attached, which matters for archived data: a repository copy should still
#  be openable in ten years by someone who does not have this package.
# =====================================================================

#' Write a recording to disk
#'
#' @param x A `resp_recording`.
#' @param path Destination `.rds` path. Parent directories are created.
#' @param compress Passed to [saveRDS()].
#'
#' @return `path`, invisibly.
#'
#' @details
#' The saved object records the sampling rate that was actually achieved,
#' never a requested one, and carries its own processing history. Nothing
#' downstream has to reconstruct what was done to the signal, which is what
#' went wrong in the pipeline this package replaces: the rate written to disk
#' was the requested 25 Hz while the signal was at 25.641 Hz, and three
#' separate scripts each rediscovered and patched the discrepancy
#' differently.
#' @export
resp_write_rds <- function(x, path, compress = TRUE) {
  if (!is_resp_recording(x))
    stop("`x` must be a resp_recording. Use as_resp_recording() first.",
         call. = FALSE)
  dir <- dirname(path)
  if (!dir.exists(dir)) dir.create(dir, recursive = TRUE)
  saveRDS(x, path, compress = compress)
  invisible(path)
}

#' Read a recording from disk
#'
#' Accepts both the respkit format and the older ad-hoc list format. Legacy
#' files are converted and, where the sampling rate can be shown to be wrong,
#' corrected; see [resp_read_legacy_rds()].
#'
#' @param path Path to a `.rds` file.
#' @param ... Passed to [resp_read_legacy_rds()] when the file is legacy.
#' @export
resp_read_rds <- function(path, ...) {
  if (!file.exists(path))
    stop("No such file: ", path, call. = FALSE)
  obj <- readRDS(path)

  if (is_resp_recording(obj)) return(obj)

  if (resp_rds_is_legacy(obj)) {
    message("Legacy RDS format detected in ", basename(path),
            "; converting. Check the reported sampling rate.")
    return(resp_read_legacy_rds(obj, ...))
  }

  as_resp_recording(obj)
}

#' Is this object in the pre-respkit list format?
#'
#' @param obj An object read from an `.rds` file.
#' @export
resp_rds_is_legacy <- function(obj) {
  # `obj$schema` would partial-match a field named e.g. `schema_version`, so a
  # legacy file carrying one would be declared modern and skip the sampling-rate
  # correction entirely -- the one thing this reader exists to do. `[[` does not
  # partial-match. Data frames are excluded because is.list() accepts them.
  is.list(obj) && !is.data.frame(obj) && !is_resp_recording(obj) &&
    all(c("signal", "fs") %in% names(obj)) &&
    !("schema" %in% names(obj))
}

#' Decimation factor the legacy staging loop actually achieved
#'
#' Reproduces the defect in the original `safe_decimate()` helper, for
#' diagnosing existing files. The loop staged decimation through factors of at
#' most `max_factor` but updated the remaining factor with integer division,
#' silently discarding the remainder, so the product of the stages undershoots
#' the request whenever `q` is not a product of factors taken greedily from
#' the top.
#'
#' @param q The decimation factor that was requested.
#' @param max_factor The stage limit the original used, 13.
#'
#' @return The factor that was actually applied.
#'
#' @examples
#' legacy_decimation_factor(80)   # 78, not 80  -> 25.641 Hz, not 25 Hz
#' legacy_decimation_factor(20)   # 13, not 20  -> a 35% error
#' @export
legacy_decimation_factor <- function(q, max_factor = 13L) {
  q <- as.integer(q)
  if (is.na(q) || q <= 1L) return(1L)
  remaining <- q
  achieved  <- 1L
  while (remaining > 1L) {
    step      <- min(remaining, max_factor)
    achieved  <- achieved * step
    remaining <- remaining %/% step
    if (remaining <= 1L) break
  }
  as.integer(achieved)
}

#' Convert a legacy RDS list to a resp_recording, correcting the sample rate
#'
#' @param obj Either a path to an `.rds` file or the list read from one.
#' @param target_fs The downsampling target that produced the file. Used to
#'   reconstruct the requested decimation factor. Default 25.
#' @param correct_fs Recompute the true sampling rate from `native_fs` and the
#'   known decimation defect. Default `TRUE`. Set `FALSE` only to reproduce
#'   an old analysis exactly, bugs included.
#' @param units Units label for the stored signal.
#'
#' @return A `resp_recording`.
#'
#' @section What is corrected:
#' The original screening script computed `q <- floor(native_fs / target_fs)`,
#' decimated with a staged helper, and recorded `fs <- native_fs / q`. The
#' helper's staging loop used integer division on the remaining factor, so for
#' `q = 80` it decimated by 13 then 6, a total of 78, not 80. The stored rate
#' of 25 Hz therefore described a signal at 25.641 Hz, and every time derived
#' from a sample index was 2.5% too long. This function reconstructs the
#' factor the helper actually achieved and sets `fs` accordingly.
#'
#' Two fields of the legacy format are deliberately **not** carried over
#' automatically:
#'
#' `start_indices` was stored in native-rate samples in untrimmed files but in
#' downsampled samples in files that a later script had trimmed, with the
#' presence of a `trim_offset_s` field as the only discriminator. Rather than
#' perpetuate a field whose units depend on processing history, the indices
#' are converted to seconds here using whichever rate the discriminator
#' implies, and stored in the `events` table as `time`. Verify them against a
#' plot before trusting them.
#'
#' Anything else in the list is preserved verbatim under `meta`.
#' @export
resp_read_legacy_rds <- function(obj, target_fs = 25, correct_fs = TRUE,
                                 units = "arbitrary") {

  if (is.character(obj)) obj <- readRDS(obj)
  if (!is.list(obj) || !all(c("signal", "fs") %in% names(obj)))
    stop("Not a legacy respiration RDS: needs at least `signal` and `fs`.",
         call. = FALSE)

  stored_fs <- as.numeric(obj$fs)
  native_fs <- if (!is.null(obj$native_fs)) as.numeric(obj$native_fs) else stored_fs

  fs   <- stored_fs
  prov <- character(0)

  if (correct_fs && is.finite(native_fs) && native_fs > stored_fs) {
    # Reconstruct the factor that was *requested* from the file's own stored
    # rate, not from a `target_fs` the caller guessed. The original wrote
    # fs <- native_fs / q_requested, so q_requested is recoverable exactly.
    # Deriving it from target_fs instead corrupts any file decimated to some
    # other rate: a 1000 Hz file stored at 50 Hz would be "corrected" to
    # 25.641 Hz, a 49% change reported as a decimation defect and applied
    # anyway.
    q_requested <- as.integer(round(native_fs / stored_fs))
    q_from_target <- as.integer(round(native_fs / target_fs))
    if (q_requested != q_from_target)
      message(sprintf(
        paste0("File records %.6g Hz from a native %.6g Hz, implying a ",
               "requested decimation of %d, not the %d that target_fs = %.6g ",
               "would imply. Using the file's own value."),
        stored_fs, native_fs, q_requested, q_from_target, target_fs))

    q_actual    <- legacy_decimation_factor(q_requested)
    fs_actual   <- native_fs / q_actual

    if (abs(fs_actual - stored_fs) / stored_fs > 1e-6) {
      warning(sprintf(
        paste0("Legacy file records fs = %.6g Hz, but a requested decimation ",
               "of %d was achieved as %d, giving a true rate of %.6g Hz ",
               "(%.2f%% discrepancy). Using the true rate. Pass ",
               "correct_fs = FALSE to reproduce the original analysis."),
        stored_fs, q_requested, q_actual, fs_actual,
        100 * abs(fs_actual - stored_fs) / stored_fs), call. = FALSE)
      fs <- fs_actual
      prov <- c(prov, sprintf(
        "legacy fs correction: %.6g Hz -> %.6g Hz (requested q=%d, achieved q=%d)",
        stored_fs, fs_actual, q_requested, q_actual))
    }
  }

  # A trimmed file no longer starts at the acquisition clock's zero, and the
  # offset is recoverable: trim_offset_samp is in downsampled samples, so
  # dividing by the CORRECTED rate gives true seconds. The stored
  # trim_offset_s was computed as trim_native / native_sr and is itself exact,
  # but it describes the cut in the ORIGINAL recording rather than where it
  # landed in the decimated one; trim_offset_samp is the field carrying the
  # 80-vs-78 error, so the two differ by about 2.5%. Leaving t0 at zero would put trimmed and untrimmed files on
  # different clocks with nothing to tell them apart -- an error of up to an
  # hour when joining against an onset table computed from the raw recording.
  was_trimmed <- !is.null(obj$trim_offset_s)
  t0 <- 0
  if (was_trimmed) {
    t0 <- if (!is.null(obj$trim_offset_samp))
      as.numeric(obj$trim_offset_samp) / fs
    else
      as.numeric(obj$trim_offset_s)
    prov <- c(prov, sprintf(
      "t0 set to %.4f s from the recorded trim offset (stored trim_offset_s was %.4f s, computed at the uncorrected rate)",
      t0, as.numeric(obj$trim_offset_s)))
  }

  # start_indices: units depend on whether an earlier script trimmed the file.
  events <- NULL
  if (!is.null(obj$start_indices) && length(obj$start_indices) > 0L) {
    idx_fs <- if (was_trimmed) fs else native_fs
    # In a trimmed file the indices count from the trimmed start, so they need
    # the same t0 offset the signal does to land on the acquisition clock.
    events <- data.frame(
      time  = t0 + as.numeric(obj$start_indices) / idx_fs,
      label = paste0("session_start_", seq_along(obj$start_indices)),
      source = if (was_trimmed) "downsampled_index" else "native_index",
      stringsAsFactors = FALSE
    )
    prov <- c(prov, sprintf(
      "start_indices converted to seconds assuming %s samples (fs = %.6g Hz)%s",
      if (was_trimmed) "downsampled" else "native", idx_fs,
      if (was_trimmed) sprintf(", offset by t0 = %.4f s", t0) else ""))
  }

  known <- c("signal", "fs", "native_fs", "id", "start_indices")
  meta  <- obj[setdiff(names(obj), known)]

  if (!is.null(obj$contamination_note))
    prov <- c(prov, paste("legacy note:", obj$contamination_note))

  resp_recording(
    signal     = obj$signal,
    fs         = fs,
    id         = if (!is.null(obj$id)) obj$id else NA_character_,
    units      = units,
    fs_native  = native_fs,
    t0         = t0,
    events     = events,
    meta       = meta,
    provenance = c("imported from legacy RDS", prov)
  )
}

# ---------------------------------------------------------------------
#  BIOPAC .acq support (optional, needs reticulate + the Python bioread
#  package). Kept out of the hard dependencies so the rest of respkit
#  installs and runs without a Python toolchain.
# ---------------------------------------------------------------------

#' Locate trigger edges in a digital code channel
#'
#' Returns the first sample of every run holding a valid code. Split out from
#' [resp_read_acq()] so the logic can be tested without a `.acq` file or a
#' Python toolchain.
#'
#' @param trig Numeric vector of trigger codes, idling at zero.
#' @param trigger_max Codes at or above this are noise, not triggers.
#' @param min_pulse_s Ignore runs shorter than this many seconds.
#' @param fs Sampling rate of `trig`, in Hz.
#'
#' @rdname trigger_runs
#'
#' @section Why a code-to-code change counts as an edge:
#' Requiring the line to return to zero between codes is wrong on real
#' hardware. On one recording in the dataset this was built against, the
#' trigger line idles at code 3 for the first 205 seconds and then steps
#' straight to code 1 -- the genuine session start, and the anchor the whole
#' alignment rests on. A zero-to-valid rule misses it silently. Verified
#' against the original pipeline's detector across 24 recordings: every edge
#' identical.
#' @export
trigger_runs <- function(trig, trigger_max = 200, min_pulse_s = 0, fs = 1) {
  # `min_pulse_s` is in seconds, so it means nothing without a real rate. The
  # placeholder default of 1 Hz silently rounds any sub-second threshold to
  # zero and disables the filter, with no other symptom.
  if (min_pulse_s > 0 && missing(fs))
    stop("`min_pulse_s` is in seconds, so `fs` must be given too. Without it ",
         "the threshold is measured against a placeholder rate of 1 Hz and ",
         "silently has no effect.", call. = FALSE)

  empty <- data.frame(index = integer(0), code = numeric(0), length = integer(0))
  v <- as.numeric(trig)
  if (!length(v)) return(empty)
  finite_in <- is.finite(v)


  # A non-finite sample is filled from its predecessor, not zeroed. Zeroing
  # splits the run it sits inside: a lone NA in the middle of a pulse produced
  # a duplicate edge, and with `min_pulse_s` set it deleted the true onset and
  # reported a later index in its place. Filling forward keeps the pulse whole
  # while still preventing an NA from poisoning a comparison. A leading NA has
  # no predecessor and becomes idle.
  if (anyNA(v) || any(!is.finite(v))) {
    bad <- !is.finite(v)
    v[bad] <- NA_real_
    # The loop handles leading gaps on its own: with no predecessor, index 1
    # takes 0 and the rest follow from it.
    for (i in which(is.na(v))) v[i] <- if (i > 1L) v[i - 1L] else 0
  }

  r      <- rle(v)
  ends   <- cumsum(r$lengths)
  starts <- ends - r$lengths + 1L

  # Codes are integers of at least 1. The lower bound is not redundant with
  # `!= 0`: one recording here carries a denormal float of 2.05e-289 in its
  # trigger channel, which passes a bare non-zero test and would be reported
  # as a trigger.
  # A run's length counts only samples that were finite to begin with. Filling
  # forward keeps a pulse whole, but it also extends the run across whatever
  # followed: three real samples trailed by 87 missing ones would otherwise be
  # reported as a 90-sample pulse, surviving a min_pulse_s floor set to reject
  # it and outranking a genuine pulse in the debounce weighting.
  cf       <- c(0L, cumsum(finite_in))
  real_len <- as.integer(cf[ends + 1L] - cf[starts])

  min_pulse_samp <- max(1L, round(min_pulse_s * fs))
  keep <- r$values >= 1 & r$values < trigger_max & real_len >= min_pulse_samp
  data.frame(index  = as.integer(starts[keep]),
             code   = r$values[keep],
             length = real_len[keep])
}

#' @rdname trigger_runs
#' @return `trigger_edges()` returns a plain integer vector of the sample
#'   indices; `trigger_runs()` returns a data frame with `index`, `code` and
#'   `length` (the pulse duration in samples), which debouncing needs in order
#'   to tell a settle artefact from the pulse it precedes.
#' @export
trigger_edges <- function(trig, trigger_max = 200, min_pulse_s = 0, fs = 1) {
  if (min_pulse_s > 0 && missing(fs))
    stop("`min_pulse_s` is in seconds, so `fs` must be given too. Without it ",
         "the threshold is measured against a placeholder rate of 1 Hz and ",
         "silently has no effect.", call. = FALSE)
  trigger_runs(trig, trigger_max = trigger_max, min_pulse_s = min_pulse_s,
               fs = fs)$index
}

# Internal: thin a cluster of near-simultaneous edges down to one.
#
# Which one matters. A parallel port settles through intermediate values
# BEFORE it reaches the code the experiment actually sent, so the first edge
# of a cluster is systematically the artefact and the real pulse is the one
# that follows it. Keeping the first -- the obvious reading of "collapse to
# the first" -- therefore reports the wrong code at the wrong time. On a
# 100 ms code-1 pulse preceded by 1 ms settle runs of codes 3 and 4, it kept
# code 3. Across 30 archive recordings it discarded 346 of 5311 edges, and
# 197 of those were LONGER than the edge that suppressed them.
#
# `weight` (pulse duration) decides instead, accepted greedily in descending
# order exactly as enforce_min_distance() does for peaks. With no weights it
# degrades to first-wins.
debounce_edges <- function(edge, debounce_s, fs, weight = NULL) {
  if (length(edge) < 2L || debounce_s <= 0) return(rep(TRUE, length(edge)))
  min_gap <- debounce_s * fs
  if (is.null(weight)) weight <- rep(1, length(edge))
  ord <- order(weight, decreasing = TRUE)
  acc <- integer(0)
  for (i in ord)
    if (!length(acc) || all(abs(edge[i] - edge[acc]) >= min_gap)) acc <- c(acc, i)
  keep <- logical(length(edge))
  keep[acc] <- TRUE
  keep
}

# Internal: settle on the value the trigger line idles at.
#
# A fixed number, or "auto" to take it from the data. Auto exists because one
# archive is not one convention: in the BIOPAC set this was built against some
# recordings idle at 0 and others at 240, so a batch loop with a single hard
# coded value silently loses every trigger in whichever half it guessed wrong.
#
# The estimator is the modal value, because a trigger line spends nearly all of
# its time idle -- 94% of samples on the recordings here. That assumption is
# checked rather than trusted: below `min_share` the channel does not look like
# a line that idles, so auto declines and says so instead of subtracting a
# number derived from noise.
resolve_trigger_idle <- function(trig, trigger_idle, min_share = 0.5) {
  if (is.numeric(trigger_idle) && length(trigger_idle) == 1L &&
      is.finite(trigger_idle))
    return(trigger_idle)

  if (!identical(trigger_idle, "auto"))
    stop("`trigger_idle` must be a single finite number, or \"auto\" to take ",
         "the idle level from the data. It is the value the trigger line sits ",
         "at when nothing is being sent.", call. = FALSE)

  finite_trig <- trig[is.finite(trig)]
  if (!length(finite_trig)) return(0)
  tab   <- table(finite_trig)
  modal <- as.numeric(names(tab)[which.max(tab)])
  share <- max(tab) / length(finite_trig)

  # Codes are integers of at least 1, so an idle level below half a count is
  # zero and there is nothing to subtract. This is not hypothetical: one
  # recording in the archive idles at a denormal float of 2.05e-289 -- the same
  # value trigger_runs() guards its lower bound against -- and auto reported
  # "the line idles at 2.05227e-289" and subtracted it. Numerically that
  # changes nothing, but it is an alarming thing to print at someone and it
  # would mask a genuine idle level if one were ever that small.
  if (abs(modal) < 0.5) return(0)

  if (share < min_share) {
    warning(sprintf(
      paste0("trigger_idle = \"auto\" could not identify an idle level: the ",
             "commonest value (%s) covers only %.1f%% of the channel, below ",
             "the %.0f%% a line that idles would show. Using 0. Inspect the ",
             "channel and pass an explicit value if this is wrong."),
      format(modal), 100 * share, 100 * min_share), call. = FALSE)
    return(0)
  }
  if (modal != 0)
    message(sprintf(
      "trigger_idle = \"auto\": the line idles at %s (%.1f%% of samples); subtracting it.",
      format(modal), 100 * share))
  modal
}

# Internal: turn a raw digital code channel into an events table.
#
# Split out of resp_read_acq() for the same reason trigger_runs() was: the
# logic can then be exercised on a bare numeric vector, with no .acq file and
# no Python toolchain. Left inline, the only thing a test could assert about
# `trigger_idle` was that the argument existed -- which a mutation removing its
# effect survives.
acq_trigger_events <- function(trig, trig_fs,
                               trigger_values = NULL,
                               trigger_max    = 200,
                               trigger_idle   = 0,
                               min_pulse_s    = 0,
                               debounce_s     = 0) {

  trigger_idle <- resolve_trigger_idle(trig, trigger_idle)
  if (trigger_idle != 0) trig <- trig - trigger_idle

  tr   <- trigger_runs(trig, trigger_max = trigger_max,
                       min_pulse_s = min_pulse_s, fs = trig_fs)
  edge <- tr$index
  runs <- tr$length

  # Counted the same way trigger_runs() counts, so the diagnostic describes
  # the run structure that was actually analysed.
  n_raw_runs <- nrow(trigger_runs(trig, trigger_max = Inf, fs = trig_fs))
  if (!length(edge) && n_raw_runs > 0L) {
    finite_trig <- trig[is.finite(trig)]
    # The modal value IS the idle level: a trigger line spends nearly all of
    # its time idle. Naming it lets the caller copy the fix out of the message
    # rather than work it out.
    tab   <- table(finite_trig)
    modal <- as.numeric(names(tab)[which.max(tab)])
    modal_pct <- 100 * max(tab) / length(finite_trig)
    message(
      n_raw_runs, " run(s) of a non-zero code were found on the trigger channel ",
      "but none survived the filters (codes must be >= 1 and < trigger_max = ",
      trigger_max, "). Observed codes: ",
      paste(utils::head(sort(unique(finite_trig[finite_trig != 0])), 8),
            collapse = ", "), ".",
      if (modal != 0)
        paste0(" The line sits at ", format(modal), " for ",
               sprintf("%.1f%%", modal_pct), " of the recording, so that is ",
               "its idle level, not a code -- this is a stuck upper bit. Pass ",
               "trigger_idle = ", format(modal), " to subtract it. Do NOT ",
               "simply raise `trigger_max`: that admits the idle stretches ",
               "themselves as triggers, which on this archive roughly doubles ",
               "the edge count.")
      else
        " Raise `trigger_max` if these really are codes.")
  }

  if (!length(edge)) return(NULL)

  vals <- trig[edge]
  if (!is.null(trigger_values)) {
    keep <- vals %in% trigger_values
    edge <- edge[keep]; vals <- vals[keep]; runs <- runs[keep]
    if (!length(edge))
      message("No trigger edge carried a code in `trigger_values`. ",
              "Codes present: ",
              paste(utils::head(sort(unique(trig[is.finite(trig) & trig != 0])), 8),
                    collapse = ", "), ".")
  }
  if (length(edge) > 1L && debounce_s > 0) {
    keep <- debounce_edges(edge, debounce_s, trig_fs, weight = runs)
    if (any(!keep))
      message(sum(!keep), " trigger edge(s) within ", debounce_s,
              " s of a longer pulse were treated as bounce and dropped.")
    edge <- edge[keep]; vals <- vals[keep]; runs <- runs[keep]
  }
  if (!length(edge)) return(NULL)

  data.frame(time  = (edge - 1L) / trig_fs,
             label = as.character(vals),
             value = vals,
             stringsAsFactors = FALSE)
}

# Internal: import bioread once per session, with an actionable error.
get_bioread <- function() {
  if (!requireNamespace("reticulate", quietly = TRUE))
    stop("Reading .acq files needs the reticulate package: ",
         "install.packages(\"reticulate\").", call. = FALSE)
  tryCatch(
    reticulate::import("bioread"),
    error = function(e)
      stop("The Python package 'bioread' is not available to reticulate. ",
           "Declare it with reticulate::py_require(\"bioread\"); py_install() ",
           "may not persist under reticulate's ephemeral uv environments. ",
           "Original error: ", conditionMessage(e), call. = FALSE)
  )
}

#' List the channels in a BIOPAC .acq file
#'
#' @param path Path to the `.acq` file.
#' @return A data frame of `index`, `name`, `units` and `fs`, invisibly
#'   printed as well.
#' @export
resp_acq_channels <- function(path) {
  if (!file.exists(path)) stop("No such file: ", path, call. = FALSE)
  bioread <- get_bioread()
  dat <- bioread$read_file(path)

  rows <- lapply(seq_along(dat$channels), function(i) {
    ch <- dat$channels[[i]]
    data.frame(
      index = i,
      name  = tryCatch(as.character(ch$name),  error = function(e) NA_character_),
      units = tryCatch(as.character(ch$units), error = function(e) NA_character_),
      fs    = tryCatch(as.numeric(ch$samples_per_second), error = function(e) NA_real_),
      n     = tryCatch(length(ch$data), error = function(e) NA_integer_),
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}

#' Read a respiratory channel from a BIOPAC .acq file
#'
#' @param path Path to the `.acq` file.
#' @param channel Channel to read: an integer index, or a string matched
#'   case-insensitively against channel names.
#' @param id Identifier to attach to the recording.
#' @param trigger_channel Optional channel index holding digital trigger
#'   codes. When given, rising edges are extracted into the `events` table.
#' @param trigger_values Trigger codes to keep. `NULL` keeps every non-zero
#'   code.
#' @param trigger_max Codes at or above this are treated as noise or
#'   saturation and dropped. On the recordings this was developed against most
#'   trigger channels sit at 240-243 throughout, which is why the threshold
#'   matters: those are not triggers.
#' @param trigger_idle Value the trigger line sits at when nothing is being
#'   sent, subtracted from the channel before any code is read. Default 0.
#'   Pass `"auto"` to take it from the data as the modal sample value.
#'
#'   Set it when the line idles somewhere else, which on real hardware is
#'   common: a stuck upper bit puts the idle level at 240 and delivers codes
#'   1-8 as 241-248. Two of the first three `.acq` files in the archive this
#'   was built against do exactly that, idling at 240 for 94% of the recording,
#'   and the default `trigger_max = 200` therefore returns no events at all.
#'
#'   `"auto"` exists because one archive is not one convention: in that same
#'   BIOPAC set some recordings idle at 0 and others at 240, so a batch loop
#'   with a single hard-coded value silently loses every trigger in whichever
#'   half it guessed wrong. It takes the modal value, since a trigger line
#'   spends nearly all its time idle, and declines with a warning if the
#'   commonest value covers less than half the channel — which means the
#'   channel does not look like a line that idles, and no offset should be
#'   guessed from it. The resolved number, not the string, is what appears in
#'   `resp_provenance()`.
#'
#'   Raising `trigger_max` is **not** the fix, and the message this function
#'   emits will say so: at `trigger_max = Inf` the idle stretches themselves
#'   satisfy `code >= 1` and are reported as triggers, which on one archive
#'   recording turned 179 real edges into 359. Subtracting the idle level is
#'   the fix, and the message names the value to use.
#' @param min_pulse_s Runs of a valid code shorter than this are ignored.
#'   Default 0, which keeps every code change. A parallel port settling through
#'   intermediate values produces runs of a few milliseconds between the real
#'   ones -- on a recording here, genuine pulses last about 1000 ms while
#'   settle artefacts last 5 to 80 ms -- so a value around 0.1 removes them.
#'   Left off by default because the correct value is hardware-specific and
#'   silently dropping triggers is worse than reporting extra ones.
#' @param debounce_s Edges within this many seconds of each other are thinned
#'   to one, keeping the one whose pulse was held **longest**. Default 0, i.e.
#'   off. Cable noise produces bursts of spurious edges and debouncing is the
#'   remedy, but the default is off for two measured reasons: on the archive
#'   this was built against, genuine inter-event gaps go down to 0.778 s with
#'   a 5th percentile of 1.083 s, so any debounce near a second sits inside
#'   the real event distribution; and dropping a genuine trigger is far worse
#'   than reporting an extra one. Set it deliberately, having looked at your
#'   own inter-edge distribution.
#'
#' @return A `resp_recording`.
#' @export
resp_read_acq <- function(path,
                          channel,
                          id              = NA_character_,
                          trigger_channel = NULL,
                          trigger_values  = NULL,
                          trigger_max     = 200,
                          trigger_idle    = 0,
                          min_pulse_s     = 0,
                          debounce_s      = 0) {

  if (!file.exists(path)) stop("No such file: ", path, call. = FALSE)
  bioread <- get_bioread()
  dat <- bioread$read_file(path)

  n_ch <- length(dat$channels)
  if (is.character(channel)) {
    nms <- vapply(seq_len(n_ch), function(i)
      tryCatch(as.character(dat$channels[[i]]$name),
               error = function(e) ""), character(1))
    # A literal, case-insensitive match. It has to be done by lower-casing both
    # sides: grep() silently discards `ignore.case` when `fixed = TRUE`, so the
    # two options cannot be combined. A literal match is required because
    # BIOPAC channel names routinely contain "(", ")", "+" and ".", and a user
    # copying a name out of resp_acq_channels() would otherwise be told it does
    # not exist.
    hit <- grep(tolower(channel), tolower(nms), fixed = TRUE)
    if (!length(hit))
      stop("No channel name matches \"", channel, "\". Available: ",
           paste(nms, collapse = " | "), call. = FALSE)
    if (length(hit) > 1L)
      stop("Channel name \"", channel, "\" matches ", length(hit),
           " channels (", paste(nms[hit], collapse = ", "),
           "). Use an index instead.", call. = FALSE)
    channel <- hit
  }
  channel <- as.integer(channel)
  if (channel < 1L || channel > n_ch)
    stop("Channel index ", channel, " is outside 1:", n_ch, ".", call. = FALSE)

  ch  <- dat$channels[[channel]]
  sig <- as.numeric(ch$data)
  fs  <- tryCatch(as.numeric(ch$samples_per_second),
                  error = function(e) as.numeric(dat$samples_per_second))
  ch_units <- tryCatch(as.character(ch$units), error = function(e) "arbitrary")

  events <- NULL
  if (!is.null(trigger_channel)) {
    trigger_channel <- as.integer(trigger_channel)
    if (is.na(trigger_channel) || trigger_channel < 1L || trigger_channel > n_ch)
      stop("`trigger_channel` index ", trigger_channel, " is outside 1:", n_ch,
           ".", call. = FALSE)
    trig <- as.numeric(dat$channels[[trigger_channel]]$data)
    trig_fs <- tryCatch(
      as.numeric(dat$channels[[trigger_channel]]$samples_per_second),
      error = function(e) fs)

    # Resolved here, not inside, so that provenance records the number that was
    # actually subtracted rather than the string "auto".
    trigger_idle <- resolve_trigger_idle(trig, trigger_idle)
    events <- acq_trigger_events(
      trig, trig_fs, trigger_values = trigger_values, trigger_max = trigger_max,
      trigger_idle = trigger_idle, min_pulse_s = min_pulse_s,
      debounce_s = debounce_s)
  }

  # How the events were derived belongs in provenance, not only in the caller's
  # script. `trigger_idle` in particular renumbers every code, so a recording
  # read with it and one read without are not comparable, and nothing else in
  # the object would say which you have.
  prov <- sprintf("read_acq(%s, channel=%d) at %.6g Hz, %d samples",
                  basename(path), channel, fs, length(sig))
  if (!is.null(trigger_channel))
    prov <- c(prov, sprintf(
      "triggers from channel %d: %d event(s)%s, trigger_max=%s, min_pulse_s=%g, debounce_s=%g",
      trigger_channel, if (is.null(events)) 0L else nrow(events),
      if (trigger_idle != 0)
        sprintf(", trigger_idle=%s subtracted from every code", format(trigger_idle))
      else "",
      format(trigger_max), min_pulse_s, debounce_s))

  resp_recording(
    signal     = sig,
    fs         = fs,
    id         = id,
    units      = ch_units,
    fs_native  = fs,
    events     = events,
    meta       = list(source_file = normalizePath(path, mustWork = FALSE),
                      channel     = channel),
    provenance = prov
  )
}
