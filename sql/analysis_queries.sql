-- =========================================================================
-- OLIST CUSTOMER RETENTION ANALYSIS
-- SQL Analysis Queries (PostgreSQL 17)
-- Author: Akshitha
-- Data source: Brazilian E-Commerce Public Dataset by Olist (2016-2018)
-- =========================================================================
-- This file contains 4 analysis queries that reproduce the Python findings:
--   1. Repeat purchase rate (the 3.00% headline)
--   2. Monthly cohort retention analysis
--   3. RFM customer segmentation (8 segments)
--   4. Product category retention ranking
--
-- All queries filter to delivered orders only and use customer_unique_id
-- (NOT customer_id, which is order-level and misleadingly named).
-- =========================================================================


-- =========================================================================
-- QUERY 1: Repeat Purchase Rate
-- =========================================================================
-- Business question:
--   What % of Olist customers placed more than one delivered order?
--
-- Key insight:
--   Only 3.00% repeat rate — far below the 20-40% e-commerce benchmark.
-- =========================================================================

WITH customer_order_counts AS (
    -- Count distinct delivered orders per unique customer
    SELECT
        c.customer_unique_id,
        COUNT(DISTINCT o.order_id) AS order_count
    FROM olist_customers c
    INNER JOIN olist_orders o ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_unique_id
)
SELECT
    COUNT(*)                                        AS total_customers,
    COUNT(*) FILTER (WHERE order_count >= 2)        AS repeat_customers,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE order_count >= 2) / COUNT(*),
        2
    ) AS repeat_rate_pct
FROM customer_order_counts;


-- =========================================================================
-- QUERY 2: Monthly Cohort Retention Analysis
-- =========================================================================
-- Business question:
--   How does customer retention decay for each monthly cohort?
--
-- Output:
--   One row per (cohort_month, month_index) with the count of customers
--   from that cohort who placed an order X months after their first.
--
-- Key insight:
--   Retention drops ~99.5% from month 0 to month 1 across every cohort —
--   Olist has a retention "wall," not a gradual curve.
-- =========================================================================

WITH customer_orders AS (
    -- All delivered orders tagged with customer_unique_id + order_month
    SELECT
        c.customer_unique_id,
        o.order_id,
        o.order_purchase_timestamp,
        DATE_TRUNC('month', o.order_purchase_timestamp)::DATE AS order_month
    FROM olist_customers c
    INNER JOIN olist_orders o ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
),

customer_cohorts AS (
    -- Each customer's cohort = month of their FIRST delivered order
    SELECT
        customer_unique_id,
        MIN(order_month) AS cohort_month
    FROM customer_orders
    GROUP BY customer_unique_id
),

orders_with_cohort AS (
    -- Tag every order with its customer's cohort AND month_index
    SELECT
        co.customer_unique_id,
        co.order_id,
        co.order_month,
        cc.cohort_month,
        (EXTRACT(YEAR FROM co.order_month) - EXTRACT(YEAR FROM cc.cohort_month)) * 12
        + (EXTRACT(MONTH FROM co.order_month) - EXTRACT(MONTH FROM cc.cohort_month)) AS month_index
    FROM customer_orders co
    INNER JOIN customer_cohorts cc USING (customer_unique_id)
)

SELECT
    cohort_month,
    month_index,
    COUNT(DISTINCT customer_unique_id) AS active_customers
FROM orders_with_cohort
GROUP BY cohort_month, month_index
ORDER BY cohort_month, month_index;


-- =========================================================================
-- QUERY 3: RFM Customer Segmentation
-- =========================================================================
-- Business question:
--   How can we segment customers based on Recency, Frequency, and Monetary
--   value to inform retention strategy?
--
-- Method:
--   - Recency: days since last delivered order (lower = better)
--   - Frequency: number of distinct delivered orders (higher = better)
--   - Monetary: total spend (higher = better)
--   - Scores 1-5 assigned via NTILE (with custom frequency buckets because
--     97% of customers have frequency = 1, which breaks standard quintiles).
--
-- Key insight:
--   "Lost High-Value" (one-time buyers who spent big, never came back)
--   is the #1 revenue segment at R$ 3.8M (28.7% of total revenue).
-- =========================================================================

WITH snapshot_date AS (
    SELECT MAX(order_purchase_timestamp)::DATE + INTERVAL '1 day' AS snapshot
    FROM olist_orders
),

customer_orders AS (
    -- Delivered orders with total order value
    SELECT
        c.customer_unique_id,
        o.order_id,
        o.order_purchase_timestamp,
        SUM(oi.price) AS order_value
    FROM olist_customers c
    INNER JOIN olist_orders o ON c.customer_id = o.customer_id
    INNER JOIN olist_order_items oi ON o.order_id = oi.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_unique_id, o.order_id, o.order_purchase_timestamp
),

