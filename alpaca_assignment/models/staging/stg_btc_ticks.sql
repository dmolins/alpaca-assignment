with source as (

    select * from {{ source('raw', 'btc_ticks') }}

),

renamed as (

    select
        open_time,
        close_time,
        open_time::date                    as date,
        extract(hour from open_time)::int  as hour,
        extract(second from open_time)::int as second,
        open                                as open_price,
        close                               as close_price,
        high                                as high_price,
        low                                 as low_price,
        volume,
        number_of_trades

    from source

),

deduped as (

    -- Real data quality issue found by inspection, not hypothetical: 15 timestamps in
    -- the source (all at :00:00, none at :59:59) have exactly 9 fully-identical
    -- duplicate rows each — the source data has a repeating "restart" pattern right
    -- after these points (e.g. around 2017-09-06 23:00:00: ...23:00:00, 23:00:00,
    -- 23:00:01, 23:00:00, 23:00:01, 23:00:02, 23:00:00, ... — each restart one second
    -- further before jumping back to :00:00). Since every duplicate's OHLCV values are
    -- byte-identical (verified: 1 distinct value combo per duplicated open_time), this
    -- is a lossless dedup, not a decision about which row to trust.
    select distinct on (open_time) *
    from renamed
    order by open_time

)

select *
from deduped
-- Defensive filter, not just documentation: the loader for this submission already
-- pre-filters to :00/:59 rows, so this is a no-op today. But it makes this model correct
-- on its own if `raw.btc_ticks` is ever swapped for a full, unfiltered load instead,
-- without needing to touch this file.
where second in (0, 59)
  and date > date '2017-08-17'  -- partial day: first row is 04:00:28, hours 0-3 missing
