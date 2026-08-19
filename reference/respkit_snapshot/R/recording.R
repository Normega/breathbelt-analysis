# =====================================================================
#  recording.R — the self-describing container everything else uses
#
#  DESIGN NOTE
#  -----------
#  The single most damaging defect in the pipeline this package replaces
#  was that the sampling rate written into the serialised object was the
#  rate that was *requested*, not the rate that was *achieved*. Three
#  separate downstream scripts independently rediscovered the discrepancy
#  and each patched around it differently, so timing errors of ~2.5%
#  survived in some code paths and not others.
#
#  A resp_recording therefore records:
#    fs           the true, achieved sampling rate — the only rate any
#                 analysis code should ever use
#    fs_native    the rate the signal was acquired at, before any resampling
#    provenance   an append-only log of every transformation applied
#
#  There is deliberately no "target_fs" or "nominal_fs" field. If you
#  cannot achieve a rate exactly, the recording tells you what you got.
# =====================================================================

RESPKIT_SCHEMA <- 1L

#' Create a respiratory recording object
#'
#' @param signal Numeric vector of the respiratory trace.
#' @param fs True sampling rate of `signal`, in Hz.
#' @param id Optional identifier (participant, run, file).
#' @param units Character label for the signal's units, e.g. "volts",
#'   "arbitrary", "z". Carried through so that amplitude features remain
#'   interpretable.
#' @param fs_native Acquisition sampling rate before any resampling.
#'   Defaults to `fs`.
#' @param t0 Time in seconds, on the original recording clock, of the
#'   first sample. Non-zero after `resp_slice()` or trimming, so that
#'   event times computed upstream stay valid.
#'
#'   Keep it a recording-relative offset rather than an absolute wall clock.
#'   Sample times are `t0 + k / fs`, so a very large `t0` spends its precision
#'   on the offset: at a Unix-epoch value of 1.7e9 the sample spacing carries
#'   about 2e-7 s of error, and every duration derived by subtracting two
#'   sample times inherits it. That is 5e-6 of a sample at 25 Hz and changes
#'   nothing in practice — measured, the breath count and median duration are
#'   unchanged and the duration SD moves in the eighth decimal — but there is
#'   no reason to pay it. `adapter_timestamped()` in `inst/examples/adapters.R`
#'   is the reachable path, if your time column happens to be epoch seconds.
#' @param events Optional data frame of discrete events (triggers, session
#'   onsets). Must contain a numeric `time` column in seconds on the same
#'   clock as `t0`. A `label` column is recommended.
#' @param meta Named list of arbitrary study-specific metadata. Nothing in
#'   respkit reads it; it is round-tripped through serialisation so you can
#'   keep side, condition, belt position, etc. attached to the signal.
#' @param provenance Character vector of prior processing steps.
#'
#' @return An object of class `resp_recording`.
#' @export
resp_recording <- function(signal,
                           fs,
                           id         = NA_character_,
                           units      = "arbitrary",
                           fs_native  = NULL,
                           t0         = 0,
                           events     = NULL,
                           meta       = list(),
                           provenance = character(0)) {

  signal <- as.numeric(signal)

  if (length(signal) == 0L)
    stop("`signal` is empty.", call. = FALSE)
  if (!is.numeric(fs) || length(fs) != 1L || !is.finite(fs) || fs <= 0)
    stop("`fs` must be a single positive finite number (Hz).", call. = FALSE)
  if (!is.numeric(t0) || length(t0) != 1L || !is.finite(t0))
    stop("`t0` must be a single finite number (seconds).", call. = FALSE)
  if (!is.list(meta))
    stop("`meta` must be a list.", call. = FALSE)

  if (is.null(fs_native)) fs_native <- fs
  if (!is.numeric(fs_native) || length(fs_native) != 1L ||
      !is.finite(fs_native) || fs_native <= 0)
    stop("`fs_native` must be a single positive finite number (Hz).", call. = FALSE)

  if (!is.null(events)) {
    if (!is.data.frame(events))
      stop("`events` must be a data frame or NULL.", call. = FALSE)
    if (!"time" %in% names(events))
      stop("`events` must have a numeric `time` column, in seconds.", call. = FALSE)
    # A factor must go via as.character(). as.numeric() on a factor returns
    # its integer level codes, so trigger times of 120.5, 300.25 and 600 s
    # would silently become 1, 2 and 3 -- still plausible-looking seconds.
    # Factors arrive from read.csv(stringsAsFactors = TRUE) and from older
    # serialised trial tables.
    if (is.factor(events$time)) events$time <- as.character(events$time)
    if (!is.numeric(events$time)) {
      converted <- suppressWarnings(as.numeric(events$time))
      if (any(is.na(converted) & !is.na(events$time)))
        stop("`events$time` must be numeric seconds; it is ",
             class(events$time)[1], " and could not be converted.", call. = FALSE)
      events$time <- converted
    }
  }

  n_nonfinite <- sum(!is.finite(signal))
  if (n_nonfinite == length(signal))
    stop("`signal` contains no finite values.", call. = FALSE)

  structure(
    list(
      schema     = RESPKIT_SCHEMA,
      id         = as.character(id)[1],
      signal     = signal,
      fs         = as.numeric(fs),
      fs_native  = as.numeric(fs_native),
      units      = as.character(units)[1],
      t0         = as.numeric(t0),
      events     = events,
      meta       = meta,
      provenance = as.character(provenance)
    ),
    class = "resp_recording"
  )
}

