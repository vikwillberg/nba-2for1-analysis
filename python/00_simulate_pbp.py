"""
00_simulate_pbp.py
------------------
Generates SYNTHETIC end-of-quarter play-by-play for 3 NBA-style seasons.

Why synthetic: this project demonstrates the method end to end. The output
schema mirrors the NBA Stats PlayByPlayV3 feed (clock as ISO-8601 duration,
actionType / subType, running scoreHome / scoreAway), so a real pull from
nba_api needs only the light cleaning listed in README -> "Using real data"
before the SQL and R steps run.

The simulator has a known ground truth: going 2-for-1 is worth roughly
+0.15 to +0.20 net points when possession is gained with 0:32-0:45 left and
about zero below that. The analysis never sees these parameters; recovering
them from the event log is the test of the method.

Scope: the last ~75 seconds of Q1, Q2 and Q3 of every game.
Q4/OT are excluded because intentional fouling and score-state distort them.

Output (data/raw/):
    teams.csv, games.csv, team_season_ratings.csv, pbp_eoq.csv.gz
"""
from __future__ import annotations

import csv
import gzip
import math
from datetime import date, timedelta
from pathlib import Path

import numpy as np

SEED = 2026
rng = np.random.default_rng(SEED)
OUT = Path(__file__).resolve().parents[1] / "data" / "raw"
OUT.mkdir(parents=True, exist_ok=True)

SEASONS = {"2022-23": 22, "2023-24": 23, "2024-25": 24}
N_TEAMS = 30

# ---------------------------------------------------------------- teams ---
# Latent (unobserved) team traits. Only season ratings are exported.
team_ids = list(range(1, N_TEAMS + 1))
tricode = {t: f"T{t:02d}" for t in team_ids}
z = rng.normal(size=N_TEAMS)
off_q0 = rng.normal(0, 0.035, N_TEAMS)          # shooting quality multiplier
def_q0 = rng.normal(0, 0.035, N_TEAMS)          # defensive quality multiplier
# 2-for-1 aggressiveness (coaching tendency), mildly correlated with offense
prop0 = 0.15 + 0.60 * z + 4.0 * off_q0

traits = {}   # (season, team) -> dict
for s in SEASONS:
    for i, t in enumerate(team_ids):
        traits[(s, t)] = dict(
            off=off_q0[i] + rng.normal(0, 0.012),
            dfn=def_q0[i] + rng.normal(0, 0.012),
            prop=prop0[i] + rng.normal(0, 0.30),   # coaching changes drift
        )

