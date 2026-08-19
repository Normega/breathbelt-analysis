# =====================================================================
#  epoch.R — assigning breaths to task windows
#
#  A NOTE ON PARTIAL BREATHS AT WINDOW EDGES
#  -----------------------------------------
#  A respiratory cycle takes several seconds, so a trial window of ten or
#  twenty seconds will almost always begin and end mid-breath. Something has
#  to be decided about those partial cycles, and the decision changes the
#  numbers.
#
#  The pipeline this replaces resolved it by inserting a synthetic trough at
#  the window boundary whenever a window contained fewer troughs than the
#  paradigm expected, then treating the interval from that synthetic trough
#  as a measured breath duration. It is not one: its length is set by where
#  the experimenter placed the window, not by when the participant breathed.
#  Because the insertion was triggered by a shortfall against the expected
#  count, it fired precisely on the trials where detection was worst, and
#  filled the gap with a number that looks like data.
#
#  respkit does not do this. It offers explicit assignment rules, reports how
#  many cycles were partial, and reports what fraction of the window is
#  actually covered by complete cycles, so an analysis can decide for itself
#  whether a window has enough evidence to be used.
# =====================================================================

#' Build a table of analysis windows
#'
#' @param onset Numeric vector of window start times, in seconds on the
#'   recording clock.
#' @param offset Numeric vector of window end times. Alternatively give
#'   `duration`.
#' @param duration Window length in seconds, recycled if scalar. Used only
#'   when `offset` is `NULL`.
#' @param lag Transduction or hardware latency in seconds, added to both
#'   bounds. A belt reports chest movement with a small delay relative to the
#'   event that triggered it, so shifting the *window* rather than the
#'   *signal* keeps the signal's own clock intact.
#' @param label Optional labels, one per window.
#' @param ... Further columns to carry alongside each window (trial number,
#'   condition, session).
#'
#' @return A data frame with `epoch`, `label`, `start`, `end`, plus any
#'   extra columns.
#' @export
resp_epochs <- function(onset, offset = NULL, duration = NULL, lag = 0,
                        label = NULL, ...) {

  onset <- as.numeric(onset)
  n <- length(onset)
  if (n == 0L) stop("`onset` is empty.", call. = FALSE)

  if (is.null(offset)) {
    if (is.null(duration))
      stop("Supply either `offset` or `duration`.", call. = FALSE)
    offset <- onset + rep_len(as.numeric(duration), n)
  } else {
    offset <- as.numeric(offset)
    if (length(offset) != n)
      stop("`offset` has length ", length(offset), " but `onset` has length ",
           n, ".", call. = FALSE)
  }

  bad <- which(offset <= onset)
  if (length(bad))
    stop(length(bad), " window(s) end at or before they start (first at index ",
         bad[1], ").", call. = FALSE)

  out <- data.frame(
    epoch = seq_len(n),
    label = if (is.null(label)) as.character(seq_len(n)) else
      as.character(rep_len(label, n)),
    start = onset  + lag,
    end   = offset + lag,
    stringsAsFactors = FALSE
  )

  extra <- list(...)
  for (nm in names(extra)) out[[nm]] <- rep_len(extra[[nm]], n)

  attr(out, "lag") <- lag
  out
}

