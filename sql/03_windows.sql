-- =====================================================================
-- 03_windows.sql  ·  One row per 2-for-1 opportunity ("window")
--
-- Window  = first possession in Q1–Q3 that a team gains with 0:30–0:45
--           left on the game clock.
-- Treated = team's first shot decision (FGA / TOV / shooting foul drawn)
--           happened with >= 0:28 left, i.e. early enough to get the ball
--           back after the opponent uses a full 24-second clock.
-- Outcome = team points minus opponent points from window start to the
--           end of the quarter.
-- =====================================================================

CREATE OR REPLACE TABLE eoq_windows AS
WITH candidates AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY game_id, period
                              ORDER BY poss_seq)                 AS rn
    FROM possessions
    WHERE period IN (1, 2, 3)
      AND start_sec BETWEEN 30.0 AND 45.0
),
win AS (
    SELECT * FROM candidates WHERE rn = 1
),
period_end AS (
    SELECT game_id, period,
           arg_max(score_home, action_number) AS end_sh,
           arg_max(score_away, action_number) AS end_sa
    FROM pbp
    GROUP BY game_id, period
),
rest_of_quarter AS (
    -- "real" possessions only: gained with >= 3.0 s left (excludes heaves)
    SELECT w.game_id, w.period,
           COUNT(*) FILTER (WHERE p.team_id =  w.team_id
                              AND p.start_sec >= 3.0)     AS team_poss,
           COUNT(*) FILTER (WHERE p.team_id <> w.team_id
                              AND p.start_sec >= 3.0)     AS opp_poss
    FROM win w
    JOIN possessions p
      ON p.game_id = w.game_id
     AND p.period  = w.period
     AND p.poss_seq >= w.poss_seq
    GROUP BY w.game_id, w.period
)
SELECT
    w.game_id,
    w.season,
    w.period,
    w.team_id,
    w.opp_team_id,
    (w.team_id = w.home_team_id)::INTEGER                           AS is_home,
    w.start_sec,
    w.start_type,
    CASE WHEN w.start_sec >= 42 THEN '42-45'
         WHEN w.start_sec >= 39 THEN '39-42'
         WHEN w.start_sec >= 36 THEN '36-39'
         WHEN w.start_sec >= 33 THEN '33-36'
         ELSE '30-33' END                                          AS start_bucket,
    COALESCE(w.first_decision_sec, 0)                              AS first_shot_sec,
    (COALESCE(w.first_decision_sec, 0) >= 28.0)::INTEGER           AS went_2for1,
    -- score state at window start, from the team's perspective
    CASE WHEN w.team_id = w.home_team_id THEN w.start_sh - w.start_sa
         ELSE w.start_sa - w.start_sh END                          AS margin_start,
    -- outcome
    CASE WHEN w.team_id = w.home_team_id THEN e.end_sh - w.start_sh
         ELSE e.end_sa - w.start_sa END                            AS team_pts,
    CASE WHEN w.team_id = w.home_team_id THEN e.end_sa - w.start_sa
         ELSE e.end_sh - w.start_sh END                            AS opp_pts,
    r.team_poss,
    r.opp_poss,
    (r.team_poss >= 2)::INTEGER                                    AS got_second_poss,
    (r.opp_poss  >= 2)::INTEGER                                    AS opp_got_second_poss,
    tr.off_rtg                                                     AS team_off_rtg,
    orr.def_rtg                                                    AS opp_def_rtg
FROM win w
JOIN period_end          e   ON e.game_id = w.game_id AND e.period = w.period
JOIN rest_of_quarter     r   ON r.game_id = w.game_id AND r.period = w.period
JOIN team_season_ratings tr  ON tr.season = w.season AND tr.team_id  = w.team_id
JOIN team_season_ratings orr ON orr.season = w.season AND orr.team_id = w.opp_team_id
ORDER BY w.game_id, w.period;

ALTER TABLE eoq_windows ADD COLUMN net_pts INTEGER;
UPDATE eoq_windows SET net_pts = team_pts - opp_pts;

-- explicit ORDER BY: DuckDB is multithreaded, so row order is not guaranteed otherwise
COPY (SELECT * FROM eoq_windows ORDER BY game_id, period)
  TO 'data/processed/eoq_windows.csv' (HEADER, DELIMITER ',');

-- coverage check: how many quarters produced an eligible window?
SELECT
    COUNT(*)                                                      AS windows,
    ROUND(COUNT(*) / (SELECT COUNT(DISTINCT game_id || '-' || period)
                      FROM pbp)::DOUBLE, 3)                       AS share_of_quarters,
    ROUND(AVG(went_2for1), 3)                                     AS went_2for1_rate
FROM eoq_windows;
