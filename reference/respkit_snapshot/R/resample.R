# =====================================================================
#  resample.R — exact multistage decimation
#
#  WHAT WENT WRONG BEFORE
#  ----------------------
#  The original helper staged decimation through factors of at most 13
#  (a numerical-stability precaution inherited from MATLAB) using:
#
#      remaining <- q
#      while (remaining > 1) {
#        step      <- min(remaining, 13)
#        x         <- signal::decimate(x, step)
#        remaining <- remaining %/% step        # <- integer division
#      }
#
#  Integer division silently discards the remainder, so the achieved
#  decimation is almost never the requested one:
#
#      q = 80  -> 13 x 6  = 78    (2000 Hz becomes 25.641 Hz, not 25)
#      q = 20  -> 13      = 13    (a 35% error)
#      q = 50  -> 13 x 3  = 39
#      q = 100 -> 13 x 7  = 91
#
#  The caller was then told the new rate was `fs / q`, which is wrong by
#  the same margin, and every time derived from sample indices inherited
#  the error.
#
#  THE FIX
#  -------
#  Factor `q` into its primes and greedily recombine them into stages that
#  are each <= max_factor. The product of the stages is then exactly `q`
#  whenever `q` has no prime factor larger than max_factor. When it does
#  (e.g. q = 17, or q = 34 = 2 x 17), that prime is emitted as its own
#  oversized stage and a warning is issued, because a slightly harder
#  filtering problem is far better than a silently wrong sampling rate.
#
#  resp_decimate() always reports the rate it actually achieved.
# =====================================================================

# Internal: prime factorisation by trial division. `q` here is a small
# integer (a decimation factor), so trial division is more than adequate.
prime_factors <- function(q) {
  q <- as.integer(q)
  if (q <= 1L) return(integer(0))
  out <- integer(0)
  n   <- q
  d   <- 2L
  while (d * d <= n) {
    while (n %% d == 0L) {
      out <- c(out, d)
      n   <- n %/% d
    }
    d <- d + 1L
  }
  if (n > 1L) out <- c(out, n)
  out
}

#' Split a decimation factor into exact multistage steps
#'
#' Returns integer stages whose product is exactly `q`, each no larger than
#' `max_factor` where the arithmetic permits. Decimating in stages keeps the
#' anti-alias filter well conditioned; a single stage of 80 requires a filter
#' with a normalised cutoff around 0.0125, where direct-form coefficients
#' lose precision.
#'
#' @param q Integer decimation factor (>= 1).
#' @param max_factor Largest permitted single stage. Default 13, matching
#'   the conventional MATLAB/`signal` guidance.
#' @param hard_max Largest single stage that will be tolerated at all, when
#'   `q` has a prime factor that cannot be split. Above this the function
#'   refuses rather than returning a decimation that would corrupt the signal.
#'
#' @return Integer vector of stages, ordered largest first.
#'   `prod(decimation_stages(q))` is always exactly `q`.
#'
#' @section Why the stage limit is enforced rather than advisory:
#' `signal::decimate` designs a Chebyshev anti-alias filter whose cutoff
#' scales as `0.8 / q`, and it degrades long before it fails. On a 0.25 Hz
#' sinusoid decimated in one stage from 5000 Hz, the recovered amplitude is
#' 0.99 at q = 43, 0.92 at q = 70, 1.33 at q = 90, 1.65 at q = 100, and the
#' output is entirely `NaN` from q = 120. The 33% and 65% errors are the
#' dangerous ones: they are finite, so nothing downstream notices.
#'
#' @examples
#' decimation_stages(80)   # 10 8      (product 80, not 78)
#' decimation_stages(20)   # 10 2      (product 20, not 13)
#' decimation_stages(169)  # 13 13
#' @export
decimation_stages <- function(q, max_factor = 13L, hard_max = 40L) {
  q <- as.integer(round(q))
  if (is.na(q) || q < 1L)
    stop("`q` must be a positive integer.", call. = FALSE)
  if (q == 1L) return(integer(0))
  if (max_factor < 2L)
    stop("`max_factor` must be at least 2.", call. = FALSE)

  f <- sort(prime_factors(q), decreasing = TRUE)

  big <- f[f > max_factor]
  f   <- f[f <= max_factor]

  stages <- integer(0)
  while (length(f)) {
    cur <- f[1L]
    f   <- f[-1L]
    i   <- 1L
    while (i <= length(f)) {
      if (cur * f[i] <= max_factor) {
        cur <- cur * f[i]
        f   <- f[-i]
      } else {
        i <- i + 1L
      }
    }
    stages <- c(stages, cur)
  }

  # Prime factors above max_factor cannot be split. Emit them as their own
  # stages so the ratio stays exact, but only while they remain in the range
  # where the anti-alias filter is still trustworthy.
  if (length(big)) {
    if (any(big > hard_max)) {
      alt <- smooth_factor_near(q, max_factor)
      stop("Decimation factor ", q, " has prime factor(s) larger than ",
           hard_max, " (", paste(big[big > hard_max], collapse = ", "),
           "), which cannot be decimated in stages. A single stage that large ",
           "makes signal::decimate return a badly attenuated or entirely ",
           "non-finite signal. ",
           if (!is.na(alt))
             paste0("Use q = ", alt, " instead (factors as ",
                    paste(decimation_stages(alt, max_factor), collapse = "x"),
                    "), or let resp_downsample() choose for you.")
           else
             "Pick a target rate that divides the source rate more smoothly.",
           call. = FALSE)
    }
    warning("Decimation factor ", q, " has prime factor(s) larger than ",
            max_factor, " (", paste(big, collapse = ", "),
            "); using oversized stage(s) so the ratio stays exact. ",
            "Choosing a target rate that divides the source rate more ",
            "smoothly will condition the anti-alias filter better.",
            call. = FALSE)
    stages <- c(big, stages)
  }

  stages <- sort(stages, decreasing = TRUE)
  stopifnot(prod(as.numeric(stages)) == q)
  stages
}

