#!/usr/bin/env bash
# Rebuilds everything from scratch: data -> SQL -> R -> validation.
# Requires: Python 3.10+ (duckdb, numpy, pandas) and R 4.x
#           (readr, dplyr, tidyr, purrr, sandwich, lmtest, ggplot2, scales)
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p data/raw data/processed output/tables output/figures output/logs

echo "[1/6] Simulating play-by-play";      python python/00_simulate_pbp.py
echo "[2/6] SQL pipeline (DuckDB)";          rm -f data/processed/nba_eoq.duckdb; python python/run_sql.py > /dev/null
echo "[3/6] R: effect estimates";            Rscript R/01_effect_models.R > output/logs/r01_effect_models.txt
echo "[4/6] R: timing + team ledger";        Rscript R/02_when_it_works.R > output/logs/r02_when_it_works.txt
                                             Rscript R/03_team_value.R    > output/logs/r03_team_value.txt
echo "[5/6] Ground-truth validation";        python python/99_ground_truth.py > output/logs/ground_truth.txt
echo "[6/6] Building report";                python python/build_report.py
echo "Done. Logs in output/logs, tables in output/tables, figures in output/figures."
