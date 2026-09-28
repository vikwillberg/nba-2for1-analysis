"""
run_sql.py  ·  Executes sql/*.sql in order against a local DuckDB file and
prints every result set (the printed output is saved to output/logs/sql_log.txt).

    python python/run_sql.py
"""
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parents[1]
DB = ROOT / "data" / "processed" / "nba_eoq.duckdb"


def statements(sql_text: str):
    buf = []
    for line in sql_text.splitlines():
        buf.append(line)
        if line.rstrip().endswith(";"):
            stmt = "\n".join(buf).strip()
            buf = []
            body = "\n".join(l for l in stmt.splitlines() if not l.strip().startswith("--")).strip()
            if body and body != ";":
                yield body


def main():
    import os
    os.chdir(ROOT)
    con = duckdb.connect(str(DB))
    log = []
    for f in sorted((ROOT / "sql").glob("*.sql")):
        log.append(f"\n==================== {f.name} ====================")
        for stmt in statements(f.read_text()):
            rel = con.sql(stmt)
            if rel is not None and stmt.lstrip().upper().startswith("SELECT"):
                log.append(str(rel))
    con.close()
    text = "\n".join(log)
    print(text)
    (ROOT / "output" / "logs").mkdir(parents=True, exist_ok=True)
    (ROOT / "output" / "logs" / "sql_log.txt").write_text(text)


if __name__ == "__main__":
    main()
