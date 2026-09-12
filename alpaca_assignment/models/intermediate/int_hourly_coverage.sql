with ticks as (

    select * from {{ ref('stg_btc_ticks') }}

),

-- A plain `group by date, hour` over ticks only produces a row for an hour that has *at
-- least one* tick - an hour with zero ticks at all (most of the gaps found in this
-- dataset, e.g. the ~35-hour outage spanning 2018-02-08/09, or the partial first day's
-- hours 0-3) would simply never appear as a group, and silently vanish from this model
-- exactly the way it silently vanished from the old hardcoded-date approach. So this
-- builds the full expected (date, hour) calendar first - one row per hour between the
-- earliest and latest date actually seen in the source - and left-joins ticks onto it,
-- the standard way to make a *missing* row detectable instead of merely absent.
date_bounds as (

    select min(date) as min_date, max(date) as max_date
    from ticks

),

expected_hours as (

    select
        day.d::date as date,
        hour.h       as hour
    from date_bounds
    cross join lateral generate_series(date_bounds.min_date, date_bounds.max_date, interval '1 day') as day(d)
    cross join lateral generate_series(0, 23) as hour(h)

),

coverage as (

    select
        expected_hours.date,
        expected_hours.hour,
        coalesce(bool_or(ticks.second = 0), false)  as has_buy_tick,
        coalesce(bool_or(ticks.second = 59), false) as has_sell_tick
    from expected_hours
    left join ticks
        on ticks.date = expected_hours.date
        and ticks.hour = expected_hours.hour
    group by expected_hours.date, expected_hours.hour

)

-- One row per (date, hour) in the full observed range, whether or not any tick for it
-- actually exists in the source - this is the generic gap-detection layer: any gap in
-- the source data (the partial first day, the multi-hour outages found elsewhere in the
-- range, or a gap a future data refresh introduces) shows up here as is_complete = false,
-- with no hardcoded date or hour list involved. int_hourly_prices independently
-- re-derives this same completeness check rather than joining against this model (see
-- that model's comment for why); this model exists so the gap itself is queryable and
-- testable on its own, not just implicit in what int_hourly_prices silently drops.
select
    date,
    hour,
    has_buy_tick,
    has_sell_tick,
    has_buy_tick and has_sell_tick as is_complete
from coverage
