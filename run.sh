#!/usr/bin/env bash
# Bitcoin hour-of-day backtesting engine — end-to-end runner.
#
# Starts Postgres, filters the source CSVs down to the rows the strategy can ever use,
# loads them, builds the dbt project, then prints the answers to both prompt questions.
# Safe to re-run: every step either recreates its own output or is naturally idempotent.
#
# Usage: ./run.sh
# Env vars (all optional):
#   DATA_DIR — directory containing half1_BTCUSDT_1s.csv / half2_BTCUSDT_1s.csv
#              (default: this script's directory)
#   PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE — Postgres connection. Defaults match
#              docker-compose.yml. If something is already listening on PGHOST:PGPORT,
#              it's reused as-is instead of starting anything new.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DATA_DIR="${DATA_DIR:-$SCRIPT_DIR}"
HALF1="$DATA_DIR/half1_BTCUSDT_1s.csv"
HALF2="$DATA_DIR/half2_BTCUSDT_1s.csv"

PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGPASSWORD="${PGPASSWORD:-postgres}"
PGDATABASE="${PGDATABASE:-btc}"
export PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE

log() { echo; echo "==> $*"; }

for f in "$HALF1" "$HALF2"; do
  [ -f "$f" ] || { echo "Missing data file: $f (set DATA_DIR to point at the CSVs)." >&2; exit 1; }
done

postgres_port_open() { (exec 3<>"/dev/tcp/${PGHOST}/${PGPORT}") 2>/dev/null; }

