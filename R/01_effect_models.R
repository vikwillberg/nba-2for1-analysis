# =====================================================================
# 01_effect_models.R  ·  How many points is a 2-for-1 actually worth?
#
# Input : data/processed/eoq_windows.csv   (built by sql/03_windows.sql)
# Output: output/tables/effect_estimates.csv
#
# Three estimators of the same quantity - the change in end-of-quarter
# net points from going 2-for-1 - moving from naive to causal:
#   (1) naive difference in means
#   (2) regression adjustment (OLS, SEs clustered by game)
#   (3) inverse-propensity weighting (ATE, cluster bootstrap CI)
# =====================================================================
suppressPackageStartupMessages({
  library(readr); library(dplyr); library(sandwich); library(lmtest); library(splines)
})
set.seed(2026)

w <- read_csv("data/processed/eoq_windows.csv", show_col_types = FALSE) |>
  arrange(game_id, period) |>
  mutate(
    start_type   = factor(start_type, levels = c("DREB", "MADE_BASKET", "LIVE_TOV", "DEAD_BALL")),
    start_bucket = factor(start_bucket),
    period       = factor(period),
    season       = factor(season),
    margin_c     = pmin(pmax(margin_start, -20), 20)      # cap blowouts
  )

cat(sprintf("Windows: %s | went 2-for-1: %.1f%%\n\n",
            format(nrow(w), big.mark = ","), 100 * mean(w$went_2for1)))

# --- (1) naive ----------------------------------------------------------
m_naive <- lm(net_pts ~ went_2for1, data = w)
ct_naive <- coeftest(m_naive, vcov = vcovCL(m_naive, cluster = ~game_id))
cat("== (1) Naive difference in means ==\n"); print(ct_naive)

# --- (2) regression adjustment -----------------------------------------
f_ols <- net_pts ~ went_2for1 + start_bucket + start_type + period + season +
                   team_off_rtg + opp_def_rtg + margin_c + is_home
m_ols <- lm(f_ols, data = w)
ct_ols <- coeftest(m_ols, vcov = vcovCL(m_ols, cluster = ~game_id))
cat("\n== (2) OLS with controls, SEs clustered by game ==\n"); print(ct_ols)

# --- (3) inverse propensity weighting ------------------------------------
f_ps <- went_2for1 ~ ns(start_sec, df = 4) + start_type + period + season +
                     team_off_rtg + opp_def_rtg + margin_c + is_home

ipw_ate <- function(d) {
  ps <- predict(glm(f_ps, family = binomial, data = d), type = "response")
  ps <- pmin(pmax(ps, 0.05), 0.95)                     # trim for overlap
  p1 <- mean(d$went_2for1)
  sw <- ifelse(d$went_2for1 == 1, p1 / ps, (1 - p1) / (1 - ps))  # stabilized
  weighted.mean(d$net_pts[d$went_2for1 == 1], sw[d$went_2for1 == 1]) -
    weighted.mean(d$net_pts[d$went_2for1 == 0], sw[d$went_2for1 == 0])
}

ps_fit <- glm(f_ps, family = binomial, data = w)
w$ps <- predict(ps_fit, type = "response")
cat("\n== (3) Propensity model: share of windows inside [0.05, 0.95] ==\n")
cat(sprintf("%.1f%%\n", 100 * mean(w$ps >= 0.05 & w$ps <= 0.95)))

ate_ipw <- ipw_ate(w)
games   <- unique(w$game_id)
idx     <- split(seq_len(nrow(w)), w$game_id)
boot    <- replicate(500, {
  g <- sample(games, length(games), replace = TRUE)
  ipw_ate(w[unlist(idx[g], use.names = FALSE), ])
})
ci_ipw <- quantile(boot, c(0.025, 0.975))
cat(sprintf("IPW ATE = %.3f  (95%% cluster-bootstrap CI %.3f to %.3f, B = 500)\n",
            ate_ipw, ci_ipw[1], ci_ipw[2]))

# --- collect ------------------------------------------------------------
row_from <- function(label, ct) {
  est <- ct["went_2for1", "Estimate"]; se <- ct["went_2for1", "Std. Error"]
  tibble(method = label, estimate = est, se = se,
         ci_low = est - 1.96 * se, ci_high = est + 1.96 * se,
         p_value = ct["went_2for1", "Pr(>|t|)"])
}
out <- bind_rows(
  row_from("Naive difference", ct_naive),
  row_from("OLS + controls", ct_ols),
  tibble(method = "Inverse propensity weighting", estimate = ate_ipw, se = sd(boot),
         ci_low = ci_ipw[[1]], ci_high = ci_ipw[[2]],
         p_value = 2 * pnorm(-abs(ate_ipw / sd(boot))))
) |> mutate(across(where(is.numeric), \(x) round(x, 4)))

cat("\n== Summary ==\n"); print(as.data.frame(out))
write_csv(out, "output/tables/effect_estimates.csv")
