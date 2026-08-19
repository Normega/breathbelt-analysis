# breathbelt_sim.R
#
# ONE data-generating function for the whole study, per handoff Task 5. The
# hypotheses share parameters, and a script per hypothesis lets those drift out
# of sync.
#
#   simulate_participant(params)          -> breath, trial, block, participant records
#   simulate_study(n, params)             -> replicate across participants
#   analyse_study(data, params)           -> named pass/fail vector for H1..H8
#   power_curve(n_grid, params, n_sims)   -> power by N, per hypothesis
#
# Analytic rather than simulated where the sampling distribution is known:
# H1, H4, H6, and every paired equivalence test on a participant-level mean.
# Simulated where it is not: H2, H3, H5, H7, H8.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHERE THE PARAMETERS COME FROM
#
# Variance components: the internal pilot, via
# Analysis/pilot_variance/variance_components_report.txt ONLY. No effect size
# comes from the pilot; Section 5.12 note 5 forbids it. Margins and expected
# effects are either derived (H1, from H7) or stated as smallest effects of
# interest.
#
# Two parameters are fixed in advance and honoured here:
#   - assumed true bias is ONE QUARTER of the equivalence margin, never zero,
#     because equivalence power peaks at zero (Section 1.7, "Assumed bias")
#   - Block 4 trial count is a RANDOM VARIABLE truncated at 60, drawn per
#     participant, not fixed at 25 (Section 5.12 note 3)

suppressPackageStartupMessages({
  library(stats)
})


# ── Parameters ────────────────────────────────────────────────────────────────

default_params <- function() list(

  # -- From the internal pilot (nuisance variance only) ---------------------
  #
  # sd_between_bias is the 95% PROFILE UPPER BOUND, not the point estimate. REML
  # returned a singular fit: the between-participant variance is estimated at
  # exactly zero, which is the most optimistic possible value and would minimise
  # the required N. The handoff is explicit that an understated
  # between-participant SD yields an optimistically small sample size.
  sd_between_bias   = 35.3,    # ms
  sd_within_diff    = 308.2,   # ms, REML residual
  sd_between_depth  = 0.152,   # z
  sd_between_cv     = 0.1079,
  sd_between_rmssd  = 839.5,   # ms
  align_resid_sd    = 95.2,    # ms

  # -- Usable observation counts, NOT nominal ones --------------------------
  #
  # The pilot yielded 549 matched breath-level differences across 13 of 18
  # participants, i.e. ~42 usable per contributing participant against a nominal
  # ~196. Powering on the nominal count would overstate precision by a factor of
  # more than four. Both the yield and the per-participant count are carried.
  breaths_usable    = 42,
  participant_yield = 13 / 18,

  # -- Design, known --------------------------------------------------------
  block3_trials     = 9L,
  block3_periods    = c(3000, 4000, 5000),
  baseline_period   = 4000,
  block4_min        = 20L,
  block4_cap        = 60L,
  block4_median     = 25L,
  catch_fraction    = 1 / 5,   # C4: catch trials never get direction_correct

  # -- Margins. Set by set_margins(); H1's is derived from H7 --------------
  margin_h1         = NA_real_,
  margin_h4         = NA_real_,
  margin_h6         = NA_real_,
  margin_h7_coef    = NA_real_,
  margin_h8         = NA_real_,
  eq_bound_h3       = NA_real_,

  # Adherence: the fraction of the cued duration change the participant actually
  # produces. Assumed, not measured; no pilot value exists because any error
  # relative to the pacer is blocked (H4).
  adherence          = 0.80,

  # -- Assumed effects (never from the pilot) -------------------------------
  bias_fraction     = 0.25,    # true bias = margin / 4, fixed in advance
  h2_tolerance_paced = 150,    # ms
  h2_tolerance_free  = 400,    # ms, see scripts/00_calibrate_detector.R Part 1
  h2_match_target    = 0.90,   # smallest match proportion of interest
  h5_icc_target      = 0.75,

  # H7's decision rule is GWET'S AC1, not Cohen's kappa. Kappa was the original
  # rule (C3) and is degenerate for this design: with a direction-correct base
  # rate near 0.95, chance agreement is nearly as high as observed agreement, so
  # kappa reads +0.19 at ZERO injected bias, far below any usable floor, and is
  # NON-MONOTONIC in the bias it is supposed to track (+0.19, +0.04, +0.06, +0.14
  # at 0, 100, 200, 400 ms). C3 preregistered AC1 and percent agreement as
  # companions precisely so a prevalence artefact would be diagnosable; it was,
  # and AC1 is promoted to the rule. Kappa is still reported, descriptively.
  # Approved by Norm 2026-08-07.
  h7_ac1_floor       = 0.80,
  h8_alert_effect    = 0.10,   # within-participant, standardised
  alpha              = 0.05
)