#' Assign breaths to epochs
#'
#' @param bt A breath table from [breath_table()].
#' @param epochs A window table from [resp_epochs()].
#' @param rule How a breath is assigned to a window.
#'   \describe{
#'     \item{`"start"`}{(default) the breath's opening trough falls inside the
#'       window. Every breath belongs to at most one window, so counts across
#'       windows sum to the total without double counting.}
#'     \item{`"contained"`}{the whole cycle lies inside the window. The
#'       strictest rule and the right one when a duration must be wholly
#'       attributable to the window's condition.}
#'     \item{`"overlap"`}{any temporal overlap. A breath can belong to two
#'       adjacent windows; use when windows are far apart and you would rather
#'       keep edge breaths than lose them.}
#'   }
#' @param pad_s Seconds of tolerance added to each side of every window before
#'   the rule is applied. A small pad recovers breaths whose trough was
#'   detected a fraction of a second outside the nominal boundary. Padding
#'   more than about a second starts admitting breaths from the neighbouring
#'   window.
#'
#' @return `bt` with `epoch` and `epoch_label` columns added.
#'
#'   Under `"start"` and `"contained"` the table keeps its original number of
#'   rows and breaths matching no window get `NA`.
#'
#'   Under `"overlap"` the result is one row per (breath, window) pair
#'   instead: a breath spanning two windows appears twice, and **a breath
#'   matching no window does not appear at all**. The row count therefore does
#'   not match `bt`, and row positions do not correspond — join on `breath`
#'   rather than by position, and do not compute a rejection rate from
#'   `nrow()`.
#'
#' @section Breath tables that are not in their original order:
#' Rows are located by position, never by the value of the `breath` column.
#' `breath` numbers cycles within one recording, so it stops matching row
#' position as soon as a table is filtered, sorted, or row-bound across
#' participants -- all of which are ordinary things to do before epoching.
#' @export
epoch_breaths <- function(bt, epochs,
                          rule  = c("start", "contained", "overlap"),
                          pad_s = 0) {

  rule       <- match.arg(rule)
  units_attr <- attr(bt, "units")

  if (!all(c("t_start", "t_end") %in% names(bt)))
    stop("`bt` must be a breath table with `t_start` and `t_end` columns.",
         call. = FALSE)
  if (!all(c("epoch", "label", "start", "end") %in% names(epochs)))
    stop("`epochs` must have `epoch`, `label`, `start` and `end` columns. ",
         "Build it with resp_epochs().", call. = FALSE)
  if (anyDuplicated(epochs$epoch))
    stop("`epochs$epoch` must be unique; it is the key used to match features ",
         "back to windows.", call. = FALSE)

  if (!nrow(bt)) {
    bt$epoch       <- integer(0)
    bt$epoch_label <- character(0)
    attr(bt, "units") <- units_attr
    return(bt)
  }

  lo <- epochs$start - pad_s
  hi <- epochs$end   + pad_s

  hits <- lapply(seq_len(nrow(epochs)), function(k) {
    hit <- switch(
      rule,
      start     = bt$t_start >= lo[k] & bt$t_start <= hi[k],
      contained = bt$t_start >= lo[k] & bt$t_end   <= hi[k],
      overlap   = bt$t_end   >= lo[k] & bt$t_start <= hi[k]
    )
    which(hit %in% TRUE)
  })

  if (rule == "overlap") {
    use <- which(lengths(hits) > 0L)
    if (!length(use)) {
      out <- bt[0, , drop = FALSE]
      out$epoch       <- integer(0)
      out$epoch_label <- character(0)
      attr(out, "units") <- units_attr
      return(out)
    }
    parts <- lapply(use, function(k) {
      p <- bt[hits[[k]], , drop = FALSE]
      p$epoch       <- epochs$epoch[k]
      p$epoch_label <- epochs$label[k]
      p
    })
    out <- do.call(rbind, parts)
    rownames(out) <- NULL
    attr(out, "units") <- units_attr
    return(out)
  }

  out <- bt
  out$epoch       <- NA_integer_
  out$epoch_label <- NA_character_

  n_multi <- 0L
  for (k in seq_along(hits)) {
    idx <- hits[[k]]
    if (!length(idx)) next
    taken   <- !is.na(out$epoch[idx])
    n_multi <- n_multi + sum(taken)
    idx     <- idx[!taken]
    if (!length(idx)) next
    out$epoch[idx]       <- epochs$epoch[k]
    out$epoch_label[idx] <- epochs$label[k]
  }

  if (n_multi > 0L)
    warning(n_multi, " breath(s) matched more than one window under rule \"",
            rule, "\" and were kept in the first match only. This means the ",
            "windows overlap, or `pad_s` is larger than the gap between them. ",
            "Use rule = \"overlap\" if a breath should count towards several ",
            "windows.", call. = FALSE)

  attr(out, "units") <- units_attr
  out
}

