#!/usr/bin/env bash
# Bitcoin hour-of-day backtesting engine — end-to-end runner.
#
# Spins up Postgres (Docker), loads the two source CSVs (pre-filtered to the :00/:59
# rows the strategy can ever use — see NOTES.md §4.2 for why), builds the dbt project,
# then prints the answers to both prompt questions. Safe to re-run: every step either
# recreates its own output or is naturally idempotent.
#
# Prerequisites: docker (with Compose v2), python3. Nothing else — psql is used if
# already on PATH (faster), but the script falls back to running it inside the Postgres
# container via `docker compose exec` if it isn't, so a host Postgres client install is
# never required.
#
# Usage: ./run.sh
# Env vars (all optional, defaults match docker-compose.yml exactly):
#   DATA_DIR   — directory containing half1_BTCUSDT_1s.csv / half2_BTCUSDT_1s.csv
#                (default: this script's directory)
#   PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE — override the Postgres connection,
#                e.g. to point at an already-running Postgres instead of Docker.

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

log "Checking prerequisites"
command -v docker >/dev/null 2>&1 || { echo "docker is required (with Compose v2 — 'docker compose', not the standalone docker-compose v1)." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required." >&2; exit 1; }
for f in "$HALF1" "$HALF2"; do
  [ -f "$f" ] || { echo "Missing data file: $f (set DATA_DIR to point at the CSVs)." >&2; exit 1; }
done

# Run a psql command against the target database. Prefers a host `psql` if present
# (faster, no docker exec overhead); falls back to running it inside the `db` container
# so a host Postgres client is never a hard requirement.
if command -v psql >/dev/null 2>&1; then
  run_psql() { PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 "$@"; }
else
  run_psql() { docker compose exec -T db psql -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 "$@"; }
fi

log "Starting Postgres via Docker Compose"
docker compose up -d --wait --wait-timeout 60

log "Setting up Python virtualenv for dbt"
if [ ! -d .venv ]; then
  python3 -m venv .venv
fi
# shellcheck source=/dev/null
source .venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet -r requirements.txt

log "Filtering source CSVs to hourly :00/:59 rows"
# The strategy can only ever use two rows per hour per day (the buy tick at :00:00 and
# the sell tick at :59:59) — filtering here keeps this script's own runtime to seconds
# instead of tens of minutes on the full ~221M-row dataset. See NOTES.md §4.2 for the
# full reasoning and the production-scale alternative (load raw, filter in dbt staging).
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
(cd alpaca_assignment && dbt build)

log "Compiling the final answer queries"
(cd alpaca_assignment && dbt compile --quiet --select answer_biggest_return_hour answer_lowest_drawdown_hour)

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