# ── Analytic equivalence power ────────────────────────────────────────────────

#' Power of a two-one-sided-tests procedure on a participant-level mean.
#'
#' Exact under normality, so no simulation is needed for H1, H4, H6 or any other
#' paired equivalence test on a participant-level mean.
#'
#' @param n      participants
#' @param margin equivalence margin, symmetric
#' @param true   assumed true effect (NOT zero; see default_params)
#' @param sd_p   SD of the participant-level quantity
tost_power <- function(n, margin, true, sd_p, alpha = 0.05) {
  if (!is.finite(sd_p) || sd_p <= 0 || n < 2) return(NA_real_)
  if (!is.finite(margin) || margin <= 0 || !is.finite(true)) return(NA_real_)
  se <- sd_p / sqrt(n)
  df <- n - 1
  tc <- qt(1 - alpha, df)

  # TOST rejects non-equivalence only when BOTH one-sided tests reject:
  #
  #   (xbar + margin)/se >  tc     rejects  H0: effect <= -margin
  #   (xbar - margin)/se < -tc     rejects  H0: effect >= +margin
  #
  # Together those bound xbar to the interval
  #
  #   -margin + tc*se  <  xbar  <  margin - tc*se
  #
  # so, standardising around the assumed true effect, with a = margin/se and
  # d = true/se:
  #
  #   power = P(a - tc - d  >  T  >  -a + tc - d)
  #
  # An earlier version of this function wrote the two rejections as separate
  # non-central t tail probabilities and SUBTRACTED them. That is wrong: it
  # returned 0 for every margin, including margins so wide that power is
  # essentially 1, because both tails evaluated to 1 and cancelled. The interval
  # form above is the standard approximation and is what is used here.
  #
  # The interval is empty when margin <= tc*se, i.e. when the margin is too
  # narrow to be bounded at this N at all. Power is then 0, correctly.
  a <- margin / se
  d <- true / se
  hi <-  a - tc - d
  lo <- -a + tc - d
  if (hi <= lo) return(0)
  max(0, min(1, pt(hi, df) - pt(lo, df)))
}

#' SD of a participant-level mean difference, accounting for the finite number
#' of breaths each participant contributes.
sd_participant_mean <- function(p) {
  sqrt(p$sd_between_bias^2 + p$sd_within_diff^2 / p$breaths_usable)
}

#' Effective N after participant-level attrition.
#'
#' 5 of 18 pilot participants yielded no usable matched breaths at all. Treating
#' enrolled N as analysable N would overstate power by that factor.
effective_n <- function(n, p) max(2, floor(n * p$participant_yield))


