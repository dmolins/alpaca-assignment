-- Fails (returns rows) if any (date, hour) pair appears more than once in the mart.
select date, hour, count(*) as n
from {{ ref('mart_daily_hourly_performance') }}
group by date, hour
having count(*) > 1
