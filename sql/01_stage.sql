-- =====================================================================
-- 01_stage.sql  ·  Load raw CSVs, parse the game clock, tag possession owner
-- Engine: DuckDB 1.x   (run from project root: python python/run_sql.py)
-- =====================================================================

CREATE OR REPLACE TABLE teams AS
SELECT * FROM read_csv_auto('data/raw/teams.csv');

CREATE OR REPLACE TABLE games AS
SELECT * FROM read_csv_auto('data/raw/games.csv', types = {'game_id': 'VARCHAR'});

CREATE OR REPLACE TABLE team_season_ratings AS
SELECT * FROM read_csv_auto('data/raw/team_season_ratings.csv');

CREATE OR REPLACE TABLE pbp_raw AS
SELECT * FROM read_csv_auto('data/raw/pbp_eoq.csv.gz',
                            types = {'game_id': 'VARCHAR', 'team_id': 'INTEGER'});

-- ---------------------------------------------------------------------
-- pbp: one row per event, clock converted to seconds remaining, plus the
-- team that owns the ball for that event.
--   * Shots / FTs / turnovers / rebounds -> the acting team
--   * Fouls -> the team that was fouled (offense keeps the ball)
--   * 'period' markers -> NULL (excluded from possession logic)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE pbp AS
SELECT
    p.game_id,
    g.season,
    p.period,
    p.action_number,
    -- 'PT00M34.50S'  ->  34.5
    CAST(regexp_extract(p.clock, 'PT(\d+)M', 1) AS INTEGER) * 60
      + CAST(regexp_extract(p.clock, 'M([\d.]+)S', 1) AS DOUBLE)      AS sec_left,
    p.team_id,
    p.action_type,
    p.sub_type,
    p.shot_value,
    p.shot_result,
    p.score_home,
    p.score_away,
    g.home_team_id,
    g.away_team_id,
    CASE
        WHEN p.action_type = 'period' THEN NULL
        WHEN p.action_type = 'Foul'
            THEN CASE WHEN p.team_id = g.home_team_id
                      THEN g.away_team_id ELSE g.home_team_id END
        ELSE p.team_id
    END                                                               AS ball_team_id
FROM pbp_raw p
JOIN games   g USING (game_id);

-- sanity: every non-period event must have an owner
SELECT
    COUNT(*)                                                    AS events,
    COUNT(*) FILTER (WHERE ball_team_id IS NULL
                       AND action_type <> 'period')             AS orphan_events,
    COUNT(DISTINCT game_id)                                     AS games,
    MIN(sec_left)                                               AS min_sec,
    MAX(sec_left)                                               AS max_sec
FROM pbp;