#' @rdname resp_recording
#' @param x Object to test.
#' @export
is_resp_recording <- function(x) inherits(x, "resp_recording")

#' Coerce common inputs to a resp_recording
#'
#' Accepts an existing `resp_recording` (returned unchanged), a bare numeric
#' vector (requires `fs`), or a list carrying at least `signal` and `fs`.
#'
#' @param x A `resp_recording`, numeric vector, or list.
#' @param fs Sampling rate, required when `x` is a bare numeric vector.
#' @param ... Further arguments passed to [resp_recording()].
#' @export
as_resp_recording <- function(x, fs = NULL, ...) {
  if (is_resp_recording(x)) {
    # An explicitly supplied rate that contradicts the object's own is the
    # single most dangerous thing this package can let past, and silently
    # discarding it is how a detection computed at one rate gets measured
    # against a recording at another: every duration then comes out scaled by
    # the ratio, with no error anywhere.
    if (!is.null(fs) && is.numeric(fs) && length(fs) == 1L && is.finite(fs) &&
        abs(fs - x$fs) > 1e-9 * max(1, abs(x$fs)))
      stop("`fs` was given as ", format(fs), " Hz but the recording is at ",
           format(x$fs), " Hz. These must agree: if a detection was computed ",
           "on a different copy of the signal, measure it on that same copy.",
           call. = FALSE)
    return(x)
  }

  if (is.numeric(x)) {
    if (is.null(fs))
      stop("`fs` must be supplied when coercing a bare numeric vector.", call. = FALSE)
    return(resp_recording(x, fs = fs, ...))
  }

  if (is.list(x)) {
    if (!all(c("signal", "fs") %in% names(x)))
      stop("A list must contain at least `signal` and `fs` to be coerced.", call. = FALSE)
    known <- c("signal", "fs", "id", "units", "fs_native", "t0", "events",
               "meta", "provenance", "schema")
    args <- list(signal = x$signal, fs = if (is.null(fs)) x$fs else fs)
    for (nm in setdiff(known, c("signal", "fs", "schema")))
      if (!is.null(x[[nm]])) args[[nm]] <- x[[nm]]

    # Anything this constructor does not recognise goes into `meta` rather
    # than being dropped. Study-specific fields such as side, abcode or
    # trigger counts ride along on exactly these lists, and losing them on
    # load is silent data loss.
    extra <- x[setdiff(names(x), known)]
    if (length(extra))
      args$meta <- utils::modifyList(
        if (is.null(args$meta)) list() else args$meta, extra)

    return(do.call(resp_recording, utils::modifyList(args, list(...))))
  }

  stop("Cannot coerce an object of class ", paste(class(x), collapse = "/"),
       " to a resp_recording.", call. = FALSE)
}

#' Sample times of a recording
#'
#' Returns times in seconds on the original recording clock, i.e. offset by
#' `t0`. Use `absolute = FALSE` for times relative to the first sample.
#'
#' @param x A `resp_recording`.
#' @param absolute Include the `t0` offset (default `TRUE`).
#' @export
resp_time <- function(x, absolute = TRUE) {
  x <- as_resp_recording(x)
  t <- (seq_along(x$signal) - 1L) / x$fs
  if (absolute) t + x$t0 else t
}

#' Duration of a recording in seconds
#'
#' @param x A `resp_recording`.
#' @export
resp_duration <- function(x) {
  x <- as_resp_recording(x)
  length(x$signal) / x$fs
}

