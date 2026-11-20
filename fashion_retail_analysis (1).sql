-- =====================================================================
-- Revenue Leakage & Promotional Impact Analysis
-- Dataset: Global Fashion Retail Sales (Kaggle, ricgomes, CC BY 4.0)
-- BigQuery dataset ID: fashion_retail
-- =====================================================================
--
-- CONTENTS (queries are in the order they were run)
--   Setup & validation ........ 1 row counts | 2 v_sales view |
--                               3-4 returns & currency checks
--   Leakage ................... 5 by country | 6 by product group |
--                               14 by category | 15 monthly trend
--   Campaigns ................. 7 & 13 campaign counts | 8 date range |
--                               9 overlap check | 10 v_sales_promo view |
--                               11 by campaign type | 12 lift |
--                               16 campaign calendar
--   Margin & profit ........... 17 margin by campaign type |
--                               18 profit per day | 19 cost % of list
--   Dashboard ................. 20 dash_daily summary table
--
-- Queries 13-19 and the verification in 20 were written by Fabrizio.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. DATA LOAD CHECK — row counts per table
-- ---------------------------------------------------------------------
-- Result (2026-11-07): transactions 6,416,827 | customers 1,643,306 |
-- products 17,940 | employees 404 | discounts 181 | stores 35
SELECT 'transactions' AS tbl, COUNT(*) AS row_count FROM fashion_retail.transactions
UNION ALL SELECT 'products',  COUNT(*) FROM fashion_retail.products
UNION ALL SELECT 'stores',    COUNT(*) FROM fashion_retail.stores
UNION ALL SELECT 'customers', COUNT(*) FROM fashion_retail.customers
UNION ALL SELECT 'employees', COUNT(*) FROM fashion_retail.employees
UNION ALL SELECT 'discounts', COUNT(*) FROM fashion_retail.discounts;


-- ---------------------------------------------------------------------
-- 2. BASE VIEW — v_sales
-- ---------------------------------------------------------------------
-- Joins each transaction line to its product and store, renames columns
-- to snake_case, and adds calculated money columns:
--   gross    = list price x quantity (what could have been earned)
--   discount = gross - net (what was given away)
--   net      = Line Total (what the customer actually paid)
--
-- Assumptions (document in README):
--   * Returns have positive Quantity but negative Line Total, so a sign
--     of -1 is applied to gross/cost on Return rows so they net out.
--   * Four currencies (USD, EUR, GBP, CNY) are converted to USD with
--     fixed approximate rates. REPLACE with actual average rates for
--     the dataset's date range before publishing.
--   * Production Cost is assumed to be in USD.
CREATE OR REPLACE VIEW fashion_retail.v_sales AS
WITH fx AS (                       -- approximate USD conversion rates (assumption)
  SELECT 'USD' AS currency, 1.00 AS usd_rate UNION ALL
  SELECT 'EUR', 1.08 UNION ALL
  SELECT 'GBP', 1.27 UNION ALL
  SELECT 'CNY', 0.14
),
base AS (
  SELECT
    t.`Invoice ID`        AS invoice_id,
    t.Line                AS line,
    DATE(t.`Date`)        AS sale_date,
    t.`Transaction Type`  AS transaction_type,
    IF(t.`Transaction Type` = 'Return', -1, 1) AS sign,   -- returns subtract
    t.`Customer ID`       AS customer_id,
    t.`Product ID`        AS product_id,
    p.Category            AS category,
    p.`Sub Category`      AS sub_category,
    p.`Description EN`    AS product_name,
    t.Size                AS size,
    t.Color               AS color,
    t.`Store ID`          AS store_id,
    s.`Store Name`        AS store_name,
    s.Country             AS country,
    s.City                AS city,
    t.`Employee ID`       AS employee_id,
    t.Currency            AS currency,
    t.`Payment Method`    AS payment_method,
    t.`Unit Price`        AS unit_price,
    t.Quantity            AS quantity,
    t.Discount            AS discount_rate,
    t.`Line Total`        AS net_amount,
    p.`Production Cost`   AS unit_cost
  FROM fashion_retail.transactions AS t
  LEFT JOIN fashion_retail.products AS p ON t.`Product ID` = p.`Product ID`
  LEFT JOIN fashion_retail.stores   AS s ON t.`Store ID`   = s.`Store ID`
)
SELECT
  b.* EXCEPT (sign),
  b.sign * b.unit_price * b.quantity                            AS gross_amount,
  b.sign * b.unit_price * b.quantity - b.net_amount             AS discount_amount,
  ROUND(b.sign * b.unit_price * b.quantity * fx.usd_rate, 2)    AS gross_usd,
  ROUND((b.sign * b.unit_price * b.quantity - b.net_amount) * fx.usd_rate, 2) AS discount_usd,
  ROUND(b.net_amount * fx.usd_rate, 2)                          AS net_usd,
  ROUND(b.sign * b.unit_cost * b.quantity, 2)                   AS cost_usd   -- assumes cost is in USD
