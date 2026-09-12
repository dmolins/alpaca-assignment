-- Every incomplete hour in the source data, in one queryable place - the tool this
-- project's own gap investigation should have been from the start, instead of a one-off
-- CSV grep whose findings could only ever describe the day it was run. Compile and run
-- this (or query int_hourly_coverage directly) any time the source data changes, to see
-- exactly what's missing and how bad it is, rather than assuming last time's count still
-- holds.
select
    date,
    hour,
    has_buy_tick,
    has_sell_tick,
    case
        when not has_buy_tick and not has_sell_tick then 'both ticks missing'
        when not has_buy_tick then 'buy tick (:00) missing'
        else 'sell tick (:59) missing'
    end as gap_reason
from {{ ref('int_hourly_coverage') }}
where not is_complete
order by date, hour
