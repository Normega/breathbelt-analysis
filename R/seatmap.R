# seatmap.R
#
# Resolve each participant to a seat, an ACQ file, and a trigger rig.
#
# WHY THIS EXISTS
#
# One .acq file holds BOTH seats of a testing rig. Three facts make naive
# lookup wrong:
#
#   1. The previous lookup, `pattern = paste0(".", PID, "\\.acq$")`, anchors the
#      ID at the END of the filename. It therefore matches right-seat
#      participants only, and fails outright for 14425, 17734, and 17896.
#
#   2. Two files contain TWO enrolled participants each (L17734.R14701 and
#      L17896.R13738). Both respiration channels carry real breathing, so
#      "select the active channel by variance" is ambiguous there and will pick
#      the wrong person about half the time. Seat must decide, not variance.
#
#   3. `belt_sessions.trigger_device` selects a RIG, meaning a parallel-port
#      address and an encoding, which normally but not always tracks the seat.
#      For 14425 the filename says left while trigger_device says Biopac_Right.
#
# Per Norm (2026-07-31) the trigger codes are authoritative and the two rigs use
# completely orthogonal code sets. So the rig is derived from the recorded codes
# rather than trusted from the dropdown, and all three sources are reconciled.
#
# Sourced by scripts/; declares no packages and installs nothing.


# ── Rig definitions ───────────────────────────────────────────────────────────
#
# From radlab BreathBelt/constants.js (commit 98b2dca):
#   { value: 'Biopac_Left',  address: 0xDFF8, shift: 16 }   code on the high nibble
#   { value: 'Biopac_Right', address: 0xD030, shift: 1  }   code as-is
#
# Event codes are 1..13 (see CONTEXT.md). Code 11 is defined but never emitted.
# The two encodings do not overlap, which is what lets two simultaneously
# running participants share one recording and still be separated.

# VERIFIED against the AcqKnowledge template and a real recording (2026-07-31).
#
# The trigger reaches the MP160 as EIGHT SEPARATE PHYSICAL LINES, "Digital (STP
# Input 0..7)", which AcqKnowledge also sums into a derived "Experiment Triggers"
# channel. The two rigs therefore do not merely use non-overlapping NUMBERS, they
# use non-overlapping WIRES:
#
#   Biopac_Right  shift 1    codes 1..13 land in the LOW  nibble, bits 0-3
#   Biopac_Left   shift 16   codes 1..13 land in the HIGH nibble, bits 4-7
#
# Every event code fits in 4 bits (max 13), which is what makes the split work.
# Two participants running simultaneously can share one recording and never
# collide, because neither can touch the other's wires.
#
# CONSEQUENCE FOR DECODING: an idle nibble floats HIGH. On a right-rig recording
# the untouched high nibble reads 0xF0, so "Experiment Triggers" idles at 240 and
# a trial start (code 10) appears as 250, not 10. Confirmed on 14542: the channel
# takes values 240 plus 0..13, and the per-line counts match codes 10 and 12
# exactly (STP3 highest, since bit 3 is set by both).
#
# So the code is a NIBBLE MASK, never value/shift and never value minus a global
# idle. Subtracting an idle would also break on the dual-occupancy files, where
# BOTH nibbles carry live codes at once and there is no single idle level.

# Channel-to-seat mapping, VERIFIED empirically 2026-07-31 by checking which
# respiration channel is active in files with exactly one seat occupied:
#
#   L0000.R3997   left empty, right occupied  -> Breath 1 active (sd 1.04 vs 0.0004)
#   L14425.R0000  left occupied, right empty  -> Breath 2 active (sd 2.73 vs 0.0004)
#   L17734.R14701 both occupied               -> both active
#
# Three orders of magnitude separate an occupied channel from a vacant one, so
# occupancy is unambiguous. Note the ordering is NOT the intuitive one: channel 1
# is the RIGHT seat.
SEAT_CHANNELS <- list(
  RIGHT = c(breath = "Breath 1", heart = "Heart 1"),
  LEFT  = c(breath = "Breath 2", heart = "Heart 2")
)
TRIGGER_CHANNEL <- "Experiment Triggers"

RIG_NIBBLE  <- c(Biopac_Right = "low", Biopac_Left = "high")
RIG_SHIFT   <- c(Biopac_Right = 1L,    Biopac_Left = 16L)
EVENT_CODES <- 1:13
# Code 11 (condition onset) is never emitted during a session. It appears ONLY in
# sendTestCascade, the setup verification sweep that fires all 13 codes before
# session start, and which drop_pre_session() removes.
SESSION_CODES <- c(1:10, 12:13)


# ── ACQ filename parsing ──────────────────────────────────────────────────────