# ── Task 6: derive H1's margin from H7 ────────────────────────────────────────
#
# Inject a systematic bias of X ms into one device's breath durations, re-run the
# direction-correct classification, and find the X at which between-device
# classification agreement falls below the acceptable level. That X is H1's
# margin, and it is defensible in a way a round number is not.
#
# BASE RATE. C3 requires the base rate to be ASSUMED, not taken from the pilot,
# and Study 5's data is not vendored (scripts only), so no empirical value is
# available. Rather than invent one, it is DERIVED from the design and from the
# breath-duration noise the pilot did license:
#
#   direction_correct = sign(dur_34 - dur_12) == sign(delta)
#
# dur_34 - dur_12 has signal `delta * adherence` and noise from breath-duration
# measurement, so
#
#   P(correct) = Phi(|delta| * adherence / sigma_change)
#
# sigma_change is the SD of a difference between two 2-breath means, which for a
# single device is sigma_dur * sqrt(1/2 + 1/2) = sigma_dur. Only the DIFFERENCE
# between devices matters for kappa, and that difference is what the injected
# bias drives.


#' Cohen's kappa for two binary raters. Reported descriptively only; see the
#' h7_ac1_floor note in default_params for why it cannot carry a decision rule.
cohen_kappa <- function(a, b) {
  a <- as.logical(a); b <- as.logical(b)
  if (!length(a)) return(NA_real_)
  po <- mean(a == b)
  pe <- mean(a) * mean(b) + mean(!a) * mean(!b)
  if (pe >= 1) return(NA_real_)
  (po - pe) / (1 - pe)
}

#' Gwet's AC1. Prevalence-robust, and H7's decision statistic.
#'
#' Differs from kappa only in how chance agreement is estimated: AC1 uses
#' 2*pi*(1-pi) with pi the mean prevalence across raters, which does not collapse
#' when prevalence is extreme.
gwet_ac1 <- function(a, b) {
  a <- as.logical(a); b <- as.logical(b)
  if (!length(a)) return(NA_real_)
  po <- mean(a == b)
  pi_hat <- (mean(a) + mean(b)) / 2
  pe <- 2 * pi_hat * (1 - pi_hat)
  if (pe >= 1) return(NA_real_)
  (po - pe) / (1 - pe)
}

#' One study's worth of direction-correct classifications on both devices, under
#' an injected between-device bias.
#'
#' Both devices record the SAME breaths, so the participant's adherence is common
#' to them and cancels; only measurement noise and the injected bias differ. That
#' is the same logic Section 5.6 uses to argue H4's between-device contrast is
#' the clean comparison.
simulate_direction_correct <- function(bias_ms, p, n_analysed) {
  sigma_dur <- p$sd_within_diff / sqrt(2)     # per-device duration noise
  A <- logical(0); B <- logical(0)
  for (i in seq_len(n_analysed)) {
    nb4 <- draw_block4_trials(1, p)
    # Block 3: 3 trials at each of -25%, 0, +25% of the 4000 ms baseline. The
    # 0 condition has delta = 0 and never gets a classification.
    d3 <- rep(c(-1000, 0, 1000), each = 3)
    # Block 4: magnitudes from the QUEST grid, signed by staircase direction,
    # with catch trials zeroed. C4: catch trials never update and never classify,
    # so H7 rests on roughly four fifths of Block 4, not all of it.
    d4 <- sample(c(-1, 1), nb4, TRUE) * round(10^rnorm(nb4, log10(0.5), 0.25) * 1000)
    d4[runif(nb4) < p$catch_fraction] <- 0
    delta <- c(d3, d4)
    delta <- delta[delta != 0]
    if (!length(delta)) next
    true_change <- delta * p$adherence
    A <- c(A, sign(true_change + rnorm(length(delta), 0, sigma_dur)) == sign(delta))
    B <- c(B, sign(true_change + bias_ms + rnorm(length(delta), 0, sigma_dur)) == sign(delta))
  }
  list(a = A, b = B)
}

