# =====================================================================
#  adapters.R — using respkit with an acquisition system it has never seen
#
#  Everything respkit knows about triggers, channel numbering and file
#  formats lives in one file, R/io.R. Nothing in the signal-processing path
#  calls into it. The whole contract between "how the data was acquired" and
#  "what respiration analysis does with it" is a single object:
#
#      resp_recording(signal, fs, id, units, fs_native, t0, events, meta)
#
#  Produce one of those and the entire package works. You do not need to
#  touch, subclass or configure anything else.
#
#  The one rule that matters: `fs` must be the rate the samples are ACTUALLY
#  at. Never the rate you asked for, never a nominal value from a header you
#  have not verified. Getting this wrong is the defect that motivated the
#  package (see README), and it is silent.
# =====================================================================

library(respkit)

## ---------------------------------------------------------------------
## 1. A plain CSV of samples
## ---------------------------------------------------------------------
adapter_csv <- function(path, fs, column = "resp", id = basename(path)) {
  d <- utils::read.csv(path)
  resp_recording(
    signal = d[[column]],
    fs     = fs,                      # must be the true rate
    id     = id,
    units  = "arbitrary",
    meta   = list(source_file = path, column = column)
  )
}

## ---------------------------------------------------------------------
## 2. A file with its own timestamp column
##
## If the samples are irregular, resample them onto a regular grid first --
## every downstream function assumes a constant interval. Deriving fs from
## the timestamps is also the honest way to discover that a recording is not
## running at the rate its header claims.
## ---------------------------------------------------------------------
adapter_timestamped <- function(path, time_col = "t", sig_col = "resp") {
  d  <- utils::read.csv(path)
  dt <- diff(d[[time_col]])
  fs <- 1 / stats::median(dt)

  jitter <- stats::sd(dt) / stats::median(dt)
  if (jitter > 0.01)
    message(sprintf(
      "Sample interval varies by %.1f%%; resampling onto a %.4f Hz grid.",
      100 * jitter, fs))

  grid <- seq(min(d[[time_col]]), max(d[[time_col]]), by = 1 / fs)
  resp_recording(
    signal = stats::approx(d[[time_col]], d[[sig_col]], xout = grid)$y,
    fs     = fs,
    id     = basename(path),
    t0     = grid[1],                 # keeps the original clock
    meta   = list(source_file = path, interval_jitter = jitter)
  )
}

## ---------------------------------------------------------------------
## 3. A different trigger convention
##
## Triggers are just an `events` data frame: a numeric `time` column in
## seconds on the same clock as the signal, plus whatever else you want to
## carry. respkit never interprets the codes; you decide what they mean.
##
## trigger_edges() is exported so you can reuse the edge logic on any
## digital code channel without going through the .acq reader.
## ---------------------------------------------------------------------
## A line that idles somewhere other than zero -- a stuck upper bit puts it at
## 240, with codes 1-8 arriving as 241-248 -- must have that level subtracted
## first, or every code is out of range and no edge survives. Do not raise
## `trigger_max` to cope: the idle stretches then qualify as codes themselves.
## resp_read_acq() takes `trigger_idle` for this; here you subtract it yourself.
adapter_with_triggers <- function(signal, trig, fs, id = NA_character_,
                                  trig_idle = 0) {
  trig  <- trig - trig_idle
  edges <- trigger_edges(trig, trigger_max = 200, min_pulse_s = 0.05, fs = fs)
  resp_recording(
    signal = signal,
    fs     = fs,
    id     = id,
    events = data.frame(time  = (edges - 1L) / fs,
                        label = as.character(trig[edges]),
                        value = trig[edges],
                        stringsAsFactors = FALSE)
  )
}

## ---------------------------------------------------------------------
## 4. Once you have a recording, nothing else changes
## ---------------------------------------------------------------------
if (FALSE) {
  rec <- adapter_csv("mydata.csv", fs = 50)

  res <- resp_analyse(rec)              # detection + morphology
  res$breaths                           # one row per respiratory cycle
  res$features                          # one-row summary
  res$quality$quality                   # good / degraded / unusable

  # Task windows come from wherever you computed them; respkit does not care
  # whether that was a trigger channel, a log file, or a stopwatch.
  onsets <- rec$events$time[rec$events$value == 1]
  eps    <- resp_epochs(onset = onsets, duration = 20, lag = 0.2)
  resp_analyse(rec, epochs = eps)$features
}

## ---------------------------------------------------------------------
## 5. What to check on a transducer respkit has not seen
##
## Three defaults are calibrated to a chest belt sampled at 2000 Hz and will
## not transfer unexamined:
##
##   polarity          "up" assumes the signal RISES on inhalation. A nasal
##                     thermistor usually falls. resp_analyse() diagnoses this
##                     from the data and warns when it disagrees with you;
##                     read res$polarity, which reports the verdict, how far
##                     the median duty cycle sits from 0.5, and whether that
##                     gap is large enough to be trusted. It is not, under a
##                     symmetric pacer -- set polarity from the transducer
##                     specification there.
##
##   iqr_unusable      resp_quality()'s amplitude thresholds are in the units
##   iqr_degraded      of your signal and are meaningless on another scale.
##                     Run the screen across your cohort with these set to NA,
##                     plot filtered_iqr, and choose a cut where it is bimodal.
##                     The frequency, flatline and saturation tests are
##                     scale-free and transfer as they are.
##
##   detect_band       the upper edge of 0.6 Hz caps detection at 36 breaths
##   min_distance_s    per minute, and 1.5 s caps it at 40. Fine for resting
##                     adults; both need raising for paediatric work. See the
##                     rate-ceiling section of ?resp_analyse.
## ---------------------------------------------------------------------