#' Per-epoch respiratory features
#'
#' @param bt A breath table from [breath_table()], optionally already flagged
#'   by [flag_breaths()].
#' @param epochs A window table from [resp_epochs()].
#' @param rule,pad_s Passed to [epoch_breaths()].
#' @param use_flags Passed to [summarise_breaths()].
#' @param min_breaths Windows yielding fewer than this many usable breaths get
#'   a row of `NA` features rather than a summary computed from too little
#'   data. The row is still returned, so every window appears in the output
#'   exactly once and missingness is explicit.
#'
#' @return One row per window: the window's own columns, then
#'   `n_breaths_partial` and `coverage_frac`, then everything
#'   [summarise_breaths()] produces.
#'
#' @section coverage_frac:
#' The proportion of the window's duration actually spanned by the breaths
#' assigned to it, with each cycle clipped to the window bounds. A window of
#' 16 s holding three complete 4 s breaths and one partial cycle at the edge
#' has a coverage of 0.75 plus whatever part of the partial cycle falls
#' inside. This is the honest replacement for padding the count out to the
#' expected number of breaths, and it is worth screening on: a window at 0.4
#' coverage is not really measured, whatever its feature values say.
#'
#' Clipping matters under the default `rule = "start"`, where a breath is
#' assigned by its opening trough alone and may extend well past the window's
#' end. Crediting such a cycle's whole duration would report a window as fully
#' covered when almost all of that cycle lies outside it.
#' @export
epoch_features <- function(bt, epochs,
                           rule        = c("start", "contained", "overlap"),
                           pad_s       = 0,
                           use_flags   = TRUE,
                           min_breaths = 1L) {

  rule <- match.arg(rule)
  assigned <- epoch_breaths(bt, epochs, rule = rule, pad_s = pad_s)

  rows <- lapply(seq_len(nrow(epochs)), function(k) {
    ep  <- epochs[k, , drop = FALSE]
    sub <- assigned[assigned$epoch %in% ep$epoch, , drop = FALSE]
    attr(sub, "units") <- attr(bt, "units")

    win_len <- ep$end - ep$start
    n_partial <- if (nrow(bt))
      sum(bt$t_end >= ep$start & bt$t_start <= ep$end &
            !(bt$t_start >= ep$start & bt$t_end <= ep$end), na.rm = TRUE)
    else 0L

    usable <- if (use_flags && "keep" %in% names(sub))
      sub[sub$keep %in% TRUE, , drop = FALSE] else sub

    # The fraction of the window actually spanned, clipping each cycle to the
    # window bounds. Summing whole durations instead credits a window with
    # time that lies outside it: under the default "start" rule a breath is
    # assigned by its opening trough alone, so a 5 s cycle beginning 0.1 s
    # before the window closes contributed its entire 5 s. Measured over
    # 10 s windows on 4 s breaths that overstated coverage by 0.095 on
    # average, and reported a full 1.0 for 98 of 200 random offsets -- which
    # defeats the point of a metric whose whole job is to say when a window is
    # not really measured.
    spanned  <- if (nrow(usable))
      pmax(0, pmin(usable$t_end, ep$end) - pmax(usable$t_start, ep$start)) else numeric(0)
    coverage <- if (length(spanned) && win_len > 0)
      min(1, sum(spanned, na.rm = TRUE) / win_len) else 0

    feat <- if (nrow(usable) >= min_breaths) {
      summarise_breaths(sub, use_flags = use_flags)
    } else {
      f <- summarise_breaths(empty_breath_table(), use_flags = FALSE)
      f$n_breaths       <- nrow(usable)
      f$n_breaths_total <- nrow(sub)
      f
    }

    # window_coverage_s is recomputed here from the CLIPPED spans. Left as
    # summarise_breaths() computes it -- the raw sum of cycle durations -- it
    # would sit one column away from coverage_frac contradicting it, and
    # anyone deriving coverage as window_coverage_s / (end - start) would
    # reproduce exactly the overstatement coverage_frac was fixed to remove.
    if ("window_coverage_s" %in% names(feat))
      feat$window_coverage_s <- sum(spanned, na.rm = TRUE)

    row <- cbind(ep,
                 data.frame(n_breaths_partial = as.integer(n_partial),
                            coverage_frac     = coverage,
                            stringsAsFactors  = FALSE),
                 feat)

    # A window column carried through resp_epochs(...) can collide with a
    # computed feature name. cbind() would keep both, and `$` then silently
    # returns the user's value instead of the measurement.
    dup <- names(row)[duplicated(names(row))]
    if (length(dup))
      stop("Window column(s) ", paste(sQuote(dup), collapse = ", "),
           " collide with computed feature names. Rename them in resp_epochs().",
           call. = FALSE)
    row
  })

  out <- do.call(rbind, rows)
  # rbind() of an empty list is NULL, but the contract is one row per window --
  # zero windows must give zero rows, not a missing object.
  if (is.null(out)) {
    out <- cbind(epochs[0, , drop = FALSE],
                 data.frame(n_breaths_partial = integer(0),
                            coverage_frac     = numeric(0)),
                 summarise_breaths(empty_breath_table(), use_flags = FALSE)[0, ])
  }
  rownames(out) <- NULL
  out
}
