with returns as (

    select * from {{ ref('int_hourly_returns') }}

),

compounded as (

    select
        date,
        hour,
        hourly_return,
        -- Cumulative product of (1 + r) via exp(sum(ln(...))): Postgres has no window
        -- PRODUCT aggregate, so this is the standard log-space trick for it. Assumes
        -- 1 + hourly_return > 0 for every row, i.e. no single hour ever loses 100%+ of
        -- its value — true for BTC at hourly granularity, but worth stating explicitly
        -- since it would silently produce NULLs (ln of a negative number) if violated.
        exp(
            sum(ln(1 + hourly_return)) over (
                partition by hour
                order by date
                rows between unbounded preceding and current row
            )
        ) as equity
    from returns

)

select
    date,
    hour,
    hourly_return,
    equity,
    max(equity) over (
        partition by hour
        order by date
        rows between unbounded preceding and current row
    ) as running_max_equity
from compounded