#' Agreement statistics under an injected bias, with a bootstrap lower bound.
h7_agreement_under_bias <- function(bias_ms, p, n_participants, n_sims = 200,
                                    seed = NULL) {
  if (!is.null(seed)) set.seed(seed)
  n_an <- effective_n(n_participants, p)
  o <- replicate(n_sims, {
    d <- simulate_direction_correct(bias_ms, p, n_an)
    if (length(d$a) < 10) return(c(NA_real_, NA_real_, NA_real_))
    c(mean(d$a == d$b), gwet_ac1(d$a, d$b), cohen_kappa(d$a, d$b))
  })
  ok <- is.finite(o[2, ])
  if (!any(ok)) return(c(agree = NA_real_, ac1 = NA_real_, ac1_lo = NA_real_,
                         kappa = NA_real_))
  c(agree  = mean(o[1, ok]),
    ac1    = mean(o[2, ok]),
    ac1_lo = unname(quantile(o[2, ok], 0.025)),
    kappa  = mean(o[3, ok]))
}

#' TASK 6. Derive H1's equivalence margin from H7.
#'
#' The first injected bias at which AC1's lower 95% bound drops below the floor.
#' That bias is the smallest between-device duration difference that would
#' materially change the study's downstream classification, which is what makes
#' it defensible as a margin in a way a round number is not.
derive_h1_margin <- function(p, n_participants = 60, grid = seq(0, 600, by = 25),
                             n_sims = 200, seed = 20260807) {
  res <- do.call(rbind, lapply(grid, function(x) {
    a <- h7_agreement_under_bias(x, p, n_participants, n_sims = n_sims,
                                 seed = seed + x)
    data.frame(bias_ms = x, agree = a[["agree"]], ac1 = a[["ac1"]],
               ac1_lo = a[["ac1_lo"]], kappa = a[["kappa"]])
  }))
  below <- which(res$ac1_lo < p$h7_ac1_floor)
  list(table = res,
       margin = if (!length(below)) NA_real_ else res$bias_ms[below[1]])
}


# ── Design draws ──────────────────────────────────────────────────────────────

#' Block 4 trial count as a RANDOM VARIABLE (Section 5.12 note 3).
#'
#' Governed by the staircase stopping rule and truncated at the 60-trial cap.
#' The pilot observed a median of 25 with a range of 24 to 35, so this is a
#' right-skewed draw matched to that and truncated, rather than the fixed 25 the
#' earlier drafts assumed.
draw_block4_trials <- function(n, p) {
  x <- p$block4_min + rnbinom(n, size = 2.5, mu = p$block4_median - p$block4_min)
  pmin(x, p$block4_cap)
}


# ── set_margins ───────────────────────────────────────────────────────────────
#
# H1's margin is DERIVED (Task 6). Every other margin is a STATED smallest
# effect of practical interest, per Section 5.12 note 2, which requires margins
# to be justified rather than chosen for convenience. Each is anchored either to
# H1's derived value or to the precision of the quantity it bounds, and each is
# flagged in the pre-registration as stated rather than derived.
set_margins <- function(p, margin_h1) {
  p$margin_h1      <- margin_h1
  # H4 bounds the between-device difference in mean absolute error against the
  # pacer. Same physical quantity and units as H1, so the same threshold of
  # practical interest applies.
  p$margin_h4      <- margin_h1
  # H6 bounds the pre-to-post change in agreement on the CV scale. 0.05 against
  # a CV near 0.15 is a third of the measure: the smallest change that would
  # count as the belts degrading with wear.
  p$margin_h6      <- 0.05
  # H7's coefficient test: half H1's margin, since a coefficient shift smaller
  # than that cannot move a conclusion if the durations are themselves equivalent.
  p$margin_h7_coef <- margin_h1 / 2
  # H8 bounds the between-device difference in the alertness slope, in ms of
  # adherence per SD of alertness.
  p$margin_h8      <- margin_h1 / 2
  # H3 bounds the duration-by-rate coefficient, in ms of duration error per ms of
  # imposed period change. 0.05 means a 1000 ms change in commanded period moves
  # the between-device duration error by at most 50 ms.
  p$eq_bound_h3    <- 0.05
  p
}


# ── simulate_participant ──────────────────────────────────────────────────────

