-- Answers: "Which hour of the day had the biggest returns?"
-- mart_daily_hourly_performance is at (date, hour) grain; roll it up to one row per
-- hour by taking each hour's final compounded equity — the running `equity` value on
-- its most recent date, since equity is already the cumulative product of (1 + r) up
-- to and including that date.
select
    hour,
    (array_agg(equity order by date desc))[1] - 1 as total_compounded_return,
    avg(hourly_return) as avg_daily_return,
    count(*) as trading_days
from {{ ref('mart_daily_hourly_performance') }}
group by hour
order by total_compounded_return desc
limit 1
