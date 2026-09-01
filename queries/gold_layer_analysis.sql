-- Explore All Objects in the Database
SELECT * FROM INFORMATION_SCHEMA.TABLES

-- Explore All Columns in the Database
SELECT * 
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'dim_customers' OR TABLE_NAME = 'fact_transactions';


---- one row per account with lifetime KPIs

DROP TABLE IF EXISTS gold.account_summary;
GO

SELECT
    a.account_number,
    a.customer_id,
    a.customer_name,
    a.account_type,
    a.branch,
    a.account_status,
    a.account_open_date,
    COUNT(c.transaction_id)                                   AS lifetime_txn_count,
    COALESCE(SUM(c.amount_signed), 0)                         AS net_lifetime_amount,
    COALESCE(SUM(CASE WHEN c.amount_signed > 0 THEN c.amount_signed END), 0)  AS lifetime_inflow,
    COALESCE(SUM(CASE WHEN c.amount_signed < 0 THEN -c.amount_signed END), 0) AS lifetime_outflow,
    MAX(c.transaction_date)                                   AS last_transaction_date,
    SUM(CASE WHEN c.is_amount_outlier = 1 THEN 1 ELSE 0 END)  AS outlier_txn_count,
    SUM(CASE WHEN c.status = 'Failed' THEN 1 ELSE 0 END)      AS failed_txn_count
INTO gold.account_summary
FROM gold.dim_customers a
LEFT JOIN gold.fact_transactions c
    ON c.account_number = a.account_number AND c.is_orphan_account = 0
GROUP BY 
    a.account_number,
    a.customer_id,
    a.customer_name,
    a.account_type,
    a.branch,
    a.account_status,
    a.account_open_date;

    select * from gold.account_summary
    
-- Monthly business summary
DROP TABLE IF EXISTS gold.monthly_summary;
GO

SELECT
    CAST(DATETRUNC(month, c.transaction_date) AS DATE)        AS txn_month,
    COUNT(*)                                                  AS txn_count,
    COUNT(DISTINCT c.account_number)                          AS active_accounts,
    COALESCE(SUM(CASE WHEN c.amount_signed > 0 THEN c.amount_signed END),0)  AS total_inflow,
    COALESCE(SUM(CASE WHEN c.amount_signed < 0 THEN -c.amount_signed END), 0) AS total_outflow,
    SUM(c.amount_signed)                                      AS net_amount,
    ROUND(AVG(ABS(c.amount_signed)), 2)                       AS avg_txn_amount,
    SUM(CASE WHEN c.status = 'Failed' THEN 1 ELSE 0 END)      AS failed_txn_count,
    SUM(CASE WHEN c.is_amount_outlier = 1 THEN 1 ELSE 0 END)  AS outlier_txn_count
INTO gold.monthly_summary 
FROM gold.fact_transactions c
WHERE c.status != 'Failed' OR c.status IS NULL
GROUP BY CAST(DATETRUNC(month, c.transaction_date) AS DATE)
ORDER BY CAST(DATETRUNC(month, c.transaction_date) AS DATE);

select * from gold.monthly_summary

-- Transaction type / channel breakdown 
DROP TABLE IF EXISTS gold.type_channel_summary;
GO

SELECT
    transaction_type,
    channel,
    COUNT(*)                              AS txn_count,
    SUM(ABS(amount_signed))               AS total_volume,
    ROUND(AVG(ABS(amount_signed)), 2)     AS avg_amount
INTO gold.type_channel_summary 
FROM gold.fact_transactions
WHERE is_orphan_account = 0
GROUP BY transaction_type,
         channel
ORDER BY total_volume DESC;

select * from gold.type_channel_summary

-- Branch performance 
DROP TABLE IF EXISTS gold.branch_performance;