simulate_participant <- function(p, id = 1L) {
  n_b4     <- draw_block4_trials(1, p)
  own_bias <- rnorm(1, p$bias_fraction * p$margin_h1, p$sd_between_bias)

  n_breath <- max(5L, rpois(1, p$breaths_usable))
  breaths  <- data.frame(id = id,
                         diff = rnorm(n_breath, own_bias, p$sd_within_diff))

  d3 <- rep(c(-1000, 0, 1000), each = 3)
  d4 <- sample(c(-1, 1), n_b4, TRUE) * round(10^rnorm(n_b4, log10(0.5), 0.25) * 1000)
  d4[runif(n_b4) < p$catch_fraction] <- 0
  trials <- data.frame(id = id,
                       block = c(rep(3L, length(d3)), rep(4L, length(d4))),
                       delta = c(d3, d4),
                       alert = rnorm(length(d3) + length(d4)))

  blocks <- data.frame(id = id, block = c(2L, 5L),
                       cv = rnorm(2, 0.15, p$sd_between_cv))

  list(breaths = breaths, trials = trials, blocks = blocks,
       participant = data.frame(id = id, own_bias = own_bias, n_b4 = n_b4))
}

simulate_study <- function(n, p) {
  n_eff <- effective_n(n, p)
  parts <- lapply(seq_len(n_eff), function(i) simulate_participant(p, id = i))
  bind <- function(nm) do.call(rbind, lapply(parts, function(z) z[[nm]]))
  list(breaths     = bind("breaths"),
       trials      = bind("trials"),
       blocks      = bind("blocks"),
       participant = bind("participant"),
       n_enrolled  = n, n_analysed = n_eff)
}


# ── Decision rules ────────────────────────────────────────────────────────────

#' TOST on participant-level values. TRUE when BOTH one-sided tests reject.
tost_reject <- function(x, margin, alpha = 0.05) {
  x <- x[is.finite(x)]
  n <- length(x)
  if (n < 3 || !is.finite(margin) || margin <= 0) return(NA)
  se <- sd(x) / sqrt(n)
  if (!is.finite(se) || se <= 0) return(NA)
  df <- n - 1
  (pt((mean(x) - margin) / se, df) < alpha) &&
    (1 - pt((mean(x) + margin) / se, df) < alpha)
}

#' Lower confidence bound on a mean, for rules of the form "lower CI above X".
lower_bound <- function(x, alpha = 0.05) {
  x <- x[is.finite(x)]
  if (length(x) < 3) return(NA_real_)
  mean(x) - qt(1 - alpha, length(x) - 1) * sd(x) / sqrt(length(x))
}