# Convention is `L<leftID>.R<rightID>.acq` with a DOT separator, not the
# underscore claimed by a stale comment in the old prep script. `0000` marks an
# empty seat.
#
# One file is malformed: `L16549.14542.acq` is missing the `R` prefix on the
# right-seat ID, so a strict L\d+\.R\d+ pattern breaks on it. The prefix is
# treated as optional on the second field and the position is what carries the
# meaning.
parse_acq_filename <- function(path) {
  base  <- sub("\\.acq$", "", basename(path), ignore.case = TRUE)
  parts <- strsplit(base, ".", fixed = TRUE)[[1]]
  if (length(parts) != 2L) {
    stop("Cannot parse ACQ filename '", basename(path), "': expected two ",
         "dot-separated seat fields, got ", length(parts), ".")
  }
  strip <- function(s) sub("^[LR]", "", s, ignore.case = TRUE)
  left  <- strip(parts[1]); right <- strip(parts[2])
  if (!grepl("^\\d+$", left) || !grepl("^\\d+$", right)) {
    stop("Cannot parse ACQ filename '", basename(path), "': seat fields are ",
         "not numeric after stripping L/R.")
  }
  data.frame(
    file       = path,
    left_id    = if (left  == "0000") NA_character_ else left,
    right_id   = if (right == "0000") NA_character_ else right,
    stringsAsFactors = FALSE
  )
}

# Long table of one row per (occupied seat, file).
build_seat_map <- function(acq_dir) {
  files <- list.files(acq_dir, pattern = "\\.acq$", full.names = TRUE,
                      ignore.case = TRUE)
  if (!length(files)) stop("No .acq files found in ", acq_dir)
  parsed <- do.call(rbind, lapply(files, parse_acq_filename))

  seats <- rbind(
    data.frame(participant_id = parsed$left_id,  seat = "LEFT",
               acq_file = parsed$file, stringsAsFactors = FALSE),
    data.frame(participant_id = parsed$right_id, seat = "RIGHT",
               acq_file = parsed$file, stringsAsFactors = FALSE)
  )
  seats <- seats[!is.na(seats$participant_id), ]
  seats <- seats[order(seats$participant_id), ]

  # Duplicates are reported but do not stop map construction: an ID appearing in
  # two files is only a problem if that participant is actually being processed.
  # 9967 occupies a seat in two different recordings and is not in the pilot, so
  # failing here would block every other participant for no reason. The hard
  # failure lives in resolve_participant(), at the point of use.
  dup <- unique(seats$participant_id[duplicated(seats$participant_id)])
  if (length(dup)) {
    warning("Participant(s) occupy a seat in more than one ACQ file: ",
            paste(dup, collapse = ", "),
            ". Harmless unless one of them is being processed.", call. = FALSE)
  }
  rownames(seats) <- NULL
  attr(seats, "duplicated_ids") <- dup
  seats
}

# Resolve one participant, or fail loudly. Never returns an ambiguous answer.
resolve_participant <- function(pid, seat_map) {
  pid <- as.character(pid)
  hit <- seat_map[seat_map$participant_id == pid, ]
  if (nrow(hit) == 0L) {
    stop("Participant ", pid, ": no ACQ file. Present in the accelerometer data ",
         "but absent from every ACQ filename, so the stretch belt recording is ",
         "missing. This participant fails the completeness criterion.")
  }
  if (nrow(hit) > 1L) {
    stop("Participant ", pid, ": occupies a seat in ", nrow(hit), " ACQ files (",
         paste(basename(hit$acq_file), collapse = ", "), ") as seat(s) ",
         paste(hit$seat, collapse = "/"), ". Cannot decide which recording is ",
         "this session. Resolve manually before processing.")
  }
  as.list(hit)
}


# ── Rig identification from the recorded codes ────────────────────────────────

# Split a raw trigger channel into its two nibbles.
.nibbles <- function(trig) {
  v <- as.integer(round(trig[is.finite(trig)]))
  list(low  = bitwAnd(v, 15L),
       high = bitwShiftR(bitwAnd(v, 240L), 4L))
}

# Infer which rig(s) actually wrote to this recording, by asking which nibble
# CARRIES INFORMATION. An idle nibble is constant (all-high or all-low); a live
# one varies and takes values that are valid event codes.
#
# Returns a character vector, possibly of length 2 for a dual-occupancy file.
rigs_present <- function(trig) {
  nb  <- .nibbles(trig)
  out <- character(0)
  for (rig in names(RIG_NIBBLE)) {
    v <- nb[[RIG_NIBBLE[[rig]]]]
    u <- unique(v)
    u <- u[u != 0L & u != 15L]          # 0 = idle low, 15 = idle floating high
    if (length(u) >= 3L && mean(u %in% EVENT_CODES) >= 0.9) out <- c(out, rig)
  }
  out
}

# Back-compatible single answer: NA when the evidence does not pick exactly one.
rig_from_trigger_codes <- function(trig) {
  r <- rigs_present(trig)
  if (length(r) == 1L) r else NA_character_
}