FROM base AS b
LEFT JOIN fx ON b.currency = fx.currency;


-- ---------------------------------------------------------------------
-- 3. VALIDATION — how returns and currencies are recorded
-- ---------------------------------------------------------------------
-- Finding: Returns have positive quantity, negative Line Total, and a
-- discount rate of 0. Four currencies present: CNY, EUR, GBP, USD.
SELECT
  transaction_type,
  currency,
  COUNT(*)                     AS line_count,
  MIN(quantity)                AS min_qty,
  MIN(net_amount)              AS min_net,
  MAX(net_amount)              AS max_net,
  ROUND(MAX(discount_rate), 2) AS max_discount_rate
FROM fashion_retail.v_sales
GROUP BY transaction_type, currency
ORDER BY transaction_type, currency;


-- ---------------------------------------------------------------------
-- 4. VALIDATION — totals by transaction type (USD)
-- ---------------------------------------------------------------------
-- Result: Sale   gross 342.7M | discount 43.5M  | net 299.2M
--         Return gross -19.2M | discount -2.4M  | net -16.8M
-- Finding: refunds are paid at the discounted price, not list price
-- (discount share on returns 12.5% vs 12.7% on sales), so the negative
-- discount on returns is the original discount being reversed.
--
-- HEADLINE: Gross 342.7M - Discounts 43.5M - Returns 16.8M
--           = Net revenue 282.4M  ->  Leakage 60.2M (17.6% of gross)
SELECT
  transaction_type,
  ROUND(SUM(gross_usd), 0)    AS gross_usd,
  ROUND(SUM(discount_usd), 0) AS discount_usd,
  ROUND(SUM(net_usd), 0)      AS net_usd
FROM fashion_retail.v_sales
GROUP BY transaction_type;


-- ---------------------------------------------------------------------
-- 5. ANALYSIS — leakage by country
-- ---------------------------------------------------------------------
-- Conditional aggregation (SUM(IF(...))) puts sales and returns in
-- separate columns so each country is one row.
--
-- Result (USD, approx.):
--   China   gross 91.0M | disc 12.2% | ret 5.6% | net 75.4M
--   US      gross 90.8M | disc 12.5% | ret 5.6% | net 75.0M
--   Germany gross 39.5M | disc 13.6% | ret 5.6% | net 32.2M
--   France  gross 34.0M | disc 13.0% | ret 5.6% | net 27.9M
--   Portugal gross 30.4M| disc 12.7% | ret 5.6% | net 25.1M
--   Spain   gross 30.0M | disc 12.6% | ret 5.7% | net 24.7M
--   UK      gross 27.0M | disc 13.3% | ret 5.6% | net 22.1M
-- Findings:
--   * Return rate is flat (~5.6%) in every country — likely a fixed rate
--     in the dataset's simulation; returns don't differentiate markets.
--   * Discount rate ranges 12.2% (China) to 13.6% (Germany). At China's
--     rate, Germany would retain ~$0.55M more.
--   * China vs US dollar ranking depends on the assumed CNY rate; the
--     percentages are unaffected by FX (rate cancels out in ratios).
--   * TODO: translate local-language country names (中国, Deutschland,
--     España) to English in the view before building the dashboard.
SELECT
  country,
  ROUND(SUM(IF(transaction_type = 'Sale',   gross_usd, 0)))    AS gross_sales,
  ROUND(SUM(IF(transaction_type = 'Sale',   discount_usd, 0))) AS discounts,
  ROUND(-SUM(IF(transaction_type = 'Return', net_usd, 0)))     AS returns,
  ROUND(SUM(net_usd))                                          AS net_revenue,
  ROUND(100 * SAFE_DIVIDE(SUM(IF(transaction_type = 'Sale', discount_usd, 0)),
                          SUM(IF(transaction_type = 'Sale', gross_usd, 0))), 1)   AS discount_pct,
  ROUND(100 * SAFE_DIVIDE(-SUM(IF(transaction_type = 'Return', net_usd, 0)),
                          SUM(IF(transaction_type = 'Sale', net_usd, 0))), 1)     AS return_pct
FROM fashion_retail.v_sales
GROUP BY country
ORDER BY net_revenue DESC;


