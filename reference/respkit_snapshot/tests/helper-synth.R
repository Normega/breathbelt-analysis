# =====================================================================
#  helper-synth.R — synthetic respiratory signals with known ground truth
#
#  Every timing and morphology feature respkit computes can be checked
#  against a signal whose breath durations and duty cycles were chosen in
#  advance. Without this, a detector that is systematically half a second
#  late looks exactly like a detector that is correct.
# =====================================================================

#' Build a synthetic respiratory signal
#'
#' @param durations Numeric vector of breath durations in seconds.
#' @param duty Inspiratory fraction of each cycle, recycled.
#' @param amplitude Peak-to-trough excursion, recycled.
#' @param fs Sampling rate.
#' @param noise SD of additive Gaussian noise.
#' @param drift Amplitude of a slow linear-plus-sinusoidal baseline drift.
#'
#' @return A list with `signal`, `fs`, and the ground-truth `trough_times`,
#'   `peak_times`, `durations`, `duty` and `amplitude`.
synth_resp <- function(durations = rep(4, 20), duty = 0.4, amplitude = 1,
                       fs = 25, noise = 0, drift = 0, seed = 1) {
  set.seed(seed)
  duty <- rep_len(duty, length(durations))
  amp  <- rep_len(amplitude, length(durations))

  sig <- numeric(0)
  trough_t <- 0
  peak_t   <- numeric(length(durations))
  elapsed  <- 0

  for (i in seq_along(durations)) {
    D  <- durations[i]
    ti <- D * duty[i]
    te <- D - ti

    n_i <- round(ti * fs)
    n_e <- round(te * fs)

    # Rising half-sine over the inspiratory phase, falling half-sine over the
    # expiratory phase. Both endpoints are excluded so consecutive cycles do
    # not duplicate the joining sample.
    up   <- amp[i] * sin(pi / 2 * (seq_len(n_i) - 1) / n_i)
    down <- amp[i] * cos(pi / 2 * (seq_len(n_e) - 1) / n_e)

    sig <- c(sig, up, down)
    peak_t[i] <- elapsed + (n_i) / fs
    elapsed <- elapsed + (n_i + n_e) / fs
    trough_t <- c(trough_t, elapsed)
  }

  sig <- c(sig, 0)
  n <- length(sig)
  t <- (seq_len(n) - 1) / fs

  if (drift != 0)
    sig <- sig + drift * (t / max(t)) + drift * 0.5 * sin(2 * pi * 0.005 * t)
  if (noise > 0)
    sig <- sig + stats::rnorm(n, sd = noise)

  list(signal = sig, fs = fs, time = t,
       trough_times = trough_t, peak_times = peak_t,
       durations = durations, duty = duty, amplitude = amp)
}

# Minimal assertion helpers, so tests run under plain `Rscript` with no
# testthat installed. Failures stop the script with a located message.
ok <- function(cond, what) {
  if (!isTRUE(cond)) stop("FAIL: ", what, call. = FALSE)
  cat("  ok  ", what, "\n", sep = "")
  invisible(TRUE)
}

near <- function(a, b, tol, what) {
  d <- max(abs(a - b))
  if (!is.finite(d) || d > tol)
    stop(sprintf("FAIL: %s (max deviation %.6g > tol %.6g)", what, d, tol),
         call. = FALSE)
  cat(sprintf("  ok   %s (max dev %.5g)\n", what, d))
  invisible(TRUE)
}

errors_with <- function(expr, pattern, what) {
  e <- tryCatch({ force(expr); NULL }, error = function(e) conditionMessage(e))
  if (is.null(e)) stop("FAIL: ", what, " (no error raised)", call. = FALSE)
  if (!grepl(pattern, e, fixed = FALSE))
    stop("FAIL: ", what, " (message was: ", e, ")", call. = FALSE)
  cat("  ok  ", what, "\n", sep = "")
  invisible(TRUE)
}

# As errors_with(), but for warnings. The expression is run to completion --
# a warning is not an early exit -- so this also confirms the function still
# returns rather than aborting.
warns_with <- function(expr, pattern, what) {
  w <- character(0)
  withCallingHandlers(force(expr),
                      warning = function(c) {
                        w <<- c(w, conditionMessage(c))
                        invokeRestart("muffleWarning")
                      })
  if (!length(w)) stop("FAIL: ", what, " (no warning raised)", call. = FALSE)
  if (!any(grepl(pattern, w, fixed = FALSE)))
    stop("FAIL: ", what, " (warnings were: ", paste(w, collapse = " | "), ")",
         call. = FALSE)
  cat("  ok  ", what, "\n", sep = "")
  invisible(TRUE)
}

# Asserts the expression completes without any warning at all.
no_warning <- function(expr, what) {
  w <- character(0)
  withCallingHandlers(force(expr),
                      warning = function(c) {
                        w <<- c(w, conditionMessage(c))
                        invokeRestart("muffleWarning")
                      })
  if (length(w))
    stop("FAIL: ", what, " (warned: ", paste(w, collapse = " | "), ")",
         call. = FALSE)
  cat("  ok  ", what, "\n", sep = "")
  invisible(TRUE)
}
