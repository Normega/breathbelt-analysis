# diag_physio_14542.R
#
# Diagnostic plots for physio alignment and signal quality.
# Loads the RDS produced by prep_physio_14542.R and generates a PDF with:
#
#   Page 1 — Full-session overview: BioPac breath + belt MLR-LP (aligned)
#   Page 2 — Alignment diagnostics: per-trial offset + drift fit residuals
#   Page 3 — MLR calibration: BioPac breath vs belt axes during baseline
#   Page 4 — Trial overlay grid: first 9 trials, BioPac vs belt (both signals)
#   Page 5 — Single trial zoom: trial 1, all three signals + condition onset

# ── Set Up ────────────────────────────────────────────────────────────────────
packages <- c("tidyverse", "patchwork")
new_packages <- packages[!sapply(packages, requireNamespace, quietly = TRUE)]
if (length(new_packages)) install.packages(new_packages)
options(readr.show_col_types = FALSE)
for (thispack in packages) {
  library(thispack, character.only = TRUE, quietly = TRUE, verbose = FALSE)
}

# ── Paths ─────────────────────────────────────────────────────────────────────
BASE_DIR   <- file.path("I:", "Shared drives", "Behavioral Interoception",
                        "Summer2026_CompareBelts")
OUTPUT_DIR <- file.path(BASE_DIR, "Analysis", "output")

PID      <- "14542"
RDS_FILE <- file.path(OUTPUT_DIR, paste0(PID, "_physio.rds"))
PDF_FILE <- file.path(OUTPUT_DIR, paste0(PID, "_physio_diag.pdf"))

# ── Load RDS ──────────────────────────────────────────────────────────────────
message("Loading RDS...")
d <- readRDS(RDS_FILE)

accel_grid   <- d$belt$accel_grid
alignment    <- d$alignment$trial_table
trial_epochs <- d$trial_epochs
RESP_HZ      <- d$belt$hz
session_start <- d$session_start_epoch_ms

bp_breath <- d$biopac$breath_25hz
bp_t_s    <- seq(0, length(bp_breath) - 1) / RESP_HZ

accel_grid <- accel_grid |>
  dplyr::mutate(t_s = (epoch_ms - session_start) / 1000)

# ── Shared theme ──────────────────────────────────────────────────────────────
th <- theme_minimal(base_size = 10) +
  theme(panel.grid.minor = element_blank(),
        plot.title = element_text(face = "bold", size = 11))

scale_to <- function(x, ref) {
  x_sc <- (x - mean(x, na.rm = TRUE)) / sd(x, na.rm = TRUE)
  x_sc * sd(ref, na.rm = TRUE) + mean(ref, na.rm = TRUE)
}

# ── Page 1: Full-session overview ─────────────────────────────────────────────
message("Page 1: Full-session overview...")

# Convert BioPac time axis to seconds-from-session-start using drift-corrected offset
offset_ms <- alignment$offset_corrected_ms[1]
bp_plot <- data.frame(t_s = bp_t_s, breath = bp_breath) |>
  dplyr::filter(dplyr::row_number() %% 5 == 0) |>
  dplyr::mutate(t_session_s = t_s - (offset_ms - session_start) / 1000)

belt_plot <- accel_grid |>
  dplyr::filter(dplyr::row_number() %% 2 == 0) |>
  dplyr::select(t_s, mlr_lp) |>
  dplyr::mutate(mlr_scaled = scale_to(mlr_lp, bp_breath))

trial_markers <- alignment |>
  dplyr::mutate(t_session_s = belt_onset_ms / 1000)

pg1 <- ggplot() +
  geom_line(data = bp_plot,
            aes(x = t_session_s, y = breath),
            colour = "steelblue", linewidth = 0.3, alpha = 0.8) +
  geom_line(data = belt_plot,
            aes(x = t_s, y = mlr_scaled),
            colour = "darkorchid", linewidth = 0.3, alpha = 0.7) +
  geom_vline(data = trial_markers,
             aes(xintercept = t_session_s),
             colour = "grey40", linetype = "dashed", linewidth = 0.3) +
  labs(title = sprintf("Participant %s \u2014 Full session (blue=BioPac breath, purple=belt MLR-LP)", PID),
       x = "Time from session start (s)", y = "Amplitude") + th


