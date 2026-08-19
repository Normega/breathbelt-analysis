# =====================================================================
#  features.R — aggregating a breath table into window-level features
# =====================================================================

# Internal: ordinary least squares slope of y on x, in closed form.
# The original computed the equivalent quantity by fitting a full lm() object
# once per trial. For a two-to-four point regression that is roughly a hundred
# times the necessary work, and it returns an object that is discarded
# immediately.
ols_slope <- function(y, x = seq_along(y)) {
  ok <- is.finite(y) & is.finite(x)
  if (sum(ok) < 2L) return(NA_real_)
  y <- y[ok]; x <- x[ok]
  vx <- sum((x - mean(x))^2)
  if (vx == 0) return(NA_real_)
  sum((x - mean(x)) * (y - mean(y))) / vx
}

# Internal: root mean square of successive differences.
rmssd <- function(y) {
  y <- y[is.finite(y)]
  if (length(y) < 2L) return(NA_real_)
  sqrt(mean(diff(y)^2))
}

# Internal: coefficient of variation, guarded against a mean at or near zero.
cv <- function(y) {
  y <- y[is.finite(y)]
  if (length(y) < 2L) return(NA_real_)
  m <- mean(y)
  if (!is.finite(m) || abs(m) < .Machine$double.eps^0.5) return(NA_real_)
  stats::sd(y) / abs(m)
}

#' Variability metrics for a series of per-breath values
#'
#' @param y Numeric vector, one value per breath, in temporal order.
#' @param times Optional numeric vector of breath onset times in seconds. When
#'   supplied, `slope_per_s` is computed in addition to `slope_per_breath`.
#'
#' @return A named list of `n`, `mean`, `median`, `sd`, `cv`, `rmssd`,
#'   `slope_per_breath` and `slope_per_s`.
#'
#' @details
#' `slope_per_breath` regresses the values on ordinal breath position; this is
#' the quantity the original pipeline called `ibi_slope`. `slope_per_s`
#' regresses on elapsed time instead. The two answer different questions and
#' diverge exactly when they matter most: if breaths are getting longer, more
#' time passes per breath, so a constant per-breath drift is a decelerating
#' per-second drift. Report whichever matches your hypothesis and say which
#' one it is.
#' @export
resp_variability <- function(y, times = NULL) {
  y  <- as.numeric(y)
  ok <- is.finite(y)
  list(
    n                = sum(ok),
    mean             = if (any(ok)) mean(y[ok])             else NA_real_,
    median           = if (any(ok)) stats::median(y[ok])    else NA_real_,
    sd               = if (sum(ok) > 1L) stats::sd(y[ok])   else NA_real_,
    cv               = cv(y),
    rmssd            = rmssd(y),
    slope_per_breath = ols_slope(y),
    slope_per_s      = if (!is.null(times)) ols_slope(y, as.numeric(times)) else NA_real_
  )
}

#' Summarise a breath table into one row of features
#'
#' @param bt A breath table from [breath_table()], optionally already passed
#'   through [flag_breaths()].
#' @param use_flags If `TRUE` (default) and `bt` has a `keep` column, breaths
#'   flagged as implausible are excluded from the summary statistics. They
#'   still count towards `n_breaths_total`, so the rejection rate is
#'   recoverable.
#' @param prefix Optional string prepended to every column name, for binding
#'   summaries of several windows side by side.
#'
#' @return A one-row data frame.
#'
#' @section On mean rate:
#' Two defensible summaries of rate exist and they are not equal.
#' `rate_bpm_mean` averages the instantaneous rates of individual breaths;
#' `rate_from_mean_duration` is `60 / mean(duration)`, which is what the
#' original pipeline reported as `mean_bpm`. Because rate is the reciprocal of
#' duration, Jensen's inequality guarantees the first is the larger whenever
#' durations vary, and the gap grows with variability. Both are returned so
#' that the choice is explicit and results stay comparable with the original.
#' @export
summarise_breaths <- function(bt, use_flags = TRUE, prefix = "") {

  if (use_flags && "keep" %in% names(bt)) {
    n_total <- nrow(bt)
    b <- bt[bt$keep %in% TRUE, , drop = FALSE]
  } else {
    n_total <- nrow(bt)
    b <- bt
  }

  n <- nrow(b)

  dur <- resp_variability(b$duration,  times = b$t_start)
  amp <- resp_variability(b$amplitude, times = b$t_start)

  out <- data.frame(
    n_breaths                = n,
    n_breaths_total          = n_total,
    # Cycles with no detected peak carry a valid duration but nothing else, so
    # every peak-derived statistic below has a smaller denominator than
    # n_breaths. Reported rather than hidden.
    n_breaths_no_peak        = if (n > 0 && "has_peak" %in% names(b))
                                 sum(!b$has_peak) else 0L,
    pct_breaths_rejected     = if (n_total > 0) 100 * (n_total - n) / n_total else NA_real_,
    window_coverage_s        = if (n > 0) sum(b$duration, na.rm = TRUE) else 0,

    duration_mean            = dur$mean,
    duration_median          = dur$median,
    duration_sd              = dur$sd,
    duration_cv              = dur$cv,
    duration_rmssd           = dur$rmssd,
    duration_slope_per_breath = dur$slope_per_breath,
    duration_slope_per_s     = dur$slope_per_s,

    rate_bpm_mean            = if (n > 0) mean(b$rate_bpm, na.rm = TRUE) else NA_real_,
    rate_from_mean_duration  = if (is.finite(dur$mean) && dur$mean > 0) 60 / dur$mean else NA_real_,

    inhale_dur_mean          = if (n > 0) mean(b$inhale_dur, na.rm = TRUE) else NA_real_,
    exhale_dur_mean          = if (n > 0) mean(b$exhale_dur, na.rm = TRUE) else NA_real_,
    duty_cycle_mean          = if (n > 0) mean(b$duty_cycle, na.rm = TRUE) else NA_real_,
    ie_ratio_median          = if (n > 0) stats::median(b$ie_ratio, na.rm = TRUE) else NA_real_,

    amplitude_mean           = amp$mean,
    amplitude_median         = amp$median,
    amplitude_sd             = amp$sd,
    amplitude_cv             = amp$cv,
    amplitude_slope_per_breath = amp$slope_per_breath,

    rvt_mean                 = if (n > 0) mean(b$rvt, na.rm = TRUE) else NA_real_,
    flow_in_mean             = if (n > 0) mean(b$flow_in, na.rm = TRUE) else NA_real_,
    flow_out_mean            = if (n > 0) mean(b$flow_out, na.rm = TRUE) else NA_real_,
    baseline_drift           = if (n > 1L) ols_slope(b$baseline, b$t_start) else NA_real_,

    stringsAsFactors = FALSE
  )

  if (nzchar(prefix)) names(out) <- paste0(prefix, names(out))
  attr(out, "units") <- attr(bt, "units")
  out
}

