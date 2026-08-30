-- Fails (returns rows) if any (date, hour) pair appears more than once — guards the
-- 30-hour gap / 15-timestamp-duplicate issues from NOTES.md §3 from silently reappearing
-- as a join fan-out bug if stg_btc_ticks or the join in int_hourly_prices ever changes.
select date, hour, count(*) as n
from {{ ref('int_hourly_prices') }}
group by date, hour
having count(*) > 1