# ── Page 2: Alignment diagnostics ─────────────────────────────────────────────
message("Page 2: Alignment diagnostics...")

p2a <- ggplot(alignment, aes(x = trial_idx, y = offset_ms - mean(offset_ms))) +
  geom_point(aes(colour = factor(phase)), size = 2) +
  geom_smooth(method = "lm", se = FALSE, colour = "grey30", linewidth = 0.7) +
  scale_colour_manual(values = c("2" = "steelblue", "3" = "tomato"),
                      labels = c("2" = "Phase 2 (fixed)", "3" = "Phase 3 (QUEST)"),
                      name = "Phase") +
  labs(title = "Clock drift: per-trial offset (demeaned)",
       x = "Trial index", y = "Offset deviation (ms)") + th

p2b <- ggplot(alignment, aes(x = trial_idx, y = residual_ms)) +
  geom_hline(yintercept = 0,       linetype = "dashed", colour = "grey60") +
  geom_hline(yintercept = c(-40, 40), linetype = "dotted", colour = "tomato", linewidth = 0.4) +
  geom_point(aes(colour = factor(phase)), size = 2) +
  scale_colour_manual(values = c("2" = "steelblue", "3" = "tomato"), name = "Phase") +
  annotate("text", x = max(alignment$trial_idx), y = 44,
           label = "+/- 1 sample (40ms)", hjust = 1, size = 3, colour = "tomato") +
  labs(title = sprintf("Residuals after linear drift correction  (SD = %.1f ms)",
                       sd(alignment$residual_ms)),
       x = "Trial index", y = "Residual (ms)") + th

pg2 <- p2a / p2b

# ── Page 3: MLR calibration ───────────────────────────────────────────────────
message("Page 3: MLR calibration...")

baseline_df <- accel_grid |>
  dplyr::filter(!is.na(x_bp) & !is.na(biopac_breath))

set.seed(42)
sub <- baseline_df |> dplyr::slice_sample(n = min(500, nrow(baseline_df)))

p3a <- ggplot(sub, aes(x = x_bp, y = biopac_breath)) +
  geom_point(alpha = 0.3, size = 1, colour = "steelblue") +
  geom_smooth(method = "lm", se = FALSE, colour = "navy", linewidth = 0.8) +
  labs(title = sprintf("x_bp vs BioPac  (r=%.3f)",
                       cor(baseline_df$x_bp, baseline_df$biopac_breath, use = "complete.obs")),
       x = "x (bandpass)", y = "BioPac breath") + th

p3b <- ggplot(sub, aes(x = y_bp, y = biopac_breath)) +
  geom_point(alpha = 0.3, size = 1, colour = "tomato") +
  geom_smooth(method = "lm", se = FALSE, colour = "darkred", linewidth = 0.8) +
  labs(title = sprintf("y_bp vs BioPac  (r=%.3f)",
                       cor(baseline_df$y_bp, baseline_df$biopac_breath, use = "complete.obs")),
       x = "y (bandpass)", y = "BioPac breath") + th

p3c <- ggplot(sub, aes(x = z_bp, y = biopac_breath)) +
  geom_point(alpha = 0.3, size = 1, colour = "darkorchid") +
  geom_smooth(method = "lm", se = FALSE, colour = "purple4", linewidth = 0.8) +
  labs(title = sprintf("z_bp vs BioPac  (r=%.3f)",
                       cor(baseline_df$z_bp, baseline_df$biopac_breath, use = "complete.obs")),
       x = "z (bandpass)", y = "BioPac breath") + th

p3d <- baseline_df |>
  dplyr::filter(dplyr::row_number() %% 3 == 0) |>
  tidyr::pivot_longer(cols = c(biopac_breath, mlr_lp),
                      names_to = "signal", values_to = "value") |>
  dplyr::group_by(signal) |>
  dplyr::mutate(value = as.numeric(scale(value))) |>
  dplyr::ungroup() |>
  ggplot(aes(x = t_s, y = value, colour = signal)) +
  geom_line(linewidth = 0.4, alpha = 0.8) +
  scale_colour_manual(values = c("biopac_breath" = "steelblue",
                                 "mlr_lp"        = "darkorchid"),
                      labels = c("biopac_breath" = "BioPac",
                                 "mlr_lp"        = "MLR-LP")) +
  labs(title = "Baseline time series (z-scored)",
       x = "Time from session start (s)", y = "z-score", colour = NULL) + th

