-- =====================================================================
-- 04_descriptives.sql  ·  Raw (unadjusted) cuts that feed the R models
-- =====================================================================

-- (a) Headline split: went 2-for-1 vs. didn't -------------------------
CREATE OR REPLACE VIEW v_summary AS
SELECT
    CASE WHEN went_2for1 = 1 THEN 'Went 2-for-1' ELSE 'Did not' END AS decision,
    COUNT(*)                                        AS windows,
    ROUND(AVG(team_pts), 3)                         AS team_pts,
    ROUND(AVG(opp_pts), 3)                          AS opp_pts,
    ROUND(AVG(net_pts), 3)                          AS net_pts,
    ROUND(AVG(got_second_poss), 3)                  AS got_2nd_poss,
    ROUND(AVG(opp_got_second_poss), 3)              AS opp_got_2nd_poss,
    ROUND(AVG((start_type = 'LIVE_TOV')::INTEGER), 3) AS share_live_tov,
    ROUND(AVG(start_sec), 1)                        AS avg_start_sec
FROM eoq_windows
GROUP BY 1
ORDER BY 1 DESC;

COPY (SELECT * FROM v_summary) TO 'output/tables/sql_summary.csv' (HEADER);
SELECT * FROM v_summary;

-- (b) By when the team gained the ball --------------------------------
CREATE OR REPLACE VIEW v_by_start AS
SELECT
    start_bucket,
    COUNT(*)                                                         AS windows,
    ROUND(AVG(went_2for1), 3)                                        AS go_rate,
    ROUND(AVG(net_pts) FILTER (WHERE went_2for1 = 1), 3)             AS net_if_go,
    ROUND(AVG(net_pts) FILTER (WHERE went_2for1 = 0), 3)             AS net_if_not,
    ROUND(AVG(net_pts) FILTER (WHERE went_2for1 = 1)
        - AVG(net_pts) FILTER (WHERE went_2for1 = 0), 3)             AS raw_diff,
    ROUND(AVG(start_sec - first_shot_sec)
          FILTER (WHERE went_2for1 = 1), 1)                          AS secs_used_if_go
FROM eoq_windows
GROUP BY start_bucket
ORDER BY start_bucket;

COPY (SELECT * FROM v_by_start) TO 'output/tables/sql_by_start_bucket.csv' (HEADER);
SELECT * FROM v_by_start;

-- (c) Among 2-for-1 attempts: does shooting too early backfire? -------
CREATE OR REPLACE VIEW v_by_shot_time AS
SELECT
    CASE WHEN first_shot_sec >= 37 THEN '4) 0:37+'
         WHEN first_shot_sec >= 34 THEN '3) 0:34-0:37'
         WHEN first_shot_sec >= 31 THEN '2) 0:31-0:34'
         ELSE                           '1) 0:28-0:31' END           AS first_shot_window,
    COUNT(*)                                                         AS attempts,
    ROUND(AVG(start_sec), 1)                                         AS avg_start_sec,
    ROUND(AVG(net_pts), 3)                                           AS net_pts,
    ROUND(AVG(got_second_poss), 3)                                   AS got_2nd_poss,
    ROUND(AVG(opp_got_second_poss), 3)                               AS opp_counter_rate
FROM eoq_windows
WHERE went_2for1 = 1
GROUP BY 1
ORDER BY 1;

COPY (SELECT * FROM v_by_shot_time) TO 'output/tables/sql_by_first_shot.csv' (HEADER);
SELECT * FROM v_by_shot_time;

-- (d) Team-season adoption in the "green zone" (ball gained at 0:33+) --
CREATE OR REPLACE VIEW v_team_adoption AS
SELECT
    w.season,
    t.team_tricode,
    COUNT(*)                                     AS green_zone_windows,
    SUM(w.went_2for1)                            AS went,
    COUNT(*) - SUM(w.went_2for1)                 AS passed,
    ROUND(AVG(w.went_2for1), 3)                  AS go_rate
FROM eoq_windows w
JOIN teams t USING (team_id)
WHERE w.start_sec >= 33
GROUP BY w.season, t.team_tricode;

COPY (SELECT * FROM v_team_adoption ORDER BY season, go_rate, team_tricode)
  TO 'output/tables/sql_team_adoption.csv' (HEADER);

SELECT season,
       ROUND(MIN(go_rate), 3)    AS lowest_team_rate,
       ROUND(MEDIAN(go_rate), 3) AS median_team_rate,
       ROUND(MAX(go_rate), 3)    AS highest_team_rate
FROM v_team_adoption
GROUP BY season
ORDER BY season;
