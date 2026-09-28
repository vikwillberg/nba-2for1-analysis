"""
build_report.py  ·  Fills report/template.html with the numbers in output/tables
and excerpts of the real SQL / R files, so the write-up can't drift from the code.

    python python/build_report.py   ->  report/the_2for1_ledger.html
"""
import html
import json
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
T = ROOT / "output" / "tables"


def excerpt(path, start_marker, end_marker, include_end=True):
    text = (ROOT / path).read_text()
    a = text.index(start_marker)
    b = text.index(end_marker, a) + (len(end_marker) if include_end else 0)
    return text[a:b]


def table_html(df, cls="mono"):
    head = "".join(f"<th>{html.escape(str(c))}</th>" for c in df.columns)
    rows = "".join("<tr>" + "".join(f"<td>{html.escape(str(v))}</td>" for v in r) + "</tr>"
                   for r in df.itertuples(index=False))
    return f'<table class="{cls}"><thead><tr>{head}</tr></thead><tbody>{rows}</tbody></table>'


def main():
    est = pd.read_csv(T / "effect_estimates.csv")
    buckets = pd.read_csv(T / "effect_by_start_bucket.csv")
    truth = pd.read_csv(T / "ground_truth.csv")
    teams = pd.read_csv(T / "team_value.csv")
    w = pd.read_csv(ROOT / "data" / "processed" / "eoq_windows.csv")

    att = w[(w.went_2for1 == 1) & (w.start_sec >= 37)].copy()
    att["bin"] = pd.cut(att.first_shot_sec, [28, 31, 34, 37, 46], right=False,
                        labels=["0:28–0:31", "0:31–0:34", "0:34–0:37", "0:37+"])
    timing = (att.groupby("bin", observed=True)
                 .agg(n=("net_pts", "size"), net=("net_pts", "mean"),
                      counter=("opp_got_second_poss", "mean"), second=("got_second_poss", "mean"))
                 .reset_index())

    t_all = truth[truth.start_bucket == "ALL"].iloc[0]
    data = {
        "estimates": est[["method", "estimate", "ci_low", "ci_high"]].to_dict("records"),
        "truth": {
            "all": {"true_effect": float(t_all.true_effect), "se": float(t_all.se)},
            "byBucket": {r.start_bucket: float(r.true_effect)
                         for r in truth[truth.start_bucket != "ALL"].itertuples()},
        },
        "buckets": buckets[["start_bucket", "windows", "go_rate", "effect", "ci_low",
                            "ci_high", "p_value"]].round(4).to_dict("records"),
        "timing": [{"bin": str(r.bin), "n": int(r.n), "net": round(r.net, 3),
                    "counter": round(r.counter, 3), "second": round(r.second, 3)}
                   for r in timing.itertuples()],
        "teams": [{"team": r.team_tricode, "rank": int(r.rank), "go_rate": round(r.go_rate, 3),
                   "too_early_rate": round(r.too_early_rate, 3), "pass": round(r.pts_left_pass, 2),
                   "early": round(r.pts_left_early, 2), "total": round(r.pts_left_per_season, 2),
                   "wins": round(r.wins_left_per_season, 3)}
                  for r in teams.sort_values("rank").itertuples()],
    }

    sql_ex = (excerpt("sql/02_possessions.sql", "CREATE OR REPLACE TABLE possessions AS", "    FROM ev\n),")
              + "\n-- ... aggregate first / last event of each possession (agg CTE) ...\n\n"
              + excerpt("sql/02_possessions.sql", "    -- when did this team gain the ball?", "AS start_type,"))
    r_ipw = (excerpt("R/01_effect_models.R", "f_ols <- ", "cluster = ~game_id))")
             + "\n\n" + excerpt("R/01_effect_models.R", "f_ps <- ", "\n}\n")
             + "\n" + excerpt("R/01_effect_models.R", "boot    <- replicate", "})"))
    log = (ROOT / "output" / "logs" / "r01_effect_models.txt").read_text()
    r_summary = log[log.index("IPW ATE"):].strip()
    r_summary = "\n".join(l for l in r_summary.splitlines() if l.strip())
    r_summary = r_summary.replace("== Summary ==", "\n== Summary ==")

    summ = pd.read_csv(T / "sql_summary.csv")
    team_tbl = teams.sort_values("rank")[["rank", "team_tricode", "go_rate", "too_early_rate",
                                          "pts_left_pass", "pts_left_early",
                                          "pts_left_per_season", "wins_left_per_season"]].copy()
    team_tbl.columns = ["Rank", "Team", "Go rate (0:33+)", "Too-early rate", "Pts: passed",
                        "Pts: too early", "Pts per season", "Wins per season"]
    for c in ["Go rate (0:33+)", "Too-early rate"]:
        team_tbl[c] = (team_tbl[c] * 100).round(0).astype(int).astype(str) + "%"
    for c in ["Pts: passed", "Pts: too early", "Pts per season"]:
        team_tbl[c] = team_tbl[c].map(lambda v: f"{v:.1f}")
    team_tbl["Wins per season"] = team_tbl["Wins per season"].map(lambda v: f"{v:.2f}")

    tree = """├── run_all.sh
├── python/
│   ├── 00_simulate_pbp.py
│   ├── run_sql.py
│   ├── 99_ground_truth.py
│   └── build_report.py
├── sql/
│   ├── 01_stage.sql
│   ├── 02_possessions.sql
│   ├── 03_windows.sql
│   └── 04_descriptives.sql
├── R/
│   ├── 01_effect_models.R
│   ├── 02_when_it_works.R
│   └── 03_team_value.R
├── data/  raw/ + processed/
├── output/ tables/ figures/ logs/
└── report/the_2for1_ledger.html"""

    page = (ROOT / "report" / "template.html").read_text()
    fills = {
        "{{DATA_JSON}}": json.dumps(data, ensure_ascii=False),
        "{{SQL_EXCERPT}}": html.escape(sql_ex),
        "{{R_IPW}}": html.escape(r_ipw),
        "{{R_SUMMARY}}": html.escape(r_summary),
        "{{SQL_SUMMARY_TABLE}}": table_html(summ),
        "{{TEAM_TABLE}}": table_html(team_tbl, cls=""),
        "{{TREE}}": html.escape(tree),
    }
    for k, v in fills.items():
        assert k in page, k
        page = page.replace(k, v)
    out = ROOT / "report" / "the_2for1_ledger.html"
    out.write_text(page)
    print(f"wrote {out.relative_to(ROOT)} ({len(page) / 1024:.0f} KB)")


if __name__ == "__main__":
    main()
