with ticks as (

    select * from {{ ref('stg_btc_ticks') }}

)

-- Conditional aggregation, not a self-join of "opens" and "closes" CTEs.
select
    date,
    hour,
    max(case when second = 0 then open_price end)  as buy_price,
    max(case when second = 59 then close_price end) as sell_price
from ticks
group by date, hour
having count(distinct second) = 2
