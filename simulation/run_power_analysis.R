# run_power_analysis.R
#
# Task 6 then Task 5: derive the equivalence margins, then produce the power
# curves and the deliverable figure.
#
# Usage:  Rscript simulation/run_power_analysis.R
#
# Outputs, all under Analysis/power/:
#   h1_margin_derivation.txt   the H7 sweep that fixes H1's margin
#   power_curves.csv           power by N for H1 through H8
#   power_curves.png           THE deliverable figure
#   power_analysis_report.txt  everything, in text

# Set Up ---------
## Load libraries ---------
packages <- c("stats", "grDevices", "graphics")
for (thispack in packages) {
  library(thispack, character.only = TRUE, quietly = TRUE, verbose = FALSE)
}

BASE_DIR <- file.path("I:", "Shared drives", "Behavioral Interoception",
                      "Summer2026_CompareBelts")
source(file.path(BASE_DIR, "simulation", "breathbelt_sim.R"))

OUT_DIR <- file.path(BASE_DIR, "Analysis", "power")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

# Sample size decisions, fixed by Norm 2026-08-14. Both are drawn on the figure.
#
#   TARGET   the preregistered enrolment target, set by H6
#   HARD_CAP the most the interim re-estimation may raise the target to, if the
#            variance comes back higher than the pilot estimated. Set at 100
#            because a one-standard-error increase in the CV spread (the estimate
#            carries 17.1% relative SE at n = 18) would require N = 103 for 0.80
#            power on H6. A cap at the target would leave H6 at 0.665 in that case
#   INTERIM  enrolled N at which the variance is re-estimated, once
TARGET   <- 75
HARD_CAP <- 100
INTERIM  <- 40

# H1's PREREGISTERED equivalence margin, fixed by Norm 2026-08-14.
#
# This is TIGHTER than the value derived from H7 below, and deliberately so. The
# derivation answers "at what between-device bias do downstream conclusions start
# to change", which is a CEILING on what may be tolerated, not a target. The
# design supports roughly 27 ms at 0.80 power, so 150 ms retains about 5.5x
# headroom while making the confirmatory claim substantially stronger. The derived
# value is still computed and reported, since it is the evidence the tightening is
# measured against.
MARGIN_H1 <- 150

N_GRID   <- c(10, 15, 20, 25, 30, 40, 50, 60, 75, 90, 100, 110, 130)
N_SIMS   <- 400

p0 <- default_params()


# ── Task 6: derive H1's margin ────────────────────────────────────────────────

message("Deriving H1's margin ceiling from H7 (this is the slow part)...")
der <- derive_h1_margin(p0, n_participants = TARGET,
                        grid = seq(0, 600, by = 25), n_sims = 120)
margin_derived <- der$margin
if (!is.finite(margin_derived)) {
  stop("AC1 never fell below the floor across the swept bias range. Widen the ",
       "grid or reconsider the floor.")
}
# The DERIVED value is the ceiling; the PREREGISTERED value is the tightening.
# Guard against the two crossing: if the derivation ever came back below the
# preregistered margin, the tightening would no longer be a tightening and the
# preregistered value would be admitting biases H7 says are consequential.
if (MARGIN_H1 > margin_derived) {
  stop("Preregistered H1 margin (", MARGIN_H1, " ms) EXCEEDS the H7-derived ",
       "ceiling (", margin_derived, " ms). The preregistered margin must be at ",
       "or below the derived value.")
}
p <- set_margins(p0, MARGIN_H1)

sink(file.path(OUT_DIR, "h1_margin_derivation.txt"))
cat("BreathBelt: deriving H1's equivalence margin from H7\n")
cat("Generated:", as.character(Sys.time()), "\n")
cat(strrep("=", 74), "\n\n")
cat("METHOD (handoff Task 6). Inject a systematic bias of X ms into one\n")
cat("device's breath durations, re-run the direction-correct classification,\n")
cat("and take the X at which between-device classification agreement falls\n")
cat("below an acceptable level. That X is the CEILING on the margin.\n\n")
cat("NOTE ON WHAT THE DERIVATION IS FOR. It answers 'at what bias do downstream\n")
cat("conclusions start to change', which bounds what may be TOLERATED. It does\n")
cat("not say what should be CLAIMED. The preregistered margin is set tighter,\n")
cat("since the design supports far more precision than the ceiling requires.\n\n")
cat("DECISION STATISTIC: Gwet's AC1, lower 95% bound, floor",
    p$h7_ac1_floor, "\n\n")
