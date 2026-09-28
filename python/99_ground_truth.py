"""
99_ground_truth.py  ·  Validation: what is the TRUE effect in the simulated league?

Because the data is simulated, every window can be replayed twice with the
same teams, clock and start type: once forcing a 2-for-1 and once forcing a
normal possession whose first shot comes after 0:28. The average difference
is the true effect the R models are trying to recover.

    python python/99_ground_truth.py      ->  output/tables/ground_truth.csv
"""
import importlib.util
import re
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("sim", ROOT / "python" / "00_simulate_pbp.py")
sim = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sim)
natural_decision = sim.wants_2for1

START_MAP = {"DREB": "DREB", "MADE_BASKET": "MADE_FG",
             "LIVE_TOV": "LIVE_TOV", "DEAD_BALL": "DEAD_BALL"}
N_WINDOWS, REPS = 6000, 20


def secs(iso):
    m = re.match(r"PT(\d+)M([\d.]+)S", iso)
    return int(m[1]) * 60 + float(m[2])


def replay(season, team, opp, period, clock, start, go):
    """Net points for `team` from `clock` to the buzzer under a forced decision."""
    while True:
        seg = sim.Segment(season, "replay", period, team, opp, 50, 50)
        first = {"call": True}

        def forced(s, t, c, st, p):
            if first["call"]:
                first["call"] = False
                return go
            return natural_decision(s, t, c, st, p)

        sim.wants_2for1 = forced
        off, c, st, shot_clock = team, clock, start, 24.0
        while c > 0:
            res = seg.possession(c, off, st, shot_clock, oreb=(st == "OREB"))
            if res is None:
                break
            c, off, st = res
            shot_clock = 14.0 if st == "OREB" else 24.0
        first_shot = secs(seg.rows[0][3]) if seg.rows else 0.0
        if not go and first_shot >= 28.0:
            continue                      # keep only true "did not go" replays
        return seg.sh - seg.sa


def main():
    w = pd.read_csv(ROOT / "data" / "processed" / "eoq_windows.csv").sort_values(["game_id", "period"]).reset_index(drop=True)
    sample = w.sample(N_WINDOWS, random_state=1)
    rows = []
    for r in sample.itertuples():
        if r.start_sec < 31.0:            # 2-for-1 not physically available
            rows.append((r.start_bucket, 0.0))
            continue
        args = (r.season, r.team_id, r.opp_team_id, r.period, r.start_sec, START_MAP[r.start_type])
        go = np.mean([replay(*args, go=True) for _ in range(REPS)])
        no = np.mean([replay(*args, go=False) for _ in range(REPS)])
        rows.append((r.start_bucket, go - no))
    sim.wants_2for1 = natural_decision

    d = pd.DataFrame(rows, columns=["start_bucket", "effect"])
    overall = pd.DataFrame({"start_bucket": ["ALL"], "true_effect": [d.effect.mean()],
                            "se": [d.effect.std() / np.sqrt(len(d))], "windows": [len(d)]})
    by_b = d.groupby("start_bucket").effect.agg(["mean", "std", "count"]).reset_index()
    by_b = pd.DataFrame({"start_bucket": by_b.start_bucket, "true_effect": by_b["mean"],
                         "se": by_b["std"] / np.sqrt(by_b["count"]), "windows": by_b["count"]})
    out = pd.concat([overall, by_b]).round(4)
    out.to_csv(ROOT / "output" / "tables" / "ground_truth.csv", index=False)
    print(out.to_string(index=False))


if __name__ == "__main__":
    main()
