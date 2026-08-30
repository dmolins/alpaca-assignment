-- Fails (returns a row) if the mart's row count doesn't match int_hourly_prices' —
-- guards the join in mart_daily_hourly_performance from silently dropping or
-- duplicating rows relative to its upstream source of truth for the grain.
select
    (select count(*) from {{ ref('int_hourly_prices') }}) as prices_rows,
    (select count(*) from {{ ref('mart_daily_hourly_performance') }}) as mart_rows
where (select count(*) from {{ ref('int_hourly_prices') }})
   != (select count(*) from {{ ref('mart_daily_hourly_performance') }})