cat("Cohen's kappa was the original rule (docs/discrepancies.md C3) and is\n")
cat("DEGENERATE for this design. With a direction-correct base rate near 0.95,\n")
cat("chance agreement is nearly as high as observed agreement, so kappa reads\n")
cat("about +0.19 at ZERO injected bias, already far below any usable floor,\n")
cat("and it is NON-MONOTONIC in the bias it is meant to track. C3 preregistered\n")
cat("AC1 and percent agreement as companions precisely so a prevalence artefact\n")
cat("would be diagnosable rather than fatal. It was diagnosed; AC1 is promoted\n")
cat("to the decision rule and kappa is retained as a descriptive.\n")
cat("Approved by Norm 2026-08-07.\n\n")
cat("BASE RATE is assumed, not taken from the pilot (Section 5.12 note 5).\n")
cat("Study 5's data is not vendored, so no empirical value exists; the rate is\n")
cat("derived from the design and from the breath-duration noise the pilot did\n")
cat("license, with adherence assumed at", p$adherence, "\n\n")
print(der$table, row.names = FALSE, digits = 3)
cat("\nDERIVED CEILING          :", margin_derived, "ms\n")
cat("PREREGISTERED H1 MARGIN  :", p$margin_h1, "ms",
    sprintf("(%.0f%% of the ceiling)\n", 100 * p$margin_h1 / margin_derived))
cat("Tightening fixed by Norm 2026-08-14. Headroom over the 0.80-power floor\n")
cat("of roughly 27 ms at the target N is about",
    sprintf("%.1fx", p$margin_h1 / 27.4), "\n\n")
cat("Margins that follow from it (STATED smallest effects of interest, not\n")
cat("derived; Section 5.12 note 2):\n")
cat("  H4 between-device mean absolute error :", p$margin_h4, "ms\n")
cat("  H6 pre-to-post change in CV           :", p$margin_h6, "\n")
cat("  H7 coefficient equivalence            :", p$margin_h7_coef, "ms\n")
cat("  H8 alertness slope difference         :", p$margin_h8, "ms\n")
cat("  H3 duration-by-rate coefficient       :", p$eq_bound_h3, "\n")
sink()
message("  H1 margin: ", p$margin_h1, " ms preregistered, ",
        margin_derived, " ms derived ceiling")


# ── Task 5: power curves ──────────────────────────────────────────────────────

message("Running power curves over N = ", paste(range(N_GRID), collapse = " to "),
        " with ", N_SIMS, " simulations per point...")
pc <- power_curve(N_GRID, p, n_sims = N_SIMS)
write.csv(pc, file.path(OUT_DIR, "power_curves.csv"), row.names = FALSE)


# ── Figure ────────────────────────────────────────────────────────────────────

hyp  <- paste0("H", 1:8)
cols <- c("#1b6ca8", "#e07b39", "#3f9b5b", "#c0392b", "#7d5ba6",
          "#8c6239", "#d16d9e", "#4f4f4f")

# H2, H4 and H5 are drawn DASHED, because their curves are not what the others
# are (prereg Section 5.13). H2 and H5 rest on a STATED effect, since match
# proportion and every agreement coefficient are blocked; H4 borrows H1's
# variance, since its own is blocked. A reader who sees only the figure would
# otherwise read H2's 0.93 at the target as a prediction of the match rate.
QUALIFIED <- c("H2", "H4", "H5")
ltys <- ifelse(hyp %in% QUALIFIED, 2, 1)

png(file.path(OUT_DIR, "power_curves.png"), width = 1150, height = 800, res = 120)
par(mar = c(7, 5, 4, 8), xpd = FALSE)
plot(NA, xlim = range(N_GRID), ylim = c(0, 1),
     xlab = "Participants enrolled",
     ylab = "Power",
     main = "BreathBelt: power against sample size, H1 to H8")
mtext("Dashed: assumed rather than pilot-licensed effect (H2, H5) or borrowed variance (H4). See Section 5.13.",
      side = 1, line = 5, cex = 0.7, col = "grey30")
