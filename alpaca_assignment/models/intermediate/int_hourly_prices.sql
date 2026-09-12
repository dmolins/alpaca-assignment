{{ config(materialized='table') }}

with ticks as (

    select * from {{ ref('stg_btc_ticks') }}

)

-- Conditional aggregation, not a self-join of "opens" and "closes" CTEs.
-- `having count(distinct second) = 2` is the same completeness check `int_hourly_coverage`
-- reports on explicitly (see that model) - kept inline here, not joined against it, so
-- this model's plan never depends on the planner correctly estimating the selectivity of
-- a boolean flag on a view (see its own history of getting exactly that wrong, in the
-- README's "performance finding" note).
select
    date,
    hour,
    max(case when second = 0 then open_price end)  as buy_price,
    max(case when second = 59 then close_price end) as sell_price
from ticks
group by date, hour
having count(distinct second) = 2