pg3 <- (p3a | p3b | p3c) / p3d + plot_layout(heights = c(1, 1.5))

# ── Page 4: Trial overlay grid (first 9 trials) ───────────────────────────────
message("Page 4: Trial overlay grid...")

plot_trial <- function(ep) {
  t_belt <- ep$belt_t_ms / 1000
  t_bp   <- seq(0, length(ep$biopac_breath_25hz) - 1) / RESP_HZ
  cond_t <- ep$condition_offset_ms / 1000
  
  df <- dplyr::bind_rows(
    data.frame(t = t_bp,   y = as.numeric(scale(ep$biopac_breath_25hz)), signal = "BioPac"),
    data.frame(t = t_belt, y = as.numeric(scale(ep$belt_mlr_lp_25hz)),   signal = "MLR-LP")
  )
  
  ggplot(df, aes(x = t, y = y, colour = signal)) +
    geom_vline(xintercept = cond_t, colour = "grey50", linetype = "dashed", linewidth = 0.4) +
    geom_line(linewidth = 0.45, alpha = 0.85) +
    scale_colour_manual(values = c("BioPac" = "steelblue",
                                   "MLR-LP" = "darkorchid")) +
    labs(title = sprintf("T%d Ph%s %s\nr_mlr=%.2f",
                         ep$trial_number, ep$phase, ep$condition,
                         ep$r_mlr_vs_biopac),
         x = "s", y = NULL) +
    th + theme(plot.title   = element_text(size = 7),
               axis.text    = element_text(size = 7),
               legend.position = "none")
}

trial_plots <- lapply(trial_epochs[seq_len(min(9, length(trial_epochs)))], plot_trial)
pg4 <- patchwork::wrap_plots(trial_plots, ncol = 3) +
  patchwork::plot_annotation(
    title = sprintf("Participant %s — Trial overlay (blue=BioPac, purple=MLR-LP)", PID),
    theme = theme(plot.title = element_text(face = "bold", size = 11))
  )

# ── Page 5: Single trial zoom ─────────────────────────────────────────────────
message("Page 5: Single trial zoom...")

ep1    <- trial_epochs[[1]]
t_belt <- ep1$belt_t_ms / 1000
t_bp   <- seq(0, length(ep1$biopac_breath_25hz) - 1) / RESP_HZ
cond_t <- ep1$condition_offset_ms / 1000

df5 <- dplyr::bind_rows(
  data.frame(t = t_bp,   y = as.numeric(scale(ep1$biopac_breath_25hz)), signal = "BioPac breath"),
  data.frame(t = t_belt, y = as.numeric(scale(ep1$belt_mlr_lp_25hz)),   signal = "Belt MLR-LP")
)

pg5 <- ggplot(df5, aes(x = t, y = y, colour = signal)) +
  geom_vline(xintercept = 0,      colour = "grey40", linetype = "dashed") +
  geom_vline(xintercept = cond_t, colour = "grey40", linetype = "dotted") +
  geom_line(linewidth = 0.7, alpha = 0.9) +
  scale_colour_manual(values = c("BioPac breath" = "steelblue",
                                 "Belt MLR-LP"   = "darkorchid")) +
  annotate("text", x = 0.2,          y = Inf, label = "trial onset",
           vjust = 1.5, size = 3, colour = "grey40") +
  annotate("text", x = cond_t + 0.2, y = Inf, label = "condition onset",
           vjust = 1.5, size = 3, colour = "grey40") +
  labs(title = sprintf("Participant %s — Trial 1 zoom (z-scored)", PID),
       x = "Time from trial onset (s)", y = "z-score", colour = NULL) + th

# ── Save PDF ──────────────────────────────────────────────────────────────────
message(sprintf("Saving PDF: %s", PDF_FILE))
pdf(PDF_FILE, width = 11, height = 8.5)
print(pg1)
print(pg2)
print(pg3)
print(pg4)
print(pg5)
dev.off()
message("Done.")