-- ---------------------------------------------------------------------
-- 6. ANALYSIS — leakage by product category / sub-category
-- ---------------------------------------------------------------------
-- CTE computes dollar totals first; outer query derives percentages.
-- leakage_pct = (discounts + returns) / gross sales
WITH totals AS (
  SELECT
    category,
    sub_category,
    SUM(IF(transaction_type = 'Sale',   gross_usd, 0))    AS gross_sales,
    SUM(IF(transaction_type = 'Sale',   discount_usd, 0)) AS discounts,
    -SUM(IF(transaction_type = 'Return', net_usd, 0))     AS returns,
    SUM(IF(transaction_type = 'Sale',   net_usd, 0))      AS net_sales
  FROM fashion_retail.v_sales
  GROUP BY category, sub_category
)
SELECT
  category,
  sub_category,
  ROUND(gross_sales)                                        AS gross_sales,
  ROUND(discounts)                                          AS discounts,
  ROUND(returns)                                            AS returns,
  ROUND(discounts + returns)                                AS leakage,
  ROUND(100 * SAFE_DIVIDE(discounts + returns, gross_sales), 1) AS leakage_pct,
  ROUND(100 * SAFE_DIVIDE(discounts, gross_sales), 1)       AS discount_pct,
  ROUND(100 * SAFE_DIVIDE(returns, net_sales), 1)           AS return_pct
FROM totals
ORDER BY leakage DESC;

-- Findings:
--   * Discount rate spans 8.9%-25.7% by sub-category (vs 12.2%-13.6% by
--     country) -> product, not geography, is the main leakage driver.
--   * Many sub-categories sit at a ~9% baseline (suits, accessories,
--     underwear, baby); targeted outliers: Children Girl & Boy 25.7%,
--     Children Coats 21.5%, Dresses & Jumpsuits 17.6% (largest $ leakage,
--     $5.0M), Masculine Shirts 17.5%, Shirts & Blouses 16.9%,
--     Masculine Pants & Jeans 15.6%.
--   * Same product type, different treatment by gender: Pants & Jeans
--     Masculine 15.6% vs Feminine 9.0%.
--   * Children's clothing: smallest category but its two largest
--     sub-categories leak 26-30% of list value.
--   * Returns flat ~5.6% again -> discounts are the leakage story.
--   * Hypothesis: ~9% baseline = store-wide sales; higher rates = targeted
--     category campaigns. Test with the discounts table (query 7).


-- ---------------------------------------------------------------------
-- 7. EXPLORE — discount campaign calendar
-- ---------------------------------------------------------------------
-- How many campaigns targeted each category / sub-category, and at what
-- average rate. ("Discont" is a typo in the original dataset.)
SELECT
  Category,
  `Sub Category`,
  COUNT(*)                  AS campaigns,
  ROUND(AVG(Discont), 2)    AS avg_rate,
  MIN(Start)                AS first_start,
  MAX(`End`)                AS last_end
FROM fashion_retail.discounts
GROUP BY Category, `Sub Category`
ORDER BY campaigns DESC;

-- Findings:
--   * Blank Category/Sub Category = store-wide campaigns: 10 campaigns,
--     avg 55%, late Nov - Dec 31 (Black Friday / holiday). Source of the
--     ~9% baseline every product carries.
--   * Sub-categories with NO targeted campaigns (Suits, Fem. Pants & Jeans,
--     Underwear/Lingerie/Pajamas, Baby, Fem./Masc. Accessories) are exactly
--     the ~9% group -> hypothesis supported.
--   * Most-targeted = biggest leakers: Dresses & Jumpsuits and Children
--     Girl & Boy (16 campaigns each, 35%). Deepest targeted rate:
--     Children Coats (42%).
--   * Masculine Pants & Jeans: 10 campaigns at 35%; Feminine Pants & Jeans:
--     none -> explains the 15.6% vs 9.0% gender gap.
--   * Campaign dates span 2020-2025; must check against the sales window.
--     NOTE: counts above include 2020-2022 campaigns that fall outside the
--     sales window -> recount within 2023-01-01..2025-03-18 later.


-- ---------------------------------------------------------------------
-- 8. CHECK — sales date range & how store-wide category is stored
-- ---------------------------------------------------------------------
-- Scalar subqueries: each (SELECT ...) returns one value -> one column.
SELECT
  (SELECT MIN(sale_date) FROM fashion_retail.v_sales)               AS first_sale,
  (SELECT MAX(sale_date) FROM fashion_retail.v_sales)               AS last_sale,
  (SELECT COUNTIF(Category IS NULL) FROM fashion_retail.discounts)  AS null_category_rows,
  (SELECT COUNTIF(Category = '')    FROM fashion_retail.discounts)  AS empty_category_rows;

