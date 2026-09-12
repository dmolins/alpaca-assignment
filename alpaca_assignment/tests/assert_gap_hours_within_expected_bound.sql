-- Canary, not a correctness check: fails (returns a row) if the number of incomplete
-- hours (int_hourly_coverage.is_complete = false) jumps well past what this dataset is
-- actually known to contain, so a future data refresh that silently drops a much bigger
-- chunk of the source than expected fails the build instead of quietly shipping a
-- degraded backtest.
--
-- 163 incomplete hours are known and expected as of 2026-09-12 (see
-- analyses/data_quality_gap_report.sql for the full breakdown, and the README's data
-- quality section for what they are: 5 from the partial first day, 158 from real gaps
-- elsewhere in the source - including a ~35-hour outage spanning 2018-02-08/09). The
-- 300 ceiling below is deliberately loose (~1.8x the known count): it exists to catch a
-- gross regression (e.g. a broken source file, a bad re-filter), not to be re-tuned every
-- time one more gap-hour is found by chance.
with gap_count as (
    select count(*) as n
    from {{ ref('int_hourly_coverage') }}
    where not is_complete
)

select n as incomplete_hours
from gap_count
where n > 300