SELECT
    a.branch,
    COUNT(DISTINCT a.account_number)                          AS account_count,
    COUNT(c.transaction_id)                                    AS txn_count,
    COALESCE(SUM(CASE WHEN c.amount_signed > 0 THEN c.amount_signed END),0)  AS total_inflow,
    COALESCE(SUM(CASE WHEN c.amount_signed < 0 THEN -c.amount_signed END), 0) AS total_outflow,
    ROUND(AVG(ABS(c.amount_signed)), 2)                        AS avg_txn_amount,
   SUM(CASE WHEN c.status = 'Failed' THEN 1 ELSE 0 END)      AS failed_txn_count,
    SUM(CASE WHEN c.is_amount_outlier = 1 THEN 1 ELSE 0 END)  AS outlier_txn_count
INTO gold.branch_performance 
FROM gold.dim_customers a
LEFT JOIN gold.fact_transactions c
    ON c.account_number = a.account_number AND c.is_orphan_account = 0
GROUP BY a.branch
ORDER BY txn_count DESC;

select * from gold.branch_performance

-- Customer segmentation (simple RFM-style tiers)
DROP TABLE IF EXISTS gold.customer_segments;
GO

WITH rfm AS (
    SELECT
        a.customer_id,
        a.account_number,
        a.customer_name,
        DATEDIFF(day, CAST(a.last_transaction_date AS DATE), GETDATE()) AS days_since_last_txn,
        a.lifetime_txn_count                                   AS frequency,
        a.net_lifetime_amount                                  AS monetary
    FROM gold.account_summary a
)
SELECT
    *,
    CASE
        WHEN frequency = 0                                    THEN 'Dormant / No Activity'
        WHEN days_since_last_txn <= 90  AND frequency >= 10   THEN 'Active - High Engagement'
        WHEN days_since_last_txn <= 90                         THEN 'Active - Regular'
        WHEN days_since_last_txn <= 365                        THEN 'At Risk'
        ELSE 'Churned / Inactive'
    END                                                        AS segment
INTO gold.customer_segments 
FROM rfm;

select * from gold.customer_segments

-- Data-quality exceptions log (for the analysis writeup)
DROP TABLE IF EXISTS gold.dq_exceptions;
GO

SELECT transaction_id, account_number, transaction_date, amount_signed,
       'Orphan account_number (no matching account in gold.dim_customers)' AS issue
INTO gold.dq_exceptions
FROM gold.fact_transactions 
WHERE is_orphan_account = 1

UNION ALL

SELECT transaction_id, account_number, transaction_date, amount_signed,
       'Transaction predates the account open date'
FROM gold.fact_transactions 
WHERE is_predates_account_open = 1

UNION ALL

SELECT transaction_id, account_number, transaction_date, amount_signed,
       'Amount is a statistical outlier (> 400,000)'
FROM gold.fact_transactions 
WHERE is_amount_outlier = 1

UNION ALL

SELECT transaction_id, account_number, transaction_date, amount_signed,
       'Amount missing in source data'
FROM gold.fact_transactions 
WHERE is_amount_missing = 1;

select * from gold.dq_exceptions

-- Top 10 accounts by lifetime net inflow
 SELECT 
 TOP 10
 account_number, customer_name, net_lifetime_amount
 FROM gold.account_summary
 ORDER BY net_lifetime_amount DESC
 
 -- Month-over-month net amount trend
SELECT txn_month, net_amount,
       net_amount - LAG(net_amount) OVER (ORDER BY txn_month) AS mom_change
FROM gold.monthly_summary
ORDER BY txn_month;

-- Customer segment distribution
SELECT segment, COUNT(*) AS customers, SUM(monetary) AS total_monetary
FROM gold.customer_segments
GROUP BY segment
ORDER BY customers DESC;

-- Branches with the highest failed-transaction rate
SELECT branch,
        ROUND(100.0 * SUM(failed_txn_count) / NULLIF(SUM(txn_count), 0), 2) AS failed_rate_pct
FROM gold.branch_performance
GROUP BY branch
ORDER BY failed_rate_pct DESC;

-- All open data-quality exceptions, most recent first
SELECT * FROM gold.dq_exceptions ORDER BY transaction_date DESC;
