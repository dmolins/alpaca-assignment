with ticks as (

    select * from {{ ref('stg_btc_ticks') }}

)

-- Conditional aggregation, not a self-join of "opens" and "closes" CTEs: an earlier
-- version joined them, and with stg_btc_ticks as a view Postgres badly under-estimated
-- both sides' row counts (~2 rows instead of ~61K each) and picked a nested-loop plan —
-- ~3.7 billion comparisons, a 20+ minute query on a 123K-row table. Aggregation has no
-- join for the planner to get wrong, so it's robust to this regardless of materialization
-- or stats. `having count(distinct second) = 2` still drops the 30 hours confirmed
-- missing one side of the tick (NOTES.md §3) naturally, same as the join did.
select
    date,
    hour,
    max(case when second = 0 then open_price end)  as buy_price,
    max(case when second = 59 then close_price end) as sell_price
from ticks
group by date, hour
having count(distinct second) = 2
