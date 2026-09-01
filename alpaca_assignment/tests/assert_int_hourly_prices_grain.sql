-- Fails (returns rows) if any (date, hour) pair appears more than once. int_hourly_prices
-- used to be a self-join of "opens" and "closes" CTEs (see the model's own comment for
-- why that was replaced); this guards against that fan-out bug reappearing if it's ever
-- rewritten back to a join.
select date, hour, count(*) as n
from {{ ref('int_hourly_prices') }}
group by date, hour
having count(*) > 1
