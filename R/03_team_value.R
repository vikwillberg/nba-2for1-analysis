# =====================================================================
# 03_team_value.R  ·  Which teams leave the most points on the table?
#
# Grades DECISIONS, not results: each team-season is charged the league-wide
# adjusted value of every mistake, so a lucky miss/make doesn't move the grade.
#   * pass    = gained the ball with 0:33+ left and did NOT go 2-for-1
#   * too early = went 2-for-1 but first shot came with 0:34+ left
#                 (only counted when the ball was gained 0:37+)
# Points -> wins uses the rule of thumb that +1 point of per-game margin
# is worth ~2.7 wins over 82 games, i.e. ~30 points of season margin per win.
#
# Output: output/tables/green_zone_effect.csv, output/tables/team_value.csv,
#         output/figures/fig3_team_points_left.png
# =====================================================================
suppressPackageStartupMessages({
  library(readr); library(dplyr); library(sandwich); library(lmtest); library(ggplot2)
})
PTS_PER_WIN <- 30

w <- read_csv("data/processed/eoq_windows.csv", show_col_types = FALSE) |>
  arrange(game_id, period) |>
  mutate(start_type = factor(start_type, levels = c("DREB", "MADE_BASKET", "LIVE_TOV", "DEAD_BALL")),
         period = factor(period), season = factor(season),
         margin_c = pmin(pmax(margin_start, -20), 20))
teams <- read_csv("data/raw/teams.csv", show_col_types = FALSE)

# pooled green-zone effect (ball gained 0:33-0:45)
green <- filter(w, start_sec >= 33)
m_green <- lm(net_pts ~ went_2for1 + start_sec + start_type + period + season +
                team_off_rtg + opp_def_rtg + margin_c + is_home, data = green)
ct <- coeftest(m_green, vcov = vcovCL(m_green, cluster = ~game_id))
value_go <- ct["went_2for1", "Estimate"]
cat(sprintf("Green-zone value of going 2-for-1: %.3f pts (SE %.3f)\n",
            value_go, ct["went_2for1", "Std. Error"]))
write_csv(tibble(estimate = value_go, se = ct["went_2for1", "Std. Error"],
                 windows = nrow(green)), "output/tables/green_zone_effect.csv")

cost_early <- read_csv("output/tables/shot_timing.csv", show_col_types = FALSE) |>
  filter(outcome == "Net points") |> pull(est) |> abs()
cat(sprintf("Cost of shooting too early: %.3f pts\n\n", cost_early))

team_season <- w |>
  group_by(season, team_id) |>
  summarise(
    green_windows = sum(start_sec >= 33),
    passes        = sum(start_sec >= 33 & went_2for1 == 0),
    go_rate       = mean(went_2for1[start_sec >= 33]),
    early_chances = sum(went_2for1 == 1 & start_sec >= 37),
    too_early     = sum(went_2for1 == 1 & start_sec >= 37 & first_shot_sec >= 34),
    .groups = "drop") |>
  mutate(pts_left_pass  = passes * value_go,
         pts_left_early = too_early * cost_early,
         pts_left       = pts_left_pass + pts_left_early)

team_value <- team_season |>
  group_by(team_id) |>
  summarise(seasons = n(),
            go_rate          = 1 - sum(passes) / sum(green_windows),
            too_early_rate   = sum(too_early) / sum(early_chances),
            pts_left_pass    = mean(pts_left_pass),
            pts_left_early   = mean(pts_left_early),
            pts_left_per_season = mean(pts_left),
            .groups = "drop") |>
  mutate(wins_left_per_season = pts_left_per_season / PTS_PER_WIN) |>
  left_join(teams, by = "team_id") |>
  arrange(pts_left_per_season) |>
  mutate(rank = row_number())

cat("== Points left on the table per season (3-season average) ==\n")
print(as.data.frame(team_value |>
  select(rank, team_tricode, go_rate, too_early_rate, pts_left_pass, pts_left_early,
         pts_left_per_season, wins_left_per_season) |>
  mutate(across(where(is.double), \(x) round(x, 2)))), row.names = FALSE)

best  <- team_value$pts_left_per_season[1]
worst <- team_value$pts_left_per_season[nrow(team_value)]
cat(sprintf("\nMedian team: %.1f pts/season | best-to-worst gap: %.1f pts = %.2f wins/season\n",
            median(team_value$pts_left_per_season), worst - best, (worst - best) / PTS_PER_WIN))
write_csv(team_value, "output/tables/team_value.csv")

# ---- figure -------------------------------------------------------------
p3 <- team_value |>
  mutate(team_tricode = factor(team_tricode, levels = rev(team_tricode))) |>
  tidyr::pivot_longer(c(pts_left_pass, pts_left_early), names_to = "source", values_to = "pts") |>
  mutate(source = recode(source, pts_left_pass = "Passed on a 2-for-1",
                                 pts_left_early = "Shot too early")) |>
  ggplot(aes(x = pts, y = team_tricode, fill = source)) +
  geom_col(width = 0.7) +
  scale_fill_manual(values = c("Passed on a 2-for-1" = "#2a78d6", "Shot too early" = "#eb6834")) +
  labs(title = "Points left on the table by end-of-quarter decisions",
       subtitle = "Per season, 3-season average. Decisions graded at league-average value.",
       x = "Points per season", y = NULL, fill = NULL) +
  theme_minimal(base_size = 11) +
  theme(legend.position = "top", panel.grid.major.y = element_blank(),
        panel.grid.minor = element_blank(), plot.title = element_text(face = "bold"),
        plot.title.position = "plot")
ggsave("output/figures/fig3_team_points_left.png", p3, width = 7, height = 7.5, dpi = 200, bg = "white")
