with returns as (

    select * from {{ ref('int_hourly_returns') }}

),

equity_curve as (

    select * from {{ ref('int_hourly_equity_curve') }}

)

-- Grain: one row per (date, hour)
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
