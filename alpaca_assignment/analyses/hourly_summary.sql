-- Full 24-hour rollup, same pattern as answer_biggest_return_hour.sql /
-- answer_lowest_drawdown_hour.sql just without the limit 1 — run.sh renders this as the
-- color-coded terminal summary of every hour's performance.
select
    hour,
    (array_agg(equity order by date desc))[1] - 1 as total_compounded_return,
    min(drawdown) as max_drawdown
from {{ ref('mart_daily_hourly_performance') }}
group by hour
order by hour