-- Result: first_sale 2023-01-01 | last_sale 2025-03-18 |
--         null_category_rows 10 | empty_category_rows 0
-- -> Sales cover ~26.5 months. Store-wide campaigns are stored as NULL.


-- ---------------------------------------------------------------------
-- 9. CHECK — campaign matches per sale line (overlap test)
-- ---------------------------------------------------------------------
-- Range join: a sale matches a campaign when its date falls between
-- Start and End AND the campaign is store-wide (Category IS NULL) or
-- targets that exact category + sub-category.
-- Expect only 0 or 1 matches; 2+ means overlapping campaigns.
-- lines_with_discount validates the join against the data's own
-- discount column.
WITH matched AS (
  SELECT
    s.invoice_id,
    s.line,
    MAX(s.discount_rate) AS discount_rate,
    COUNT(d.Start)       AS n_campaigns
  FROM fashion_retail.v_sales AS s
  LEFT JOIN fashion_retail.discounts AS d
    ON  s.sale_date BETWEEN d.Start AND d.`End`
    AND ( d.Category IS NULL
          OR (d.Category = s.category AND d.`Sub Category` = s.sub_category) )
  WHERE s.transaction_type = 'Sale'
  GROUP BY s.invoice_id, s.line
)
SELECT
  n_campaigns,
  COUNT(*)                   AS sale_lines,
  COUNTIF(discount_rate > 0) AS lines_with_discount
FROM matched
GROUP BY n_campaigns
ORDER BY n_campaigns;

-- Result: 0 campaigns -> 4,288,334 lines, 0 with discount
--         1 campaign  -> 1,788,866 lines, 1,788,866 with discount
-- Findings:
--   * No overlapping campaigns -> join is safe (no duplicated rows).
--   * Campaign calendar explains EVERY discount: all matched lines are
--     discounted, no unmatched line is.
--   * 4,288,334 + 1,788,866 = 6,077,200 = total sale lines (reconciles).
--   * 29.4% of sale lines were sold under a campaign.


-- ---------------------------------------------------------------------
-- 10. VIEW — v_sales_promo (sales tagged with their campaign)
-- ---------------------------------------------------------------------
-- Built on v_sales; kept separate so simple queries skip the range join.
-- Only Sale rows are matched: a return's own date says nothing about the
-- campaign the item was bought under.
CREATE OR REPLACE VIEW fashion_retail.v_sales_promo AS
SELECT
  s.*,
  d.Description AS campaign_name,
  d.Start       AS campaign_start,
  d.`End`       AS campaign_end,
  d.Discont     AS campaign_rate,
  CASE
    WHEN d.Start IS NULL    THEN 'No campaign'
    WHEN d.Category IS NULL THEN 'Store-wide'
    ELSE 'Targeted'
  END AS campaign_type
FROM fashion_retail.v_sales AS s
LEFT JOIN fashion_retail.discounts AS d
  ON  s.transaction_type = 'Sale'
  AND s.sale_date BETWEEN d.Start AND d.`End`
  AND ( d.Category IS NULL
        OR (d.Category = s.category AND d.`Sub Category` = s.sub_category) );


-- ---------------------------------------------------------------------
-- 11. ANALYSIS — sales by campaign type
-- ---------------------------------------------------------------------
-- Window function SUM(SUM(net_usd)) OVER () = grand total across groups,
-- used to compute each group's share without a second query.
-- avg_line_rate vs avg_campaign_rate validates the campaign match.
SELECT
  campaign_type,
  COUNT(*)                                                  AS sale_lines,
  ROUND(SUM(gross_usd))                                     AS gross_sales,
  ROUND(SUM(discount_usd))                                  AS discounts,
  ROUND(SUM(net_usd))                                       AS net_sales,
  ROUND(100 * SAFE_DIVIDE(SUM(discount_usd), SUM(gross_usd)), 1) AS discount_pct,
  ROUND(100 * SUM(net_usd) / SUM(SUM(net_usd)) OVER (), 1)  AS share_of_net_sales_pct,
  ROUND(AVG(discount_rate), 3)                              AS avg_line_rate,
  ROUND(AVG(campaign_rate), 3)                              AS avg_campaign_rate
FROM fashion_retail.v_sales_promo
WHERE transaction_type = 'Sale'
GROUP BY campaign_type
ORDER BY net_sales DESC;