rfm_raw AS (
    SELECT
        customer_unique_id,
        (SELECT snapshot FROM snapshot_date)::DATE - MAX(order_purchase_timestamp)::DATE AS recency_days,
        COUNT(DISTINCT order_id) AS frequency,
        SUM(order_value)         AS monetary
    FROM customer_orders
    GROUP BY customer_unique_id
),

rfm_scored AS (
    SELECT
        customer_unique_id,
        recency_days,
        frequency,
        monetary,
        -- Recency: lower days = higher score (invert NTILE)
        6 - NTILE(5) OVER (ORDER BY recency_days) AS r_score,
        -- Frequency: manual buckets to handle the one-timer dominance
        CASE
            WHEN frequency = 1 THEN 1
            WHEN frequency = 2 THEN 3
            WHEN frequency BETWEEN 3 AND 4 THEN 4
            ELSE 5
        END AS f_score,
        NTILE(5) OVER (ORDER BY monetary) AS m_score
    FROM rfm_raw
)

SELECT
    CASE
        WHEN r_score >= 4 AND f_score >= 4                                      THEN 'Champions'
        WHEN f_score >= 3 AND r_score >= 3                                      THEN 'Loyal Customers'
        WHEN r_score >= 4 AND f_score = 3                                       THEN 'Potential Loyalists'
        WHEN f_score >= 3 AND r_score <= 2                                      THEN 'At Risk'
        WHEN r_score = 5 AND f_score = 1 AND m_score >= 4                       THEN 'New High-Value'
        WHEN r_score >= 4 AND f_score = 1                                       THEN 'Recent One-Timers'
        WHEN r_score <= 2 AND f_score = 1 AND m_score >= 4                      THEN 'Lost High-Value'
        WHEN r_score <= 2 AND f_score = 1                                       THEN 'Lost / Hibernating'
        ELSE                                                                         'Middle One-Timers'
    END                                      AS segment,
    COUNT(*)                                 AS customer_count,
    ROUND(AVG(monetary)::NUMERIC, 2)         AS avg_monetary,
    ROUND(SUM(monetary)::NUMERIC, 2)         AS total_revenue
FROM rfm_scored
GROUP BY 1
ORDER BY total_revenue DESC;


-- =========================================================================
-- QUERY 4: Product Category Retention Ranking
-- =========================================================================
-- Business question:
--   Which product categories produce the most repeat customers?
--
-- Method:
--   - For each customer, identify the category of their FIRST order
--     (using ROW_NUMBER window function).
--   - Calculate the % of first-in-category customers who became repeat buyers.
--   - Filter to categories with >= 500 customers for statistical reliability.
--
-- Key insight:
--   Home appliances (8.74%) retains 5.3x better than electronics (1.66%) —
--   counterintuitive finding: "durable" categories drive more repeat purchases.
-- =========================================================================

WITH delivered_order_items AS (
    -- Base: delivered order items joined with English category names
    SELECT
        c.customer_unique_id,
        o.order_id,
        o.order_purchase_timestamp,
        pt.product_category_name_english AS category
    FROM olist_customers c
    INNER JOIN olist_orders o           ON c.customer_id = o.customer_id
    INNER JOIN olist_order_items oi     ON o.order_id = oi.order_id
    INNER JOIN olist_products p         ON oi.product_id = p.product_id
    INNER JOIN product_category_translation pt
           ON p.product_category_name = pt.product_category_name
    WHERE o.order_status = 'delivered'
),

first_orders AS (
    -- Rank orders within each customer by timestamp
    SELECT
        customer_unique_id,
        category,
        ROW_NUMBER() OVER (
            PARTITION BY customer_unique_id
            ORDER BY order_purchase_timestamp, order_id
        ) AS order_rank
    FROM delivered_order_items
),

first_order_per_customer AS (
    SELECT customer_unique_id, category
    FROM first_orders
    WHERE order_rank = 1
),

customer_order_counts AS (
    SELECT
        customer_unique_id,
        COUNT(DISTINCT order_id) AS total_orders
    FROM delivered_order_items
    GROUP BY customer_unique_id
),

first_orders_with_repeat_flag AS (
    SELECT
        f.customer_unique_id,
        f.category,
        CASE WHEN c.total_orders >= 2 THEN 1 ELSE 0 END AS is_repeat
    FROM first_order_per_customer f
    INNER JOIN customer_order_counts c USING (customer_unique_id)
)

SELECT
    category,
    COUNT(*)                                    AS total_customers,
    SUM(is_repeat)                              AS repeat_customers,
    ROUND(100.0 * SUM(is_repeat) / COUNT(*), 2) AS repeat_rate_pct
FROM first_orders_with_repeat_flag
GROUP BY category
HAVING COUNT(*) >= 500
ORDER BY repeat_rate_pct DESC;


-- =========================================================================
-- END OF ANALYSIS QUERIES
-- =========================================================================