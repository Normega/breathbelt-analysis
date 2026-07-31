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

RIG_SHIFT <- c(Biopac_Right = 1L, Biopac_Left = 16L)
EVENT_CODES <- c(1:10, 12:13)          # 11 is never emitted
TRIGGER_IDLE_DEFAULT <- 240L           # 0xF0; a hardware pull-up, not an encoding


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

# Infer the rig from the trigger values actually present, using the orthogonality
# of the two code sets. Returns "Biopac_Right", "Biopac_Left", or NA if the
# evidence does not clearly favour one.
#
# `values` is the set of distinct non-idle plateau values on the trigger channel.
rig_from_trigger_codes <- function(values, idle = TRIGGER_IDLE_DEFAULT) {
  v <- unique(values[is.finite(values)])
  v <- v[v != idle & v != 0]
  if (!length(v)) return(NA_character_)

  fits <- vapply(names(RIG_SHIFT), function(rig) {
    s <- RIG_SHIFT[[rig]]
    mean(v %in% (EVENT_CODES * s))
  }, numeric(1))

  best <- names(fits)[which.max(fits)]
  # Demand a clean win: the right rig's 1..13 is not a subset of the left rig's
  # multiples of 16, so a genuine recording should score near 1 on exactly one.
  if (max(fits) < 0.9 || sum(fits >= 0.9) != 1L) return(NA_character_)
  best
}

# Detect the idle level as the modal value of the trigger channel. The handoff
# records 240 for 14542, but 14542 is a right-rig participant and idle is a
# hardware property, so it is measured per file rather than assumed.
detect_trigger_idle <- function(trig) {
  tb <- table(trig[is.finite(trig)])
  as.integer(names(tb)[which.max(tb)])
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

# Decode a raw trigger channel into an event table, undoing the rig's encoding.
# Returns sample index, time, and the DECODED event code (1..13).
decode_triggers <- function(trig, hz, shift, idle = NULL) {
  if (is.null(idle)) idle <- detect_trigger_idle(trig)
  active <- is.finite(trig) & trig != idle & trig != 0
  if (!any(active)) {
    stop("No non-idle samples on the trigger channel (idle detected as ", idle, ").")
  }
  # Leading edge of each plateau, so a held pulse counts once.
  onset <- which(active & c(TRUE, !active[-length(active)]))
  raw   <- trig[onset]
  code  <- raw / shift
  data.frame(
    sample_idx = onset,
    time_sec   = (onset - 1L) / hz,
    raw_value  = raw,
    code       = ifelse(abs(code - round(code)) < 1e-9, as.integer(round(code)), NA_integer_),
    stringsAsFactors = FALSE
  )
}

# Drop everything before the session-start code (1), which removes the setup
# verification cascade. This replaces the fragile 100 s cutoff in the old script.
drop_pre_session <- function(events, session_start_code = 1L) {
  first <- which(events$code == session_start_code)
  if (!length(first)) {
    stop("No session-start code (", session_start_code, ") found. Cannot ",
         "distinguish the setup verification cascade from real trials.")
  }
  events[seq(first[1], nrow(events)), , drop = FALSE]
}
