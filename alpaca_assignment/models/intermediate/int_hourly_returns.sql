with prices as (

    select * from {{ ref('int_hourly_prices') }}

)

select
    date,
    hour,
    buy_price,
    sell_price,
    sell_price / buy_price - 1 as hourly_return
from prices