# Find a local Postgres client+server install (psql/initdb/pg_ctl always ship together),
# whether or not it's on PATH — used both to talk to Postgres and, if Docker isn't
# available, to start it ourselves.
find_pg_bin() {
  if command -v psql >/dev/null 2>&1; then
    dirname "$(command -v psql)"
    return
  fi
  for d in \
    /Applications/Postgres.app/Contents/Versions/latest/bin \
    /opt/homebrew/opt/postgresql@16/bin \
    /opt/homebrew/opt/postgresql/bin \
    /usr/local/opt/postgresql@16/bin \
    /usr/local/opt/postgresql/bin \
    /usr/lib/postgresql/*/bin
  do
    [ -x "$d/psql" ] && { echo "$d"; return; }
  done
}
PG_BIN="$(find_pg_bin || true)"

# A real connectivity check against PGUSER, not just "is the port open" — a different
# Postgres instance (e.g. an already-running local dev cluster under a different role)
# can easily be squatting on the same port with incompatible credentials.
postgres_usable() {
  if [ -n "$PG_BIN" ]; then
    PGPASSWORD="$PGPASSWORD" "$PG_BIN/psql" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -c "SELECT 1" >/dev/null 2>&1
  else
    postgres_port_open
  fi
}

HAVE_DOCKER=false
if postgres_port_open; then
  if postgres_usable; then
    log "Postgres already reachable at ${PGHOST}:${PGPORT} — reusing it"
  else
    echo "A Postgres server is already listening on ${PGHOST}:${PGPORT}, but connecting as" >&2
    echo "PGUSER='$PGUSER' failed. This is a different instance than the one run.sh expects" >&2
    echo "by default (matching docker-compose.yml). Either:" >&2
    echo "  - point PGUSER/PGPASSWORD/PGDATABASE at that instance's real credentials, or" >&2
    echo "  - stop it, or set PGPORT to a free port, so run.sh can start its own instance." >&2
    exit 1
  fi
elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  HAVE_DOCKER=true
  log "Starting Postgres via Docker Compose"
  docker compose up -d --wait --wait-timeout 60
elif [ -n "$PG_BIN" ] && { [ "$PGHOST" = "localhost" ] || [ "$PGHOST" = "127.0.0.1" ]; }; then
  log "Docker not found — starting a local Postgres instance directly ($PG_BIN)"
  PGDATA_DIR="$SCRIPT_DIR/.pgdata"
  # --encoding/--locale pinned explicitly: initdb otherwise picks them up from the
  # invoking shell's locale env vars, which may not be set (or not be UTF-8) in every
  # environment this script runs in — and dbt's own SQL comments use non-ASCII characters.
  [ -d "$PGDATA_DIR" ] || "$PG_BIN/initdb" -D "$PGDATA_DIR" -U "$PGUSER" --auth=trust --encoding=UTF8 --locale=C >/dev/null
  "$PG_BIN/pg_ctl" -D "$PGDATA_DIR" status >/dev/null 2>&1 || \
    "$PG_BIN/pg_ctl" -D "$PGDATA_DIR" -o "-p $PGPORT" -l "$PGDATA_DIR/server.log" start
  for _ in $(seq 1 30); do postgres_port_open && break; sleep 1; done
  postgres_port_open || { echo "Local Postgres didn't come up — check $PGDATA_DIR/server.log" >&2; exit 1; }
  "$PG_BIN/psql" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname = '$PGDATABASE'" | grep -q 1 || \
    "$PG_BIN/psql" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -c "CREATE DATABASE $PGDATABASE" >/dev/null
else
  echo "Postgres isn't reachable at ${PGHOST}:${PGPORT}, and neither Docker nor a local Postgres install (initdb/pg_ctl) was found to start one." >&2
  exit 1
fi

# psql: prefer a real local install (faster, no container hop); fall back to running it
# inside the Postgres container. Either way, no separate manual client setup is needed.
if [ -n "$PG_BIN" ]; then
  run_psql() { PGPASSWORD="$PGPASSWORD" "$PG_BIN/psql" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 "$@"; }
elif [ "$HAVE_DOCKER" = true ]; then
  run_psql() { docker compose exec -T db psql -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 "$@"; }
else
  echo "Need a psql client (or Docker) to talk to Postgres." >&2
  exit 1
fi

# Shared virtualenv setup (dbt-postgres + matplotlib, see requirements.txt) — used by the
# dbt step below if dbt isn't already installed some other way, and always used by the
# chart step at the end, since that needs matplotlib regardless.
ensure_venv() {
  [ -d .venv ] || python3 -m venv .venv
  # shellcheck source=/dev/null
  source .venv/bin/activate
  pip install --quiet --upgrade pip
  pip install --quiet -r requirements.txt
}

# dbt: use one already on PATH if there is one (e.g. installed via pipx); otherwise set
# up a throwaway virtualenv with python3. Either way works — python3 is not required for
# this step if dbt is already installed some other way (it's still needed later for the
# chart, but that degrades gracefully — see the end of the script).
if command -v dbt >/dev/null 2>&1; then
  log "Using dbt already on PATH ($(command -v dbt))"
  run_dbt() { dbt "$@"; }
elif command -v python3 >/dev/null 2>&1; then
  log "Setting up a Python virtualenv for dbt"
  ensure_venv
  run_dbt() { dbt "$@"; }
else
  echo "Need either 'dbt' on PATH or python3 (to install it into a virtualenv)." >&2
  exit 1
fi

log "Filtering source CSVs to hourly :00/:59 rows"
# The strategy can only ever use two rows per hour per day (the buy tick at :00:00 and
# the sell tick at :59:59) — filtering here keeps this script's own runtime to seconds
# instead of tens of minutes on the full ~221M-row dataset.
FILTER_DIR="$(mktemp -d)"
trap 'rm -rf "$FILTER_DIR"' EXIT

filter_pattern=' [0-9]{2}:00:00,| [0-9]{2}:59:59,'
grep -E "$filter_pattern" "$HALF1" > "$FILTER_DIR/half1_filtered.csv"
grep -E "$filter_pattern" "$HALF2" > "$FILTER_DIR/half2_filtered.csv"
cat "$FILTER_DIR/half1_filtered.csv" "$FILTER_DIR/half2_filtered.csv" > "$FILTER_DIR/combined_filtered.csv"
row_count="$(wc -l < "$FILTER_DIR/combined_filtered.csv" | tr -d ' ')"
echo "    $row_count rows after filtering"

log "Loading raw.btc_ticks"
run_psql <<'SQL'
CREATE SCHEMA IF NOT EXISTS raw;
DROP TABLE IF EXISTS raw.btc_ticks;
CREATE TABLE raw.btc_ticks (
    open_time                    timestamp NOT NULL,
    open                         numeric NOT NULL,
    high                         numeric NOT NULL,
    low                          numeric NOT NULL,
    close                        numeric NOT NULL,
    volume                       numeric NOT NULL,
    close_time                   timestamp NOT NULL,
    quote_asset_volume           numeric NOT NULL,
    number_of_trades             integer NOT NULL,
    taker_buy_base_asset_volume  numeric NOT NULL,
    taker_buy_quote_asset_volume numeric NOT NULL,
    ignore_col                   integer NOT NULL
);
SQL
run_psql -c "\copy raw.btc_ticks FROM STDIN WITH (FORMAT csv)" < "$FILTER_DIR/combined_filtered.csv"

log "Building the dbt project (staging, intermediate, marts, all data tests)"
export DBT_PROFILES_DIR="$SCRIPT_DIR/profiles"
(cd alpaca_assignment && run_dbt build)

log "Compiling the final answer queries"
(cd alpaca_assignment && run_dbt compile --quiet --select answer_biggest_return_hour answer_lowest_drawdown_hour)

echo
echo "############################################################"
echo "# Q1: Which hour of the day had the biggest returns?"
echo "############################################################"
run_psql < alpaca_assignment/target/compiled/alpaca_assignment/analyses/answer_biggest_return_hour.sql

echo
echo "############################################################"
echo "# Q2: Which hour of the day had the lowest maximum losses?"
echo "############################################################"
run_psql < alpaca_assignment/target/compiled/alpaca_assignment/analyses/answer_lowest_drawdown_hour.sql

log "Compiling the hourly summary"
(cd alpaca_assignment && run_dbt compile --quiet --select hourly_summary)

CHART_PATH="$SCRIPT_DIR/hourly_summary.png"
if command -v python3 >/dev/null 2>&1; then
  log "Generating the hourly performance chart"
  ensure_venv
  run_psql --csv < alpaca_assignment/target/compiled/alpaca_assignment/analyses/hourly_summary.sql > "$FILTER_DIR/hourly_summary.csv"

  python3 - "$FILTER_DIR/hourly_summary.csv" "$CHART_PATH" <<'PY'
import csv
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.cm import RdYlGn
from matplotlib.colors import Normalize

csv_path, png_path = sys.argv[1], sys.argv[2]

rows = []
with open(csv_path) as f:
    for row in csv.DictReader(f):
        rows.append((
            int(row["hour"]),
            float(row["total_compounded_return"]) * 100,
            float(row["max_drawdown"]) * 100,
        ))
rows.sort(key=lambda r: r[0])

labels = [f"{h:02d}:00" for h, _, _ in rows]
returns = [r for _, r, _ in rows]
drawdowns = [d for _, _, d in rows]

fig, axes = plt.subplots(2, 1, figsize=(13, 9), sharex=True)
fig.suptitle(
    "BTC hour-of-day performance — buy at :00, sell at :59 (2017–2024)",
    fontsize=14, fontweight="bold",
)

def panel(ax, values, title, ylabel):
    norm = Normalize(vmin=min(values), vmax=max(values))
    colors = [RdYlGn(norm(v)) for v in values]
    bars = ax.bar(labels, values, color=colors, edgecolor="#333333", linewidth=0.6)
    best_i = values.index(max(values))
    bars[best_i].set_edgecolor("black")
    bars[best_i].set_linewidth(2.5)
    for bar, v in zip(bars, values):
        ax.annotate(
            f"{v:+.0f}%", xy=(bar.get_x() + bar.get_width() / 2, v),
            xytext=(0, 3 if v >= 0 else -12), textcoords="offset points",
            ha="center", fontsize=7,
        )
    ax.axhline(0, color="black", linewidth=0.8)
    ax.set_title(title, fontsize=11)
    ax.set_ylabel(ylabel)
    ax.margins(y=0.15)

panel(axes[0], returns, "Total compounded return by hour", "Return (%)")
panel(axes[1], drawdowns, "Max drawdown by hour", "Drawdown (%)")

plt.xticks(rotation=45, ha="right")
plt.xlabel("Hour of day (UTC)")
plt.tight_layout()
plt.savefig(png_path, dpi=150)
print(f"Saved {png_path}")
PY

  echo
  echo "############################################################"
  echo "# Chart: $CHART_PATH"
  echo "############################################################"
  # Best-effort auto-open — fine if neither exists, the path above is enough either way.
  { command -v open >/dev/null 2>&1 && open "$CHART_PATH"; } || \
  { command -v xdg-open >/dev/null 2>&1 && xdg-open "$CHART_PATH"; } || true
else
  echo
  echo "python3 not found — skipping the hourly performance chart (the answers above are unaffected)." >&2
fi
