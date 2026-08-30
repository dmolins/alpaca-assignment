with returns as (

    select * from {{ ref('int_hourly_returns') }}

),

equity_curve as (

    select * from {{ ref('int_hourly_equity_curve') }}

)

-- Grain: one row per (date, hour) — not pre-aggregated up to hour-of-day. Keeping the
-- daily dimension here, rather than collapsing it away like an earlier version of this
-- mart did, is what lets this table answer questions beyond the prompt's two: weekday
-- vs. weekend performance by hour, a rolling trend for one specific hour over time,
-- year-over-year comparisons, etc. — all just a different GROUP BY/WHERE against this
-- same table, with no new model needed. The hour-of-day rollups the prompt actually asks
-- for live in analyses/, computed from this table, not baked into its grain.
select
    returns.date,
    returns.hour,
    returns.buy_price,
    returns.sell_price,
    returns.hourly_return,
    equity_curve.equity,
    equity_curve.running_max_equity,
    equity_curve.equity / equity_curve.running_max_equity - 1 as drawdown
from returns
inner join equity_curve
    on returns.date = equity_curve.date
    and returns.hour = equity_curve.hour
order by returns.hour, returns.date
