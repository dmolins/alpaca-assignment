-- Answers: "Which hour of the day had the lowest maximum losses?"
-- mart_daily_hourly_performance already carries a per-row `drawdown` (equity /
-- running_max_equity - 1) for every (date, hour). Max drawdown per hour is just the
-- worst (most negative) of those across all its dates: min(drawdown). "Lowest maximum
-- losses" means the smallest-magnitude drawdown, i.e. closest to zero, i.e. the largest
-- (least negative) max_drawdown across hours — hence order by ... desc, not asc.
select
    hour,
    min(drawdown) as max_drawdown,
    (array_agg(equity order by date desc))[1] - 1 as total_compounded_return,
    count(*) as trading_days
from {{ ref('mart_daily_hourly_performance') }}
group by hour
order by max_drawdown desc
limit 1
