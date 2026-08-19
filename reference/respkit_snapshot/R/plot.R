# =====================================================================
#  plot.R — diagnostic plots using base graphics
#
#  Base graphics rather than ggplot2, so that quality-control plotting has no
#  dependency beyond what ships with R. These are diagnostics meant to be
#  skimmed a few hundred at a time, not figures for publication.
# =====================================================================

#' Plot a recording, optionally with detected extrema
#'
#' @param x A `resp_recording` or numeric vector.
#' @param fs Sampling rate; required for bare numeric input.
#' @param detection Optional output of [resp_detect()].
#' @param from,to Optional time window in seconds on the recording clock.
#'   Plotting an hour of data at 25 Hz produces an unreadable smear; a window
#'   of one to two minutes is usually what you want.
#' @param epochs Optional window table from [resp_epochs()], drawn as shaded
#'   bands.
#' @param main Plot title.
#' @param col,lwd,type Trace colour, line width and plot type.
#' @param xlab,ylab Axis labels. `NULL` uses sensible defaults.
#' @param ... Further arguments passed to [plot()]. The trace's own graphical
#'   parameters are exposed as named arguments above rather than left to `...`,
#'   because [plot()] is already being called with them and passing them again
#'   through `...` is a "matched by multiple actual arguments" error.
#' @export
plot_resp <- function(x, fs = NULL, detection = NULL, from = NULL, to = NULL,
                      epochs = NULL, main = NULL, col = "#2c7be5", lwd = 1,
                      type = "l", xlab = "Time (s)", ylab = NULL, ...) {

  rec <- as_resp_recording(x, fs = fs)
  if (!is.null(from) || !is.null(to)) rec <- resp_slice(rec, from, to)

  t <- resp_time(rec)
  s <- rec$signal

  if (is.null(main))
    main <- sprintf("%s  (%.6g Hz, %.1f s)",
                    if (is.na(rec$id)) "recording" else rec$id,
                    rec$fs, resp_duration(rec))
  if (is.null(ylab)) ylab <- paste0("Signal (", rec$units, ")")

  if (!is.null(epochs) && !all(c("start", "end") %in% names(epochs)))
    stop("`epochs` must have `start` and `end` columns. Build it with ",
         "resp_epochs().", call. = FALSE)

  plot(t, s, type = type, col = col, lwd = lwd,
       xlab = xlab, ylab = ylab, main = main, ...)

  if (!is.null(epochs)) {
    vis <- epochs[epochs$end >= min(t) & epochs$start <= max(t), , drop = FALSE]
    if (nrow(vis)) {
      yr <- range(s, na.rm = TRUE)
      rect(vis$start, yr[1], vis$end, yr[2],
           col = grDevices::adjustcolor("grey60", alpha.f = 0.15), border = NA)
      lines(t, s, col = col, lwd = lwd)
    }
  }

  if (!is.null(detection)) {
    lo <- min(t); hi <- max(t)
    pk <- detection$peak_times
    tr <- detection$trough_times
    pk <- pk[pk >= lo & pk <= hi]
    tr <- tr[tr >= lo & tr <= hi]
    if (length(pk))
      points(pk, stats::approx(t, s, xout = pk, rule = 2)$y,
             col = "#e63946", pch = 19, cex = 0.8)
    if (length(tr))
      points(tr, stats::approx(t, s, xout = tr, rule = 2)$y,
             col = "#2dc653", pch = 17, cex = 0.8)
  }

  invisible(NULL)
}

#' Plot per-breath features over time
#'
#' Four stacked panels: duration, amplitude, duty cycle and end-expiratory
#' baseline. Flagged breaths, if [flag_breaths()] has been run, are drawn
#' hollow so that a rejection pattern is visible at a glance.
#'
#' @param bt A breath table from [breath_table()].
#' @param main Overall title.
#' @export
plot_breaths <- function(bt, main = NULL) {
  if (!nrow(bt)) {
    message("Breath table is empty; nothing to plot.")
    return(invisible(NULL))
  }

  keep <- if ("keep" %in% names(bt)) bt$keep %in% TRUE else rep(TRUE, nrow(bt))
  pch  <- ifelse(keep, 19, 1)
  col  <- ifelse(keep, "#2c7be5", "#e63946")

  op <- graphics::par(mfrow = c(4, 1), mar = c(2.5, 4.5, 1.5, 1), oma = c(2, 0, 2, 0))
  on.exit(graphics::par(op), add = TRUE)

  units <- attr(bt, "units")
  if (is.null(units)) units <- "arbitrary"

  panels <- list(
    list(y = bt$duration,   lab = "Duration (s)"),
    list(y = bt$amplitude,  lab = paste0("Amplitude (", units, ")")),
    list(y = bt$duty_cycle, lab = "Duty cycle Ti/Ttot"),
    list(y = bt$baseline,   lab = paste0("Baseline (", units, ")"))
  )

  for (p in panels) {
    # A panel whose column is entirely NA gives plot() no finite ylim and it
    # errors. Draw the empty frame and say so instead: an all-NA column is
    # informative (no cycle had a peak, say), not a reason to abort the figure.
    if (!any(is.finite(p$y)) || !any(is.finite(bt$t_start))) {
      plot(0, 0, type = "n", xlab = "", ylab = p$lab, xaxt = "n", yaxt = "n")
      graphics::text(0, 0, "no finite values", col = "grey50", cex = 0.9)
      next
    }
    plot(bt$t_start, p$y, type = "b", pch = pch, col = col, cex = 0.7,
         xlab = "", ylab = p$lab, lty = 3)
    if (identical(p$lab, "Duty cycle Ti/Ttot"))
      graphics::abline(h = 0.5, col = "grey60", lty = 2)
  }
  graphics::mtext("Time (s)", side = 1, line = 2.2)
  if (!is.null(main)) graphics::mtext(main, side = 3, outer = TRUE, font = 2)

  invisible(NULL)
}