-- Result (USD, approx.):
--   No campaign 4,288,334 lines | gross 242.7M | disc 0    | net 242.7M | 81.1% of net
--   Targeted      854,995 lines | gross  43.8M | disc 15.2M| net  28.6M | 9.6%  | rate 0.343
--   Store-wide    933,871 lines | gross  56.2M | disc 28.3M| net  27.9M | 9.3%  | rate 0.504
-- Findings:
--   * Line rate = campaign rate exactly (0.343 / 0.504) -> join validated.
--   * Store-wide holiday sale (~13 days/yr: Black Friday Nov 27 + Dec
--     20-31 — corrected after query 16) = 65% of all discount $;
--     gives away ~$1.01 per $1 of net revenue collected.
--   * Targeted campaigns = 35% of discount $; ~$0.53 given per $1 collected.
--   * 81% of net revenue is full-price; promotions = 19% of revenue but
--     100% of discount leakage.
--   * CAVEAT: holiday volume is naturally high, so holiday lift can't be
--     separated from seasonality with this data.


-- ---------------------------------------------------------------------
-- 12. ANALYSIS — targeted campaign lift by sub-category
-- ---------------------------------------------------------------------
-- Compares average daily units / net revenue on targeted-campaign days
-- vs no-campaign days, per sub-category.
-- Break-even at ~35% off: need ~+54% units (1 / 0.65) to hold revenue.
-- AVG(IF(cond, x, NULL)) averages only rows meeting cond (AVG skips NULL).
-- HAVING filters after grouping (keep only targeted sub-categories).
WITH daily AS (
  SELECT
    category,
    sub_category,
    sale_date,
    campaign_type,
    SUM(quantity) AS units,
    SUM(net_usd)  AS net
  FROM fashion_retail.v_sales_promo
  WHERE transaction_type = 'Sale'
  GROUP BY category, sub_category, sale_date, campaign_type
)
SELECT
  category,
  sub_category,
  ROUND(AVG(IF(campaign_type = 'No campaign', units, NULL)))  AS units_per_day_normal,
  ROUND(AVG(IF(campaign_type = 'Targeted',    units, NULL)))  AS units_per_day_campaign,
  ROUND(100 * (SAFE_DIVIDE(AVG(IF(campaign_type = 'Targeted',    units, NULL)),
                           AVG(IF(campaign_type = 'No campaign', units, NULL))) - 1), 1) AS unit_lift_pct,
  ROUND(100 * (SAFE_DIVIDE(AVG(IF(campaign_type = 'Targeted',    net, NULL)),
                           AVG(IF(campaign_type = 'No campaign', net, NULL))) - 1), 1)   AS net_revenue_lift_pct
FROM daily
GROUP BY category, sub_category
HAVING COUNTIF(campaign_type = 'Targeted') > 0
ORDER BY net_revenue_lift_pct DESC;

-- Result (selected rows):
--   Children Girl & Boy     normal 104/day | campaign 1176/day | units +1033% | net +669%
--   Children Coats          normal 105/day | campaign  883/day | units  +744% | net +349%
--   Feminine Dresses & Jump normal 310/day | campaign 1002/day | units  +223% | net +123%
--   Fem./Masc. Coats & Blaz normal ~320/day| campaign ~806/day | units  +151% | net  +14%
-- Findings:
--   * Every targeted campaign clears break-even; Children's sub-categories
--     show the largest net revenue lift (supports hypothesis that targeted
--     promotions increase spending on these products — within this data).
--   * CAUTION: lifts are unrealistically large (up to 11x volume) and
--     normal daily volume is near-identical across sub-categories
--     (104-107 Children, 309-323 adult) -> promotion effects appear to be
--     programmed into the simulation. Method transfers to real data;
--     the magnitudes should not be taken as real-world evidence.
--   * ANOMALY: Coats & Blazers +151% units at ~40% off should give ~+51%
--     net, but shows only +14% -> something lowers revenue per unit during
--     campaigns (deeper discounts? cheaper items? timing?). To investigate.


-- ---------------------------------------------------------------------
-- 13. YOUR QUERY — campaigns overlapping the sales window
-- ---------------------------------------------------------------------
-- Written by Fabrizio. Corrected version of query 7: only counts
-- campaigns that overlap 2023-01-01..2025-03-18.
-- Logic: exclude campaigns that ENDED before sales began, and campaigns
-- that STARTED after sales ended.
SELECT
  Category,
  `Sub Category`,
  COUNT(*)                  AS campaigns,
  ROUND(AVG(Discont), 2)    AS avg_rate,
  MIN(Start)                AS first_start,
  MAX(`End`)                AS last_end
FROM fashion_retail.discounts
WHERE `End` >= DATE '2023-01-01'
  AND Start <= DATE '2025-03-18'