# ── Reconciliation ────────────────────────────────────────────────────────────

# Cross-check the three sources of truth for one participant. Returns a record
# with the resolved seat and rig plus an explicit agreement flag.
#
# The seat and the rig are resolved INDEPENDENTLY and are allowed to disagree.
# A participant can sit in the left chair while the right computer runs the
# session: the seat determines which respiration channel carries their breathing,
# the rig determines how their event codes are encoded. Collapsing the two is the
# error that would silently mis-channel 14425.
reconcile_session <- function(pid, seat_map, trigger_device = NA_character_,
                              observed_codes = NULL,
                              idle = TRIGGER_IDLE_DEFAULT) {
  res <- resolve_participant(pid, seat_map)
  rig_observed <- if (!is.null(observed_codes)) {
    rig_from_trigger_codes(observed_codes, idle = idle)
  } else NA_character_

  rig <- if (!is.na(rig_observed)) rig_observed else trigger_device
  seat_implied_by_rig <- c(Biopac_Left = "LEFT", Biopac_Right = "RIGHT")[rig]

  notes <- character(0)
  if (!is.na(rig_observed) && !is.na(trigger_device) &&
      rig_observed != trigger_device) {
    notes <- c(notes, sprintf(
      "trigger_device says %s but the recorded codes say %s; codes win",
      trigger_device, rig_observed))
  }
  if (!is.na(rig) && !is.na(seat_implied_by_rig) &&
      seat_implied_by_rig != res$seat) {
    notes <- c(notes, sprintf(
      "seat is %s (from ACQ filename) but the rig is %s; participant sat in one seat while the other computer ran the session",
      res$seat, rig))
  }
  if (is.na(rig_observed) && !is.null(observed_codes)) {
    notes <- c(notes, "trigger codes matched neither rig cleanly")
  }

  list(
    participant_id = as.character(pid),
    seat           = res$seat,          # decides the respiration channel
    rig            = rig,               # decides the code encoding
    shift          = if (!is.na(rig)) RIG_SHIFT[[rig]] else NA_integer_,
    acq_file       = res$acq_file,
    agrees         = length(notes) == 0L,
    notes          = if (length(notes)) paste(notes, collapse = "; ") else NA_character_
  )
}

# Decode a raw trigger channel into an event table for ONE rig, by masking that
# rig's nibble. The other rig's lines are ignored entirely, whether they are idle
# or carrying another participant's session.
#
# Returns the leading edge of each code plateau, so a held pulse counts once.
decode_triggers <- function(trig, hz, rig) {
  if (!rig %in% names(RIG_NIBBLE)) {
    stop("Unknown rig '", rig, "'. Expected one of: ",
         paste(names(RIG_NIBBLE), collapse = ", "))
  }
  v    <- as.integer(round(trig))
  code <- if (RIG_NIBBLE[[rig]] == "low") bitwAnd(v, 15L)
          else bitwShiftR(bitwAnd(v, 240L), 4L)

  # 0 and 15 are the two idle states of a nibble (driven low, or floating high).
  active <- code != 0L & code != 15L & !is.na(code)
  if (!any(active)) {
    stop("No event codes on the ", RIG_NIBBLE[[rig]], " nibble for rig ", rig,
         ". Either the wrong rig was supplied or no triggers reached the MP160.")
  }
  onset <- which(active & c(TRUE, !active[-length(active)]))
  data.frame(
    sample_idx = onset,
    time_sec   = (onset - 1L) / hz,
    code       = code[onset],
    stringsAsFactors = FALSE
  )
}


# Drop everything up to and including the setup verification cascade.
#
# SUBTLE: take the LAST session-start code, not the first.
#
# `sendTestCascade` fires ALL THIRTEEN codes before the session begins, so the
# cascade contains its own code 1. Anchoring on the first code 1 therefore keeps
# the entire cascade, including its code 10, which shows up as one extra
# trial-start trigger. That is exactly the off-by-one that appeared on 14542:
# 35 trial starts against 34 trial records.
#
# The cascade always precedes the real session, so the last code 1 is the real
# session start. A session with no cascade has a single code 1 and is unaffected.
drop_pre_session <- function(events, session_start_code = 1L) {
  hits <- which(events$code == session_start_code)
  if (!length(hits)) {
    stop("No session-start code (", session_start_code, ") found. Cannot ",
         "distinguish the setup verification cascade from real trials.")
  }
  if (length(hits) > 2L) {
    warning("Found ", length(hits), " session-start codes; expected 1 (no ",
            "cascade) or 2 (cascade plus session). Using the last. The session ",
            "may have been restarted.", call. = FALSE)
  }
  events[seq(hits[length(hits)], nrow(events)), , drop = FALSE]
}
