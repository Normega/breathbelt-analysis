# trials.R
#
# Trial-record cleaning. Structural only: no outcome quantity is computed.
#
# WHY THIS EXISTS
#
# Seven of the eighteen pilot participants carry duplicate trial rows, in two
# distinct forms. Both were found by a guard that refuses to align when the
# trigger count and the record count disagree.
#
#   FINAL-TRIAL DUPLICATE  (3997, 14425, 16753, 17755)
#     The last trial is written twice. The copy carries trial_number + 1 and is
#     otherwise identical: same condition, breath_period_ms, response, correct,
#     confidence, arousal, response_rt_ms, trial_onset_ms and trial_end_ms.
#     Because trial_number differs, a (phase, trial_number) key does NOT catch it.
#
#   BATCH DUPLICATE  (13738, 16807, 17446)
#     An entire phase-3 insert is repeated. Every row is byte-identical except
#     created_at, which differs by about 4 ms across the whole batch, so a single
#     insert call was retried. 17446 is larger again, 78 rows for 43 trials.
#
# THE KEY IS trial_onset_ms. Two genuine trials cannot begin in the same
# millisecond, and trials are participant-initiated so they are seconds apart in
# practice. trial_number is unusable because the final-trial duplicate increments
# it, and created_at is unusable because the batch duplicate differs on it.
#
# Both patterns duplicate CONTENT, so no information is lost by dropping the
# later copy. The alternative the old script used, truncating to
# min(n_triggers, n_records), would silently mis-pair every trial after the
# discrepancy.
#
# Sourced by scripts/; installs nothing.


# Remove duplicate trial records. Returns the cleaned table with an attribute
# recording what was dropped.
dedupe_trials <- function(trials, pid = NA_character_, verbose = TRUE) {
  if (!"trial_onset_ms" %in% names(trials)) {
    stop("dedupe_trials needs a trial_onset_ms column.")
  }
  ord  <- order(trials$trial_onset_ms)
  t    <- trials[ord, , drop = FALSE]
  dup  <- duplicated(t$trial_onset_ms)
  n_in <- nrow(t)

  if (any(dup)) {
    # Only drop rows that are genuinely redundant. If two rows share an onset but
    # disagree on trial CONTENT, that is not a duplicate and must not be silently
    # discarded: it means something unmodelled happened.
    content <- intersect(c("phase", "condition", "breath_period_ms", "response",
                           "correct", "confidence", "arousal", "response_rt_ms",
                           "trial_end_ms"), names(t))
    key   <- do.call(paste, c(t[content], sep = "\r"))
    for (on in unique(t$trial_onset_ms[dup])) {
      idx <- which(t$trial_onset_ms == on)
      if (length(unique(key[idx])) > 1L) {
        stop("Participant ", pid, ": ", length(idx), " trial records share ",
             "trial_onset_ms = ", on, " but DISAGREE on trial content. This is ",
             "not a simple duplicate and must be resolved by hand.")
      }
    }
    if (verbose) {
      message("  [", pid, "] dropped ", sum(dup), " duplicate trial record(s) of ",
              n_in, "; ", n_in - sum(dup), " remain")
    }
  }
  out <- t[!dup, , drop = FALSE]
  attr(out, "n_dropped") <- sum(dup)
  attr(out, "n_input")   <- n_in
  rownames(out) <- NULL
  out
}