# Internal: the integer nearest `q_target` whose prime factors are all within
# `max_factor`, searched over a window around it. Returns NA if the window
# contains no such integer.
smooth_factor_near <- function(q_target, max_factor = 13L, search = 0.2) {
  lo <- max(2L, as.integer(floor(q_target * (1 - search))))
  hi <- as.integer(ceiling(q_target * (1 + search)))
  if (hi < lo) return(NA_integer_)
  cand <- lo:hi
  ok   <- vapply(cand, function(k) all(prime_factors(k) <= max_factor), logical(1))
  cand <- cand[ok]
  if (!length(cand)) return(NA_integer_)
  cand[which.min(abs(cand - q_target))]
}

#' Decimate a signal by an exact integer factor
#'
#' Applies `signal::decimate()` in stages produced by [decimation_stages()].
#' Each stage carries its own Chebyshev anti-alias filter, so no separate
#' low-pass is required beforehand.
#'
#' @param x A `resp_recording` or a numeric vector.
#' @param q Integer decimation factor.
#' @param fs Sampling rate; required only when `x` is a bare numeric vector.
#' @param max_factor Largest single decimation stage (see [decimation_stages()]).
#'
#' @return An object of the same kind as `x`. For a `resp_recording`, `fs` is
#'   updated to the achieved rate and the stages are logged to provenance.
#'   For a numeric vector, a list with `signal`, `fs`, `q` and `stages`.
#' @export
resp_decimate <- function(x, q, fs = NULL, max_factor = 13L) {
  was_recording <- is_resp_recording(x)
  if (was_recording) {
    fs  <- x$fs
    sig <- x$signal
  } else {
    if (is.null(fs))
      stop("`fs` must be supplied when `x` is not a resp_recording.", call. = FALSE)
    sig <- as.numeric(x)
  }

  q      <- as.integer(round(q))
  stages <- decimation_stages(q, max_factor = max_factor)

  if (length(stages) == 0L) {
    new_fs <- fs
  } else {
    # Against the whole factor, not the largest stage. Checking only the
    # largest lets a signal pass and then starve later stages: q = 169 as
    # 13 x 13 needs 390 samples by that rule, but the second stage then sees
    # only 30 and the output is finite and 79% wrong -- exactly the silent
    # failure the per-stage finiteness check cannot catch.
    min_len <- 30L * q
    if (length(sig) < min_len)
      stop("Signal has ", length(sig), " samples, too few to decimate by ", q,
           " stably (need at least ~", min_len, ", i.e. 30 samples per output ",
           "sample). Decimate less, or filter without decimating.", call. = FALSE)

    for (s in stages) {
      sig <- as.numeric(signal::decimate(sig, s))
      # signal::decimate does not signal failure: an ill-conditioned
      # anti-alias filter simply returns NaN, and the corrupted result would
      # otherwise flow silently into detection.
      if (!all(is.finite(sig)))
        stop("Decimation stage of ", s, " (within q = ", q, ") produced a ",
             "non-finite signal. The anti-alias filter for a stage this large ",
             "is numerically unstable. Decimate to a higher target rate, or ",
             "use a factor whose prime factors are all 13 or below.",
             call. = FALSE)
    }
    new_fs <- fs / q
  }

  if (!was_recording)
    return(list(signal = sig, fs = new_fs, q = q, stages = stages))

  out <- x
  out$signal <- sig
  out$fs     <- new_fs
  out <- add_provenance(
    out, "decimate(q=%d via %s): %.6g Hz -> %.6g Hz, n=%d",
    q, paste(stages, collapse = "x"), fs, new_fs, length(sig))
  out
}