GROUP BY Category, `Sub Category`
ORDER BY campaigns DESC;

-- Result: counts drop (e.g. Dresses & Jumpsuits 16 -> 7; store-wide
-- 10 -> 4, i.e. 2 per holiday season: Black Friday + holiday sale).
-- Most-targeted sub-categories (Dresses & Jumpsuits, Children Girl & Boy)
-- get a campaign roughly every 3.7 months (26 months / 7).
-- Some last_end dates (2025-03-31) fall after the last sale — correct:
-- these campaigns started inside the window and overlap it.


-- ---------------------------------------------------------------------
-- 14. YOUR QUERY — net revenue by category (millions USD)
-- ---------------------------------------------------------------------
-- Written by Fabrizio. Sales + returns netted together, so net_usd_m is
-- final revenue after returns. Categories reconcile to the $282.4M total.
-- Note: gross/discount here are net of returns, so they differ slightly
-- from the sales-only figures in query 6.
-- Context (sales-only, from query 6): Children's = 9.5% of gross sales
-- but 14.1% of discounts and 12.6% of total leakage ($7.6M of $60.2M) —
-- disproportionate, but small in dollars vs the holiday sale ($28.3M).
SELECT
  category,
  ROUND(SUM(gross_usd)    / 1000000, 1) AS gross_usd_m,
  ROUND(SUM(discount_usd) / 1000000, 1) AS discount_usd_m,
  ROUND(SUM(net_usd)      / 1000000, 1) AS net_usd_m
FROM fashion_retail.v_sales
GROUP BY category
ORDER BY net_usd_m DESC;


-- ---------------------------------------------------------------------
-- 15. YOUR QUERY — monthly trend (millions USD)
-- ---------------------------------------------------------------------
-- Written by Fabrizio. DATE_TRUNC(sale_date, MONTH) rounds each date to
-- the first of its month so all days in a month group together.
SELECT
  DATE_TRUNC(sale_date, MONTH) AS month,
  ROUND(SUM(gross_usd)    / 1000000, 1) AS gross_usd_m,
  ROUND(SUM(discount_usd) / 1000000, 1) AS discount_usd_m,
  ROUND(SUM(net_usd)      / 1000000, 1) AS net_usd_m
FROM fashion_retail.v_sales
GROUP BY month
ORDER BY month;

-- Findings:
--   * December dominates: net $23.5M (2023), $26.1M (2024), ~2-3x a
--     typical month; $12-14M discounts (holiday sale). All other months
--     have < $3M discounts.
--   * Summer (Jun-Aug) is the slowest stretch ($6-8M net) with ZERO
--     discounts both years -> no promotions run in summer. Supports
--     testing a summer sale (but seasonality caveat applies).
--   * Campaign months are the busiest non-holiday months: March ($12-14M)
--     and September ($14-16M). Feb and Aug (no campaigns) among lowest.
--   * YoY: 2023 net ~$123.8M -> 2024 ~$139.9M (~+13%); every 2024 month
--     beats the same 2023 month.
--   * April shows -0.0 discounts: returns of items bought in March
--     campaigns reverse part of March's discount.
--   * March 2025 ($7.4M) is partial (data ends 2025-03-18), not a decline.
--   * OPEN QUESTION: November < October both years despite Black Friday.


-- ---------------------------------------------------------------------
-- 16. YOUR QUERY — full campaign calendar within the sales window
-- ---------------------------------------------------------------------
-- Written by Fabrizio. Reuses the overlap WHERE from query 13.
SELECT
  Start, `End`, Discont, Description, Category, `Sub Category`
FROM fashion_retail.discounts
WHERE `End` >= DATE '2023-01-01'
  AND Start <= DATE '2025-03-18'
ORDER BY Start;

-- Result: 79 campaign rows following an identical yearly schedule:
--   Jan 1-10   New Year Winter Sale            40%  coats & sweaters (6)
--   Mar 15-31  Early Spring Collection Refresh 35%  shirts, dresses, kids (5)
--   May 1-15   Mid-Spring Refresh Sale         25%  warm-weather items (8)
--   Sep 1-15   Fall Collection Launch          45%  pants, shirts, dresses, kids (7)
--   Oct 1-10   Autumn Essentials Sale          20%  sweaters, sportswear (6)
--   Nov 27     Black Friday Mega Sale          60%  store-wide, ONE day
--   Dec 20-31  Holiday Season Sale             50%  store-wide
-- Findings:
--   * Store-wide promotions total only ~13 days/yr, yet = 65% of all
--     discount dollars.
--   * Explains Nov < Oct (query 15): Oct has a 10-day campaign, Nov has
--     only one promo day (27th). No "waiting" behaviour needed — simpler
--     explanation preferred.
--   * Targeted campaigns are fixed calendar points (e.g. Dresses: Mar, May,
--     Sep), not evenly spaced — the "every 3.7 months" average was
--     misleading.
--   * No promotions mid-May through August -> confirms the summer gap.
--   * Black Friday is Nov 27 both years (real dates: Nov 24, 2023 and
--     Nov 29, 2024) -> another simulation artifact.