# ── analyse_study ─────────────────────────────────────────────────────────────
#
# Returns a named logical vector, TRUE where that hypothesis's decision rule
# passes on this simulated study.
#
# Mixed models are replaced throughout by the summary-statistics equivalent: a
# per-participant slope or contrast, then a one-sample test across participants.
# For a balanced within-participant design that agrees closely with a
# random-slope model and is fast enough to run inside a power loop, which lmer
# is not.
#
# HONEST LIMITATION. H2 and H5 have no pilot-licensed effect size, because match
# proportion and every agreement coefficient are BLOCKED (Section 1.7). Their
# per-participant quantities are therefore drawn around a STATED smallest effect
# of interest with an assumed spread, and their curves show how precision grows
# with N at that assumed effect. They are not predictions of the effect itself.
analyse_study <- function(dat, p) {
  ids <- unique(dat$breaths$id)
  n   <- length(ids)
  out <- c(H2 = NA, H3 = NA, H5 = NA, H7 = NA, H8 = NA)
  if (n < 3) return(out)

  # -- H2. Cycle-level detection. All three parts must pass (Section 5.4). ---
  match_p <- rbeta(n, p$h2_match_target * 30, (1 - p$h2_match_target) * 30)
  timing  <- rnorm(n, 0, p$align_resid_sd / sqrt(p$breaths_usable))
  count_i <- rnorm(n, 0.80, 0.12)
  out[["H2"]] <- isTRUE(lower_bound(match_p, p$alpha) > p$h2_match_target - 0.05) &&
                 isTRUE(abs(mean(timing)) < p$h2_tolerance_paced) &&
                 isTRUE(lower_bound(count_i, p$alpha) > 0.75)

  # -- H3. Rate invariance of duration error, tested for EQUIVALENCE. -------
  slopes <- vapply(ids, function(i) {
    tr <- dat$trials[dat$trials$id == i & dat$trials$delta != 0, ]
    if (nrow(tr) < 4) return(NA_real_)
    y <- p$bias_fraction * p$eq_bound_h3 * tr$delta +
         rnorm(nrow(tr), 0, p$sd_within_diff / sqrt(2))
    unname(coef(lm(y ~ tr$delta))[2])
  }, numeric(1))
  out[["H3"]] <- isTRUE(tost_reject(slopes, p$eq_bound_h3, p$alpha))

  # -- H5. Variability agreement, ICC lower bound above target. -------------
  icc_draw <- rnorm(n, p$h5_icc_target + 0.08, 0.15)
  out[["H5"]] <- isTRUE(lower_bound(icc_draw, p$alpha) > p$h5_icc_target)

  # -- H7. AC1 floor AND coefficient equivalence, both required. ------------
  d  <- simulate_direction_correct(p$bias_fraction * p$margin_h1, p, n)
  a1 <- if (length(d$a) >= 10) gwet_ac1(d$a, d$b) else NA_real_
  coef_diff <- rnorm(n, p$bias_fraction * p$margin_h7_coef, p$sd_between_bias)
  out[["H7"]] <- isTRUE(is.finite(a1) && a1 > p$h7_ac1_floor) &&
                 isTRUE(tost_reject(coef_diff, p$margin_h7_coef, p$alpha))

  # -- H8. Alertness slope, equivalence between devices. --------------------
  b_diff <- vapply(ids, function(i) {
    nb <- sum(dat$trials$id == i & dat$trials$block == 4L)
    if (nb < 5) return(NA_real_)
    rnorm(1, p$bias_fraction * p$margin_h8, p$sd_within_diff / sqrt(nb))
  }, numeric(1))
  out[["H8"]] <- isTRUE(tost_reject(b_diff, p$margin_h8, p$alpha))

  out
}


# ── power_curve ───────────────────────────────────────────────────────────────
#
# ANALYTIC for H1, H4, H6: a TOST on a participant-level mean has a known
# sampling distribution, so simulating it would add Monte Carlo error and
# nothing else. SIMULATED for H2, H3, H5, H7, H8.
#
# n is ENROLLED participants. Every curve is evaluated at effective_n(n), the
# number expected to yield usable matched breaths, because 5 of 18 pilot
# participants yielded none.

power_curve <- function(n_grid, p, n_sims = 400, seed = 20260807) {
  set.seed(seed)
  sd_p <- sd_participant_mean(p)

  do.call(rbind, lapply(n_grid, function(n) {
    n_eff <- effective_n(n, p)
    sims  <- replicate(n_sims, analyse_study(simulate_study(n, p), p))
    sim_p <- rowMeans(sims == 1, na.rm = TRUE)

    data.frame(
      n = n, n_analysed = n_eff,
      H1 = tost_power(n_eff, p$margin_h1, p$bias_fraction * p$margin_h1, sd_p, p$alpha),
      H2 = sim_p[["H2"]],
      H3 = sim_p[["H3"]],
      H4 = tost_power(n_eff, p$margin_h4, p$bias_fraction * p$margin_h4, sd_p, p$alpha),
      H5 = sim_p[["H5"]],
      H6 = tost_power(n_eff, p$margin_h6, p$bias_fraction * p$margin_h6,
                      p$sd_between_cv, p$alpha),
      H7 = sim_p[["H7"]],
      H8 = sim_p[["H8"]])
  }))
}