#' @rdname summarise_breaths
#' @export
summarize_breaths <- summarise_breaths

#' Continuous respiratory rate and volume time series
#'
#' Converts the discrete breath table into signals sampled on a regular grid,
#' which is what you need to correlate respiration against another continuous
#' measure such as heart rate, pupil diameter or a BOLD time series.
#'
#' @param bt A breath table from [breath_table()].
#' @param fs_out Output sampling rate in Hz. Values well above about 1 Hz do
#'   not add information: the underlying measurements update once per breath.
#' @param from,to Time bounds in seconds. Default to the span of `bt`.
#' @param what Which per-breath columns to interpolate. Default rate, RVT and
#'   amplitude.
#' @param method `"constant"` (default) is a step function: each breath's
#'   value covers its own cycle, from `t_start` up to `t_end`. This makes no
#'   claim the data cannot support. `"linear"` interpolates between cycle
#'   midpoints, giving a smoother series at the cost of inventing intermediate
#'   values.
#'
#' @details
#' Outside the span of the breath table the first and last values are carried
#' forward, so the series never has leading or trailing gaps. Where breaths
#' have been removed from the table, the preceding breath's value carries
#' across the hole rather than the series going `NA`; filter the output on
#' time if that matters for your analysis.
#'
#' @return A data frame with a `time` column and one column per entry in
#'   `what`.
#' @export
resp_rate_series <- function(bt, fs_out = 4, from = NULL, to = NULL,
                             what = c("rate_bpm", "rvt", "amplitude"),
                             method = c("constant", "linear")) {

  method <- match.arg(method)
  what   <- intersect(what, names(bt))
  if (!length(what))
    stop("None of the requested columns are present in the breath table.",
         call. = FALSE)
  if (!nrow(bt))
    stop("Breath table is empty.", call. = FALSE)

  if (is.null(from)) from <- min(bt$t_start, na.rm = TRUE)
  if (is.null(to))   to   <- max(bt$t_end,   na.rm = TRUE)

  grid <- seq(from, to, by = 1 / fs_out)
  out  <- data.frame(time = grid)

  b <- bt[order(bt$t_start), , drop = FALSE]

  if (method == "constant") {
    # Step boundaries are the cycle starts, so a grid point takes the value of
    # the breath it actually falls inside. Anchoring on cycle midpoints and
    # stepping there instead would shift every value half a breath late.
    slot <- pmax(1L, findInterval(grid, b$t_start))
    for (col in what) out[[col]] <- b[[col]][slot]
    return(out)
  }

  anchor <- (b$t_start + b$t_end) / 2
  for (col in what) {
    y  <- b[[col]]
    ok <- is.finite(anchor) & is.finite(y)
    if (sum(ok) < 2L) {
      out[[col]] <- rep(NA_real_, length(grid))
      next
    }
    out[[col]] <- stats::approx(anchor[ok], y[ok], xout = grid,
                                method = "linear", rule = 2)$y
  }
  out
}