-- ---------------------------------------------------------------------
-- 17. YOUR QUERY — gross margin by campaign type (millions USD)
-- ---------------------------------------------------------------------
-- Written by Fabrizio. Sales only (net_sales = after discounts, before
-- returns). Gross profit = net sales - production cost.
-- Note: parentheses around the subtraction are required — division
-- happens before subtraction.
SELECT
  campaign_type,
  ROUND(SUM(net_usd) / 1000000, 1)                  AS net_sales,
  ROUND(SUM(cost_usd) / 1000000, 1)                 AS cost,
  ROUND((SUM(net_usd) - SUM(cost_usd)) / 1000000, 1) AS gross_profit,
  ROUND(100 * SAFE_DIVIDE(SUM(net_usd) - SUM(cost_usd), SUM(net_usd)), 1) AS margin_pct
FROM fashion_retail.v_sales_promo
WHERE transaction_type = 'Sale'
GROUP BY campaign_type
ORDER BY margin_pct DESC;

-- Result: No campaign  net 242.7 | cost 83.0 | GP 159.7 | 65.8%
--         Targeted     net  28.6 | cost 14.8 | GP  13.8 | 48.3%
--         Store-wide   net  27.9 | cost 18.1 | GP   9.8 | 35.1%
-- Findings:
--   * Full-price margin 65.8% is plausible for fashion retail -> the
--     "Production Cost is in USD" assumption looks reasonable.
--   * No promotion sells below cost; all remain profitable per item.
--   * Full-price = 81% of net sales but 87% of gross profit ($183.3M
--     total); store-wide = 9.3% of net sales but only 5.3% of profit.
--   * Cost is ~34% of list price across all campaign types, so:
--       50% off (Holiday) -> ~32% margin; 60% off (Black Friday) -> ~15%;
--       any discount above ~66% would sell below cost.
--   * The extra 10 points on Black Friday (60% vs 50%) roughly halves
--     margin -> discount DEPTH is the lever worth questioning.


-- ---------------------------------------------------------------------
-- 18. YOUR QUERY — gross profit per day by campaign
-- ---------------------------------------------------------------------
-- Written by Fabrizio. Sales only (returns have no campaign name and
-- would otherwise drag down the "normal day" row).
-- COUNT(DISTINCT sale_date) counts each date once.
-- Blank campaign_name = full-price sales ("normal days").
SELECT
  campaign_name,
  COUNT(DISTINCT sale_date)                                        AS days,
  ROUND((SUM(net_usd) - SUM(cost_usd)) / 1000000, 1)               AS gross_profit,
  ROUND((SUM(net_usd) - SUM(cost_usd)) / COUNT(DISTINCT sale_date) / 1000, 0) AS profit_per_day_k,
  ROUND(SUM(quantity) / COUNT(DISTINCT sale_date))                 AS units_per_day   -- added later
FROM fashion_retail.v_sales_promo
WHERE transaction_type = 'Sale'
GROUP BY campaign_name
ORDER BY profit_per_day_k DESC;

-- Result:
--   Holiday Season Sale (50%)        24 days | GP 9.6M  | $401K/day
--   (normal days, full price)       782 days | GP 159.7M| $204K/day
--   Autumn Essentials (20%)          20 days | GP 3.2M  | $158K/day
--   Mid-Spring Refresh (25%)         30 days | GP 3.1M  | $103K/day
--   Early Spring Refresh (35%)       38 days | GP 3.8M  |  $99K/day
--   Fall Collection Launch (45%)     30 days | GP 3.0M  |  $99K/day
--   Black Friday Mega Sale (60%)      2 days | GP 0.2M  |  $81K/day
--   New Year Winter Sale (40%)       30 days | GP 0.8M  |  $27K/day
-- Day counts reconcile: 782 + 24 + 2 = 808 days (2023-01-01..2025-03-18).
-- Findings:
--   * Holiday Season Sale earns ~2x a normal day's profit (seasonality
--     caveat: Dec 20-31 is peak shopping regardless).
--   * Black Friday at 60% earns LESS than half a normal day — the ~15%
--     margin shows up in totals; volume doesn't compensate.
--     -> Recommendation: test Black Friday at 50%.
--   * Units per day (added later): normal 6,033 | Black Friday 19,149
--     (~3.2x) | Holiday 41,211 (~6.8x) | New Year 4,497 (lowest).
--     Profit per unit: normal ~$33.80 | Holiday ~$9.70 | Black Friday ~$4.20.
--     -> Black Friday draws shoppers but earns little per unit; the
--        shallower Holiday sale sells MORE units/day (seasonality caveat).
--     -> Test target: at ~$9.70/unit, Black Friday at 50% needs only
--        ~8,300 units/day (-57%) to match current profit.
--     -> New Year sale's low volume supports the volume explanation
--        (post-holiday fatigue or low leftover stock).
--   * Store-wide rows (Holiday, Black Friday) cover the whole store, so
--     they compare fairly to a normal day. Targeted rows cover only a few
--     sub-categories -> NOT comparable to a whole-store day (see next step).