# ------------------------------------------------------------- helpers ---
def iso_clock(sec: float) -> str:
    sec = max(0.0, round(sec, 1))
    m = int(sec // 60)
    s = sec - 60 * m
    return f"PT{m:02d}M{s:05.2f}S"


def sigmoid(x: float) -> float:
    return 1.0 / (1.0 + math.exp(-x))


def rush_factor(used: float, transition: bool) -> float:
    """Shot-quality multiplier for how fast the possession was forced."""
    if transition:
        return 1.10 if used < 8 else 1.0
    if used < 3:
        return 0.62
    if used < 5:
        return 0.78
    if used < 7:
        return 0.90
    if used < 10:
        return 0.96
    return 1.0


def rush_tov(used: float, transition: bool) -> float:
    if transition:
        return 0.0
    return 0.05 if used < 3 else (0.03 if used < 5 else 0.0)


def wants_2for1(season: str, team: int, c: float, start: str, period: int) -> bool:
    p = sigmoid(traits[(season, team)]["prop"] + 0.28 * (c - 37.0)
                + (0.9 if start == "LIVE_TOV" else 0.0)
                - (0.15 if period == 1 else 0.0))
    return rng.random() < p


# ------------------------------------------------------------ simulator ---
class Segment:
    """Simulates one end-of-period segment and records PBP rows."""

    def __init__(self, season, game_id, period, home, away, score_h, score_a):
        self.season, self.game_id, self.period = season, game_id, period
        self.home, self.away = home, away
        self.sh, self.sa = score_h, score_a
        self.rows = []
        self.action = 0

    def other(self, t):
        return self.away if t == self.home else self.home

    def add_pts(self, team, pts):
        if team == self.home:
            self.sh += pts
        else:
            self.sa += pts

    def emit(self, clock, team, action_type, sub_type, shot_value=None,
             shot_result=None, desc=""):
        self.action += 1
        self.rows.append([
            self.game_id, self.action, self.period, iso_clock(clock),
            team if team else "", tricode.get(team, ""), action_type,
            sub_type, shot_value if shot_value is not None else "",
            shot_result or "", self.sh, self.sa, desc,
        ])

    # ---- one possession (may include offensive-rebound continuations) ---
    def possession(self, c, off, start, shot_clock=24.0, oreb=False):
        """Returns (next_clock, next_offense, next_start) or None at period end."""
        dfn = self.other(off)
        tr_o = traits[(self.season, off)]
        tr_d = traits[(self.season, dfn)]
        q = (1 + tr_o["off"]) * (1 - tr_d["dfn"])
        transition = (start == "LIVE_TOV") and not oreb

        # ---------------- choose mode and shot time T -------------------
        if c < 2.0:
            mode = "heave"
            if rng.random() > 0.85:          # no shot gets off
                return None
            T = max(0.0, c - rng.uniform(0.3, max(0.35, c)))
        elif c < 4.5:
            mode = "quick"
            T = max(0.0, c - rng.uniform(0.8, c - 0.3))
        elif c <= shot_clock:                # shot clock off -> last shot
            mode = "last_shot"
            T = rng.uniform(0.8, 4.0) if c > 7 else c - rng.uniform(2.0, c - 0.5)
        elif oreb:
            mode = "putback"
            d = float(np.clip(rng.normal(4.0, 3.0), 1.0, shot_clock - 0.5))
            T = c - d
        elif 31.0 <= c <= 46.0 and wants_2for1(self.season, off, c, start, self.period):
            mode = "2for1"
            if c <= 38 or rng.random() < 0.75:
                T = rng.uniform(28.3, min(c - 1.5, 35.0))
            else:                            # the "too early" 2-for-1
                T = rng.uniform(35.0, c - 1.5)
        elif 24.0 < c <= 31.0 and rng.random() < 0.55:
            mode = "hold"                    # burn the clock vs a 2-for-1
            d = rng.uniform(19.0, min(23.5, c - 1.0))
            T = c - d
        else:
            mode = "normal"
            mu = 8.0 if transition else 14.5
            d = float(np.clip(rng.normal(mu, 4.0), 3.0 if transition else 5.0,
                              min(shot_clock - 0.5, 23.5)))
            T = c - d
        T = round(max(0.0, T), 1)
        used = c - T

        # ---------------- outcome probabilities ------------------------
        p_tov, p_foul, p3 = 0.125, 0.085, 0.40
        m2, m3 = 0.55, 0.365
        f = q
        if mode in ("2for1", "normal", "hold"):
            f *= rush_factor(used, transition)
            p_tov += rush_tov(used, transition)
            if mode == "2for1":
                p3 = 0.45
            if transition:
                p3 = 0.35
        elif mode == "putback":
            f *= 1.12; p3 = 0.25; p_tov = 0.07
        elif mode == "last_shot":
            f *= 0.86 if c < 8 else 0.90; p3 = 0.42; p_tov = 0.09
        elif mode == "quick":                # 2.0-4.5 s: rushed catch-and-fire
            f *= 0.25 + 0.06 * (c - 2.0); p3 = 0.55; p_tov = 0.08; p_foul = 0.04
        elif mode == "heave":                # < 2 s: mostly backcourt heaves
            p_tov, p_foul, p3 = 0.0, 0.01, 1.0
            m3 = 0.03 if c < 1.0 else 0.06
            f = 1.0
        m2 *= f
        m3 *= f

        u = rng.random()
        # ---------------- turnover -------------------------------------
        if u < p_tov:
            live = rng.random() < 0.55
            sub = rng.choice(["Bad Pass", "Lost Ball"]) if live else \
                rng.choice(["Out of Bounds", "Traveling", "Offensive Foul"])
            self.emit(T, off, "Turnover", sub, desc=f"{tricode[off]} {sub} Turnover")
            if T <= 0.2:
                return None
            return (T, dfn, "LIVE_TOV" if live else "DEAD_BALL")

        # ---------------- shooting foul -> FTs --------------------------
        if u < p_tov + p_foul:
            self.emit(T, dfn, "Foul", "Shooting", desc=f"{tricode[dfn]} Shooting Foul")
            made_last = False
            for k in (1, 2):
                made = rng.random() < 0.78
                if made:
                    self.add_pts(off, 1)
                self.emit(T, off, "Free Throw", f"Free Throw {k} of 2", 1,
                          "Made" if made else "Missed",
                          f"{tricode[off]} Free Throw {k} of 2 ({'MADE' if made else 'MISS'})")
                made_last = made
            if made_last:
                return (T, dfn, "MADE_FG")
            return self.rebound(T, off, dfn, ft=True)

        # ---------------- field goal attempt ---------------------------
        val = 3 if rng.random() < p3 else 2
        made = rng.random() < (m3 if val == 3 else m2)
        kind = rng.choice(["Jump Shot", "Pullup Jump Shot", "Step Back Jump Shot"]) if val == 3 \
            else rng.choice(["Layup", "Driving Layup", "Jump Shot", "Dunk", "Floating Jump Shot"])
        if made:
            self.add_pts(off, val)
            self.emit(T, off, "Made Shot", kind, val, "Made",
                      f"{tricode[off]} {val}PT {kind} ({val} PTS)")
            if rng.random() < 0.025:             # and-one
                self.emit(T, dfn, "Foul", "Shooting", desc=f"{tricode[dfn]} Shooting Foul")
                ft = rng.random() < 0.78
                if ft:
                    self.add_pts(off, 1)
                self.emit(T, off, "Free Throw", "Free Throw 1 of 1", 1,
                          "Made" if ft else "Missed",
                          f"{tricode[off]} Free Throw 1 of 1 ({'MADE' if ft else 'MISS'})")
                if not ft:
                    return self.rebound(T, off, dfn, ft=True)
            # Q1-Q3: game clock keeps running through the inbound
            nxt = round(T - rng.uniform(1.0, 2.5), 1)
            if nxt <= 0.1:
                return None
            return (nxt, dfn, "MADE_FG")
        self.emit(T, off, "Missed Shot", kind, val, "Missed",
                  f"MISS {tricode[off]} {val}PT {kind}")
        return self.rebound(T, off, dfn, ft=False)

    def rebound(self, T, off, dfn, ft):
        R = round(T - rng.uniform(0.5, 2.0), 1)
        if R <= 0.0:
            return None
        if rng.random() < (0.15 if ft else 0.24):
            self.emit(R, off, "Rebound", "Offensive", desc=f"{tricode[off]} Offensive Rebound")
            return (R, off, "OREB")
        self.emit(R, dfn, "Rebound", "Defensive", desc=f"{tricode[dfn]} Defensive Rebound")
        return (R, dfn, "DREB")

    def run(self):
        c = round(rng.uniform(62.0, 75.0), 1)
        off = self.home if rng.random() < 0.5 else self.away
        dfn = self.other(off)
        # seed event that hands `off` the ball
        start = rng.choice(["DREB", "MADE_FG", "LIVE_TOV", "DEAD_BALL"], p=[0.50, 0.33, 0.10, 0.07])
        if start == "DREB":
            self.emit(c + 1.2, dfn, "Missed Shot", "Jump Shot", 2, "Missed", f"MISS {tricode[dfn]} 2PT Jump Shot")
            self.emit(c, off, "Rebound", "Defensive", desc=f"{tricode[off]} Defensive Rebound")
        elif start == "MADE_FG":
            self.add_pts(dfn, 2)
            self.emit(c, dfn, "Made Shot", "Layup", 2, "Made", f"{tricode[dfn]} 2PT Layup (2 PTS)")
        elif start == "LIVE_TOV":
            self.emit(c, dfn, "Turnover", "Bad Pass", desc=f"{tricode[dfn]} Bad Pass Turnover")
        else:
            self.emit(c, dfn, "Turnover", "Out of Bounds", desc=f"{tricode[dfn]} Out of Bounds Turnover")

        shot_clock = 24.0
        while c > 0:
            res = self.possession(c, off, start, shot_clock, oreb=(start == "OREB"))
            if res is None:
                break
            c, off, start = res
            shot_clock = 14.0 if start == "OREB" else 24.0
        self.emit(0.0, None, "period", "end", desc=f"End of Q{self.period}")
        return self.rows


# ------------------------------------------------------------- schedule ---
def build_schedule(season, yy):
    games = []
    for t in team_ids:
        opps = [o for o in team_ids if o != t]
        opps += list(rng.choice(opps, size=12, replace=False))
        games += [(t, o) for o in opps]          # (home, away)
    rng.shuffle(games)
    start = date(2000 + yy, 10, 18)
    out = []
    for i, (h, a) in enumerate(games, start=1):
        gdate = start + timedelta(days=int(i * 172 / len(games)))
        out.append((f"002{yy:02d}{i:05d}", season, gdate.isoformat(), h, a))
    return out


def main():
    with open(OUT / "teams.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["team_id", "team_tricode", "team_name"])
        for t in team_ids:
            w.writerow([t, tricode[t], f"Team {t:02d}"])

    with open(OUT / "team_season_ratings.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["season", "team_id", "off_rtg", "def_rtg"])
        for s in SEASONS:
            for t in team_ids:
                tr = traits[(s, t)]
                w.writerow([s, t,
                            round(114.8 + 118 * tr["off"] + rng.normal(0, 0.8), 1),
                            round(114.8 - 118 * tr["dfn"] + rng.normal(0, 0.8), 1)])

    gf = open(OUT / "games.csv", "w", newline="")
    pf = gzip.open(OUT / "pbp_eoq.csv.gz", "wt", newline="")
    gw, pw = csv.writer(gf), csv.writer(pf)
    gw.writerow(["game_id", "season", "game_date", "home_team_id", "away_team_id"])
    pw.writerow(["game_id", "action_number", "period", "clock", "team_id", "team_tricode",
                 "action_type", "sub_type", "shot_value", "shot_result",
                 "score_home", "score_away", "description"])
    n_rows = 0
    for s, yy in SEASONS.items():
        for gid, season, gdate, h, a in build_schedule(s, yy):
            gw.writerow([gid, season, gdate, h, a])
            sh = sa = 0
            for period in (1, 2, 3):
                sh += int(round(rng.normal(26.0, 4.0)))
                sa += int(round(rng.normal(26.0, 4.0)))
                seg = Segment(season, gid, period, h, a, sh, sa)
                rows = seg.run()
                pw.writerows(rows)
                n_rows += len(rows)
                sh, sa = seg.sh, seg.sa
    gf.close(); pf.close()
    print(f"wrote {n_rows:,} play-by-play rows")


if __name__ == "__main__":
    main()