abline(h = c(0.8, 0.9), col = "grey75", lty = c(2, 3))
abline(v = TARGET,   col = "grey20", lty = 1, lwd = 2)
abline(v = HARD_CAP, col = "grey45", lty = 4, lwd = 1.8)
abline(v = INTERIM,  col = "grey60", lty = 3, lwd = 1.5)
for (i in seq_along(hyp)) {
  lines(pc$n, pc[[hyp[i]]], col = cols[i], lwd = 2.2, lty = ltys[i],
        type = "b", pch = 16, cex = 0.6)
}
text(INTERIM,  0.02, paste0(" interim\n re-estimate\n N=", INTERIM),
     adj = c(0, 0), cex = 0.65, col = "grey45")
text(TARGET,   0.02, paste0(" target N=", TARGET),
     adj = c(0, 0), cex = 0.75, col = "grey20")
text(HARD_CAP, 0.02, paste0(" hard cap N=", HARD_CAP),
     adj = c(0, 0), cex = 0.7, col = "grey45")
text(max(N_GRID), 0.805, "0.80", adj = c(1, 0), cex = 0.7, col = "grey40")
par(xpd = TRUE)
legend(max(N_GRID) * 1.03, 1,
       legend = ifelse(hyp %in% QUALIFIED, paste0(hyp, "*"), hyp),
       col = cols, lwd = 2.2, lty = ltys, bty = "n", cex = 0.85, pch = 16)
dev.off()


# ── Report ────────────────────────────────────────────────────────────────────

n80 <- vapply(hyp, function(h) {
  ok <- which(is.finite(pc[[h]]) & pc[[h]] >= 0.80)
  if (!length(ok)) NA_real_ else pc$n[ok[1]]
}, numeric(1))

sink(file.path(OUT_DIR, "power_analysis_report.txt"))
cat("BreathBelt power analysis\n")
cat("Generated:", as.character(Sys.time()), "\n")
cat(strrep("=", 74), "\n\n")
cat("VARIANCE PARAMETERS, from the internal pilot (nuisance only):\n")
cat("  between-participant SD of duration bias :", p$sd_between_bias,
    "ms  (95% profile UPPER bound; REML point estimate was 0)\n")
cat("  within-participant SD of differences    :", p$sd_within_diff, "ms\n")
cat("  usable matched breaths per participant  :", p$breaths_usable, "\n")
cat("  participant yield                       :", round(p$participant_yield, 3),
    " (13 of 18 pilot participants yielded usable matched breaths)\n\n")
cat("MARGINS:\n")
cat("  H1 PREREGISTERED     :", p$margin_h1, "ms\n")
cat("  H1 derived ceiling   :", margin_derived, "ms (from H7; the preregistered\n")
cat("                          margin is deliberately tighter, Norm 2026-08-14)\n")
cat("  H3 / H4 / H6 / H7 / H8 are stated smallest effects of interest.\n\n")
cat("ASSUMED TRUE BIAS is one quarter of each margin, never zero, because\n")
cat("equivalence power peaks at zero (Section 1.7).\n\n")
cat("SAMPLE SIZE PLAN (Norm 2026-08-14):\n")
cat("  target                :", TARGET, "enrolled\n")
cat("  interim re-estimation :", INTERIM, "enrolled, once\n")
cat("  hard cap              :", HARD_CAP, "enrolled\n\n")
cat("POWER AT THE TARGET, N =", TARGET, ":\n")
row <- pc[pc$n == TARGET, ]
for (h in hyp) cat(sprintf("  %-3s %.3f\n", h, row[[h]]))
cat("\nSMALLEST N REACHING 0.80 POWER:\n")
for (h in hyp) cat(sprintf("  %-3s %s\n", h,
                           ifelse(is.na(n80[[h]]), paste0("> ", max(N_GRID)),
                                  as.character(n80[[h]]))))
cat("\nFULL CURVE:\n")
print(pc, row.names = FALSE, digits = 3)
cat("\nCAVEAT. H2 and H5 have no pilot-licensed effect size, because match\n")
cat("proportion and every agreement coefficient are BLOCKED (Section 1.7).\n")
cat("Their per-participant quantities are drawn around a STATED smallest effect\n")
cat("of interest with an assumed spread, so their curves show how precision\n")
cat("grows with N at that assumed effect rather than predicting the effect.\n")
sink()

message("Wrote: ", file.path(OUT_DIR, "power_curves.png"))
message("Wrote: ", file.path(OUT_DIR, "power_analysis_report.txt"))