#' Downsample towards a target rate, reporting what was achieved
#'
#' Integer decimation can only reach rates of the form `fs / q`. Rather than
#' pretending the target was met, this function decimates by the integer
#' factor that lands closest to `target_fs` and returns the true resulting
#' rate. Inspect `resp_provenance()` or the returned `fs` to see it.
#'
#' @param x A `resp_recording` or numeric vector.
#' @param target_fs Desired sampling rate in Hz.
#' @param fs Sampling rate, required when `x` is a bare numeric vector.
#' @param max_factor Largest single decimation stage.
#' @param tolerance Relative discrepancy between the achieved and target rate
#'   above which a message is emitted. Default 0.005 (0.5%).
#'
#' @return As [resp_decimate()].
#' @export
resp_downsample <- function(x, target_fs, fs = NULL, max_factor = 13L,
                            tolerance = 0.005) {
  cur_fs <- if (is_resp_recording(x)) x$fs else fs
  if (is.null(cur_fs))
    stop("`fs` must be supplied when `x` is not a resp_recording.", call. = FALSE)
  if (!is.finite(target_fs) || target_fs <= 0)
    stop("`target_fs` must be a positive number.", call. = FALSE)

  if (target_fs >= cur_fs) {
    message(sprintf("No downsampling: fs (%.6g Hz) already at or below target (%.6g Hz).",
                    cur_fs, target_fs))
    if (is_resp_recording(x)) return(x)
    return(list(signal = as.numeric(x), fs = cur_fs, q = 1L, stages = integer(0)))
  }

  q_exact <- cur_fs / target_fs
  q       <- max(1L, as.integer(round(q_exact)))

  # Reroute only when the exact factor would be REFUSED, i.e. it contains a
  # prime above `hard_max`. Rerouting merely because a factor exceeds
  # `max_factor` trades an exact rate for an inexact one to avoid a stage that
  # decimation_stages() considers safe: 850 Hz to 25 Hz needs q = 34 = 2 x 17,
  # which is exact and recovers amplitude identically, yet the old rule
  # substituted q = 33 and a 3% rate error. Every such substitution measured
  # made the achieved rate strictly worse.
  hard_max <- 40L
  if (q > 1L && any(prime_factors(q) > hard_max)) {
    alt <- smooth_factor_near(q_exact, max_factor)
    if (!is.na(alt) && alt != q) {
      message(sprintf(
        paste0("Decimating by %d (%.6g Hz) rather than %d (%.6g Hz): %d has a ",
               "prime factor above %d, which cannot be decimated safely."),
        alt, cur_fs / alt, q, cur_fs / q, q, hard_max))
      q <- alt
    }
  }

  achieved <- cur_fs / q

  if (abs(achieved - target_fs) / target_fs > tolerance)
    message(sprintf(
      paste0("Target %.6g Hz is not an integer divisor of %.6g Hz. ",
             "Decimating by %d gives %.6g Hz; this is the rate that will be ",
             "recorded and used."),
      target_fs, cur_fs, q, achieved))

  resp_decimate(x, q = q, fs = cur_fs, max_factor = max_factor)
}