-- New Year Winter Sale reasoning (Fabrizio):
--   Like-for-like: only store-wide rows compare to a normal day; vs other
--   targeted campaigns (5-8 sub-categories, $99K-$158K/day), the New Year
--   sale (6 sub-categories) earns only $27K/day -> genuinely weaker.
--   Candidate explanations:
--     1. Less profitable categories  -> tested in query 19 (ruled out)
--     2. Post-holiday shopping fatigue -> testable (Jan 1-10 full-price
--        sales vs other normal days)
--     3. Clearance of leftover winter stock, which may be small after the
--        holidays -> low volume, low profit. Goal is to clear stock, so
--        profit/day may be the wrong measure. Not testable without
--        inventory data; proxy = distinct products sold per day.
--   Links to the Coats & Blazers anomaly in query 12 (same products).


-- ---------------------------------------------------------------------
-- 19. YOUR QUERY — production cost as % of list price, by sub-category
-- ---------------------------------------------------------------------
-- Written by Fabrizio. Tests whether New Year sale products have thinner
-- margins.
SELECT
  category,
  sub_category,
  ROUND(100 * SAFE_DIVIDE(SUM(cost_usd), SUM(gross_usd)), 1) AS cost_pct_of_list
FROM fashion_retail.v_sales
WHERE transaction_type = 'Sale'
GROUP BY category, sub_category
ORDER BY cost_pct_of_list DESC;

-- Result: all sub-categories 32.1%-35.1%. New Year sale sub-categories
-- 33.6%-35.1% (slightly above average).
-- Findings:
--   * At 40% off, 35% cost -> ~42% margin vs 33% cost -> ~45%: far too
--     small to explain ~4x lower profit/day. Thinner margins RULED OUT.
--   * New Year sale weakness must come from volume (fatigue or low
--     leftover stock).
--   * Uniform cost ratio across very different products is another sign
--     of the simulation (real product lines vary widely in markup).


-- ---------------------------------------------------------------------
-- 20. DASHBOARD TABLE — dash_daily (source for Looker Studio)
-- ---------------------------------------------------------------------
-- Pre-aggregates v_sales_promo to one row per date / transaction type /
-- country / sub-category / campaign so the dashboard doesn't re-scan
-- 6.4M rows and the range join on every chart load.
-- SNAPSHOT: re-run after any change to v_sales (e.g. updated FX rates).
-- Also translates local-language country names (TODO from query 5) and
-- replaces NULL campaign names with 'No campaign' (COALESCE).
CREATE OR REPLACE TABLE fashion_retail.dash_daily AS
SELECT
  sale_date,
  DATE_TRUNC(sale_date, MONTH)  AS month,
  transaction_type,
  CASE country
    WHEN '中国'        THEN 'China'
    WHEN 'Deutschland' THEN 'Germany'
    WHEN 'España'      THEN 'Spain'
    ELSE country
  END                            AS country,
  category,
  sub_category,
  campaign_type,
  COALESCE(campaign_name, 'No campaign') AS campaign_name,
  SUM(quantity)     AS units,
  SUM(gross_usd)    AS gross_usd,
  SUM(discount_usd) AS discount_usd,
  SUM(net_usd)      AS net_usd,
  SUM(cost_usd)     AS cost_usd
FROM fashion_retail.v_sales_promo
GROUP BY sale_date, month, transaction_type, country, category,
         sub_category, campaign_type, campaign_name;

-- Verification (written by Fabrizio): net revenue reconciles to $282.4M.
SELECT
  COUNT(*)                         AS row_count,
  ROUND(SUM(net_usd) / 1000000, 1) AS net_revenue_m
FROM fashion_retail.dash_daily;
