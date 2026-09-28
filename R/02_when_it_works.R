# =====================================================================
# 02_when_it_works.R  ·  When is the 2-for-1 worth it, and when to shoot?
#
# (a) Effect by the clock time the team gained possession
#     -> separate adjusted OLS inside each 3-second bucket
# (b) Among teams that went 2-for-1: does shooting "too early"
#     (0:34 or later) hand the opponent its own 2-for-1?
#
# Output: output/tables/effect_by_start_bucket.csv
#         output/tables/shot_timing.csv
#         output/figures/fig1_effect_by_start.png
#         output/figures/fig2_shot_timing.png
# =====================================================================
suppressPackageStartupMessages({
  library(readr); library(dplyr); library(purrr); library(sandwich); library(lmtest)
  library(ggplot2)
})

w <- read_csv("data/processed/eoq_windows.csv", show_col_types = FALSE) |>
  arrange(game_id, period) |>
  mutate(start_type = factor(start_type, levels = c("DREB", "MADE_BASKET", "LIVE_TOV", "DEAD_BALL")),
         period = factor(period), season = factor(season),
         margin_c = pmin(pmax(margin_start, -20), 20))

controls <- "start_sec + start_type + period + season + team_off_rtg + opp_def_rtg + margin_c + is_home"
clustered <- function(m, term) {
  ct <- coeftest(m, vcov = vcovCL(m, cluster = ~game_id))
  c(est = ct[term, "Estimate"], se = ct[term, "Std. Error"], p = ct[term, "Pr(>|t|)"])
}

# ---- (a) effect by start bucket ----------------------------------------
by_bucket <- w |>
  group_split(start_bucket) |>
  map_dfr(function(d) {
    m <- lm(as.formula(paste("net_pts ~ went_2for1 +", controls)), data = d)
    r <- clustered(m, "went_2for1")
    tibble(start_bucket = d$start_bucket[1], windows = nrow(d),
           go_rate = mean(d$went_2for1),
           effect = r[["est"]], se = r[["se"]], p_value = r[["p"]],
           ci_low = r[["est"]] - 1.96 * r[["se"]], ci_high = r[["est"]] + 1.96 * r[["se"]])
  })
cat("== (a) Adjusted 2-for-1 effect by when possession was gained ==\n")
print(as.data.frame(mutate(by_bucket, across(where(is.numeric), \(x) round(x, 3)))))
write_csv(by_bucket, "output/tables/effect_by_start_bucket.csv")

# ---- (b) shot timing among 2-for-1 attempts ------------------------------
# Only windows where shooting at 0:34+ was physically realistic (ball gained 0:37+)
att <- w |>
  filter(went_2for1 == 1, start_sec >= 37) |>
  mutate(too_early = as.integer(first_shot_sec >= 34))

m_net     <- lm(as.formula(paste("net_pts ~ too_early +", controls)), data = att)
m_counter <- lm(as.formula(paste("opp_got_second_poss ~ too_early +", controls)), data = att)
m_second  <- lm(as.formula(paste("got_second_poss ~ too_early +", controls)), data = att)

timing <- bind_rows(
  c(outcome = "Net points",                      clustered(m_net, "too_early")),
  c(outcome = "Opponent gets 2 real possessions", clustered(m_counter, "too_early")),
  c(outcome = "Team gets 2 real possessions",    clustered(m_second, "too_early"))
) |> mutate(across(c(est, se, p), as.numeric))

raw_timing <- att |>
  group_by(shot_window = if_else(too_early == 1, "Too early (0:34+ left)", "On time (0:28-0:34 left)")) |>
  summarise(attempts = n(), net_pts = mean(net_pts),
            opp_counter_rate = mean(opp_got_second_poss), .groups = "drop")

cat("\n== (b) Shooting 'too early' (first shot at 0:34+) vs 0:28-0:34, ball gained 0:37+ ==\n")
print(as.data.frame(raw_timing))
cat("\nAdjusted difference (too early minus on time):\n")
print(as.data.frame(mutate(timing, across(where(is.numeric), \(x) round(x, 3)))))
write_csv(timing, "output/tables/shot_timing.csv")
write_csv(raw_timing, "output/tables/shot_timing_raw.csv")

# ---- figures --------------------------------------------------------------
theme_eoq <- theme_minimal(base_size = 12) +
  theme(panel.grid.minor = element_blank(), panel.grid.major.x = element_blank(),
        panel.grid.major.y = element_line(colour = "#e1e0d9", linewidth = 0.4),
        plot.title = element_text(face = "bold"), plot.title.position = "plot",
        axis.text = element_text(colour = "#52514e"))

p1 <- ggplot(by_bucket, aes(x = start_bucket, y = effect)) +
  geom_hline(yintercept = 0, colour = "#c3c2b7") +
  geom_linerange(aes(ymin = ci_low, ymax = ci_high), colour = "#2a78d6", linewidth = 0.9) +
  geom_point(colour = "#2a78d6", size = 3.2) +
  labs(title = "The 2-for-1 pays once you gain the ball with 0:33+ left",
       subtitle = "Adjusted change in end-of-quarter net points, 95% CI (clustered by game)",
       x = "Seconds left when possession was gained", y = "Net points vs. not going") +
  theme_eoq
ggsave("output/figures/fig1_effect_by_start.png", p1, width = 7.5, height = 4.5, dpi = 200, bg = "white")

p2 <- att |>
  mutate(shot_bin = cut(first_shot_sec, breaks = c(28, 31, 34, 37, 46), right = FALSE,
                        labels = c("0:28-0:31", "0:31-0:34", "0:34-0:37", "0:37+"))) |>
  group_by(shot_bin) |>
  summarise(counter = mean(opp_got_second_poss), n = n(), .groups = "drop") |>
  ggplot(aes(x = shot_bin, y = counter)) +
  geom_col(width = 0.55, fill = "#2a78d6") +
  geom_text(aes(label = scales::percent(counter, accuracy = 1)), vjust = -0.5, colour = "#0b0b0b") +
  scale_y_continuous(labels = scales::percent, limits = c(0, 1)) +
  labs(title = "Shoot too early and the opponent gets its own 2-for-1",
       subtitle = "Share of attempts where the opponent got 2 real possessions (ball gained 0:37+)",
       x = "Clock at the first shot", y = NULL) +
  theme_eoq
ggsave("output/figures/fig2_shot_timing.png", p2, width = 7.5, height = 4.5, dpi = 200, bg = "white")
cat("\nFigures written to output/figures/\n")
