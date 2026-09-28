-- =====================================================================
-- 02_possessions.sql  ·  Rebuild possessions from raw events
--
-- A possession changes whenever the ball-owning team changes between
-- consecutive events (offensive rebounds therefore extend a possession).
-- The possession *start* is the event that handed the ball over:
--   * a defensive rebound            -> that rebound's clock
--   * otherwise (make / TOV / last FT)-> previous possession's last event
-- =====================================================================

CREATE OR REPLACE TABLE possessions AS
WITH ev AS (
    SELECT *,
           LAG(ball_team_id) OVER w AS prev_ball_team
    FROM pbp
    WHERE action_type <> 'period'
    WINDOW w AS (PARTITION BY game_id, period ORDER BY action_number)
),
numbered AS (
    SELECT *,
           SUM(CASE WHEN prev_ball_team IS NULL
                      OR ball_team_id <> prev_ball_team THEN 1 ELSE 0 END)
               OVER (PARTITION BY game_id, period ORDER BY action_number
                     ROWS UNBOUNDED PRECEDING)                         AS poss_seq
    FROM ev
),
agg AS (
    SELECT
        game_id, season, period, poss_seq,
        ANY_VALUE(ball_team_id)                     AS team_id,
        ANY_VALUE(home_team_id)                     AS home_team_id,
        ANY_VALUE(away_team_id)                     AS away_team_id,
        -- first event of the possession
        arg_min(action_type, action_number)         AS first_type,
        arg_min(sub_type,    action_number)         AS first_sub,
        arg_min(sec_left,    action_number)         AS first_sec,
        arg_min(score_home,  action_number)         AS first_sh,
        arg_min(score_away,  action_number)         AS first_sa,
        -- last event of the possession
        arg_max(action_type, action_number)         AS last_type,
        arg_max(sub_type,    action_number)         AS last_sub,
        arg_max(shot_result, action_number)         AS last_result,
        arg_max(sec_left,    action_number)         AS last_sec,
        arg_max(score_home,  action_number)         AS last_sh,
        arg_max(score_away,  action_number)         AS last_sa,
        -- first "shot decision": FGA, turnover, or drawing a shooting foul
        MAX(sec_left) FILTER (
            WHERE action_type IN ('Made Shot', 'Missed Shot', 'Turnover')
               OR (action_type = 'Foul' AND sub_type ILIKE '%shooting%')
        )                                           AS first_decision_sec,
        COUNT(*) FILTER (WHERE action_type = 'Rebound'
                           AND sub_type = 'Offensive') AS orebs
    FROM numbered
    GROUP BY game_id, season, period, poss_seq
)
SELECT
    a.*,
    CASE WHEN a.home_team_id = a.team_id THEN a.away_team_id
         ELSE a.home_team_id END                                        AS opp_team_id,
    -- when did this team gain the ball?
    CASE WHEN a.first_type = 'Rebound' AND a.first_sub = 'Defensive'
         THEN a.first_sec
         ELSE LAG(a.last_sec) OVER wp END                               AS start_sec,
    -- how did it gain the ball?
    CASE
        WHEN a.first_type = 'Rebound' AND a.first_sub = 'Defensive'      THEN 'DREB'
        WHEN LAG(a.last_type) OVER wp = 'Made Shot'
          OR (LAG(a.last_type) OVER wp = 'Free Throw'
              AND LAG(a.last_result) OVER wp = 'Made')                  THEN 'MADE_BASKET'
        WHEN LAG(a.last_type) OVER wp = 'Turnover'
          AND LAG(a.last_sub) OVER wp IN ('Bad Pass', 'Lost Ball')       THEN 'LIVE_TOV'
        WHEN LAG(a.last_type) OVER wp = 'Turnover'                       THEN 'DEAD_BALL'
        ELSE 'UNKNOWN'
    END                                                                 AS start_type,
    -- score at the moment possession was gained
    CASE WHEN a.first_type = 'Rebound' AND a.first_sub = 'Defensive'
         THEN a.first_sh ELSE LAG(a.last_sh) OVER wp END                AS start_sh,
    CASE WHEN a.first_type = 'Rebound' AND a.first_sub = 'Defensive'
         THEN a.first_sa ELSE LAG(a.last_sa) OVER wp END                AS start_sa
FROM agg a
WINDOW wp AS (PARTITION BY a.game_id, a.period ORDER BY a.poss_seq);

-- sanity: possession counts and points per possession by start type
SELECT
    start_type,
    COUNT(*)                                                     AS possessions,
    ROUND(AVG(CASE WHEN team_id = home_team_id THEN last_sh - start_sh
                   ELSE last_sa - start_sa END), 3)              AS pts_per_poss
FROM possessions
WHERE start_sec IS NOT NULL
GROUP BY start_type
ORDER BY possessions DESC;
