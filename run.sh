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

postgres_reachable() { (exec 3<>"/dev/tcp/${PGHOST}/${PGPORT}") 2>/dev/null; }

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

HAVE_DOCKER=false
if postgres_reachable; then
  log "Postgres already reachable at ${PGHOST}:${PGPORT} — reusing it"
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
  for _ in $(seq 1 30); do postgres_reachable && break; sleep 1; done
  postgres_reachable || { echo "Local Postgres didn't come up — check $PGDATA_DIR/server.log" >&2; exit 1; }
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

# dbt: use one already on PATH if there is one (e.g. installed via pipx); otherwise set
# up a throwaway virtualenv with python3. Either way works — python3 is not required if
# dbt is already installed some other way.
if command -v dbt >/dev/null 2>&1; then
  log "Using dbt already on PATH ($(command -v dbt))"
  run_dbt() { dbt "$@"; }
elif command -v python3 >/dev/null 2>&1; then
  log "Setting up a Python virtualenv for dbt"
  [ -d .venv ] || python3 -m venv .venv
  # shellcheck source=/dev/null
  source .venv/bin/activate
  pip install --quiet --upgrade pip
  pip install --quiet -r requirements.txt
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

echo
echo "############################################################"
echo "# All 24 hours — return and drawdown (green = best, red = worst)"
echo "############################################################"
run_psql -t -A -F',' < alpaca_assignment/target/compiled/alpaca_assignment/analyses/hourly_summary.sql | awk '
BEGIN { FS = ","; RESET = "\033[0m" }
{
    hour[NR] = $1; ret[NR] = $2; dd[NR] = $3
    if (NR == 1 || $2 + 0 < minret) minret = $2 + 0
    if (NR == 1 || $2 + 0 > maxret) { maxret = $2 + 0; bestret = NR }
    if (NR == 1 || $3 + 0 < mindd)  mindd  = $3 + 0
    if (NR == 1 || $3 + 0 > maxdd)  { maxdd  = $3 + 0; bestdd  = NR }
    n = NR
}
function color(t,   r, g) {
    if (t < 0) t = 0
    if (t > 1) t = 1
    if (t < 0.5) { r = 255; g = int(510 * t) }
    else         { r = int(510 * (1 - t)); g = 255 }
    return sprintf("\033[38;2;%d;%d;0m", r, g)
}
END {
    printf "%-6s %14s %16s\n", "Hour", "Return", "Max Drawdown"
    for (i = 1; i <= n; i++) {
        tr = (maxret == minret) ? 1 : (ret[i] - minret) / (maxret - minret)
        td = (maxdd  == mindd)  ? 1 : (dd[i]  - mindd)  / (maxdd  - mindd)
        printf "%-6s %s%13.1f%%%s %s%15.1f%%%s\n", \
            sprintf("%02d:00", hour[i]), \
            color(tr), ret[i] * 100, RESET, \
            color(td), dd[i] * 100, RESET
    }
    printf "\nBest return:   %02d:00 (%+.1f%%)\n", hour[bestret], ret[bestret] * 100
    printf "Best drawdown: %02d:00 (%+.1f%%)\n", hour[bestdd], dd[bestdd] * 100
}
'