#' Extract a time window from a recording
#'
#' The returned recording keeps a correct `t0`, so downstream times stay on
#' the original clock and nothing needs to remember how much was trimmed.
#'
#' @param x A `resp_recording`.
#' @param from,to Window bounds in seconds on the recording clock. `NULL`
#'   means "from the start" / "to the end".
#' @param absolute Interpret `from`/`to` on the absolute clock (default) or
#'   relative to the first sample.
#' @export
resp_slice <- function(x, from = NULL, to = NULL, absolute = TRUE) {
  x <- as_resp_recording(x)
  t <- resp_time(x, absolute = absolute)

  if (is.null(from)) from <- -Inf
  if (is.null(to))   to   <-  Inf
  if (length(from) != 1L || length(to) != 1L)
    stop("`from` and `to` must each be a single value.", call. = FALSE)
  if (is.na(from) || is.na(to))
    stop("`from` and `to` must not be NA.", call. = FALSE)
  if (from > to)
    stop("`from` (", from, ") is after `to` (", to, ").", call. = FALSE)

  keep <- which(t >= from & t <= to)
  if (length(keep) == 0L)
    stop("The requested window contains no samples. Recording spans ",
         sprintf("%.2f", min(t)), "-", sprintf("%.2f", max(t)), " s.", call. = FALSE)

  new_t0 <- if (absolute) t[keep[1]] else t[keep[1]] + x$t0

  ev <- x$events
  if (!is.null(ev) && nrow(ev) > 0L) {
    lo <- if (absolute) from else from + x$t0
    hi <- if (absolute) to   else to   + x$t0
    # which() rather than a logical subscript: an NA time would otherwise
    # index an all-NA row into the result, so the event is neither kept nor
    # dropped and every other column of it is wiped.
    ev <- ev[which(ev$time >= lo & ev$time <= hi), , drop = FALSE]
  }

  out <- x
  out$signal     <- x$signal[keep]
  out$t0         <- new_t0
  out$events     <- ev
  out$provenance <- c(x$provenance,
                      sprintf("slice(from=%.4f, to=%.4f) -> t0=%.4f, n=%d",
                              from, to, new_t0, length(keep)))
  out
}

#' Processing history of a recording
#'
#' @param x A `resp_recording`.
#' @export
resp_provenance <- function(x) as_resp_recording(x)$provenance

# Internal: append a provenance line without touching anything else.
add_provenance <- function(x, ...) {
  x$provenance <- c(x$provenance, sprintf(...))
  x
}

#' @export
print.resp_recording <- function(x, ...) {
  cat("<resp_recording>\n")
  cat(sprintf("  id         : %s\n", x$id))
  cat(sprintf("  samples    : %s\n", format(length(x$signal), big.mark = ",")))
  cat(sprintf("  fs         : %.6g Hz", x$fs))
  if (!isTRUE(all.equal(x$fs, x$fs_native)))
    cat(sprintf("   (native %.6g Hz, decimated %.4gx)", x$fs_native, x$fs_native / x$fs))
  cat("\n")
  cat(sprintf("  duration   : %.2f s (%.2f min)\n",
              resp_duration(x), resp_duration(x) / 60))
  cat(sprintf("  clock      : t0 = %.4f s\n", x$t0))
  cat(sprintf("  units      : %s\n", x$units))
  n_ev <- if (is.null(x$events)) 0L else nrow(x$events)
  cat(sprintf("  events     : %d\n", n_ev))
  if (length(x$meta))
    cat(sprintf("  meta       : %s\n", paste(names(x$meta), collapse = ", ")))
  if (length(x$provenance)) {
    cat("  provenance :\n")
    for (p in x$provenance) cat("    - ", p, "\n", sep = "")
  }
  invisible(x)
}

#' @export
summary.resp_recording <- function(object, ...) {
  s <- object$signal
  finite <- s[is.finite(s)]
  out <- list(
    id          = object$id,
    n           = length(s),
    fs          = object$fs,
    duration_s  = resp_duration(object),
    n_nonfinite = sum(!is.finite(s)),
    min         = if (length(finite)) min(finite) else NA_real_,
    max         = if (length(finite)) max(finite) else NA_real_,
    mean        = if (length(finite)) mean(finite) else NA_real_,
    sd          = if (length(finite)) stats::sd(finite) else NA_real_,
    iqr         = if (length(finite)) stats::IQR(finite) else NA_real_
  )
  class(out) <- "summary.resp_recording"
  out
}
