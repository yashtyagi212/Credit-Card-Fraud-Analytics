select current_database();

transaction_id   TEXT PRIMARY KEY,
customer_id     TEXT NOT NULL,
merchant_id     TEXT NOT NULL,
transaction_datetime  TIMESTAMP WITHOUT TIME ZONE NOT NULL,
transaction_amount   NUMERIC(18, 2) NOT NULL,
merchant_category TEXT,
merchant_country  TEXT,
card_present  SMALLINT,
customer_age  INTEGER,
account_age_days  INTEGER,
is_fraud  BOOLEAN NOT NULL,


SELECT
    COUNT(*) AS total_transactions,
    COUNT(*) FILTER (WHERE is_fraud) AS fraud_transactions
FROM public.transactions;


SELECT
    COUNT(*) AS total_transactions,
    COUNT(DISTINCT customer_id) AS unique_customers,
    COUNT(DISTINCT merchant_id) AS unique_merchants,

    COUNT(*) FILTER (WHERE is_fraud) AS fraud_transactions,

    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_fraud)
        / NULLIF(COUNT(*), 0),
        3
    ) AS fraud_rate_pct,

    SUM(transaction_amount) AS total_transaction_amount,

    COALESCE(
        SUM(transaction_amount) FILTER (WHERE is_fraud),
        0
    ) AS fraudulent_transaction_amount

FROM public.transactions;




SELECT
    merchant_category,
    COUNT(*) AS total_transactions,
    COUNT(*) FILTER (WHERE is_fraud) AS fraud_transactions,

    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_fraud)
        / NULLIF(COUNT(*), 0),
        2
    ) AS fraud_rate_pct,

    COALESCE(
        SUM(transaction_amount) FILTER (WHERE is_fraud),
        0
    ) AS fraudulent_transaction_amount

FROM public.transactions
GROUP BY merchant_category
ORDER BY fraud_rate_pct DESC, total_transactions DESC;




WITH transaction_segments AS (
    SELECT
        CASE
            WHEN account_age_days IS NULL THEN 'Unknown'
            WHEN account_age_days <= 90 THEN 'Newer: 0–90 days'
            ELSE 'Older: 91+ days'
        END AS account_group,

        CASE
            WHEN card_present = 0 THEN 'Card not present'
            WHEN card_present = 1 THEN 'Card present'
            ELSE 'Unknown'
        END AS card_status,

        is_fraud
    FROM public.transactions
),
segment_summary AS (
    SELECT
        account_group,
        card_status,
        COUNT(*) AS total_transactions,
        COUNT(*) FILTER (WHERE is_fraud) AS fraud_transactions
    FROM transaction_segments
    GROUP BY account_group, card_status
),
baseline AS (
    SELECT
        COUNT(*) FILTER (WHERE is_fraud)::NUMERIC
        / NULLIF(COUNT(*), 0) AS overall_fraud_rate
    FROM public.transactions
)
SELECT
    s.account_group,
    s.card_status,
    s.total_transactions,
    s.fraud_transactions,

    ROUND(
        100.0 * s.fraud_transactions
        / NULLIF(s.total_transactions, 0),
        2
    ) AS fraud_rate_pct,

    ROUND(
        (s.fraud_transactions::NUMERIC
         / NULLIF(s.total_transactions, 0))
        / NULLIF(b.overall_fraud_rate, 0),
        2
    ) AS fraud_rate_lift

FROM segment_summary AS s
CROSS JOIN baseline AS b
ORDER BY fraud_rate_pct DESC NULLS LAST;




WITH monthly_summary AS (
    SELECT
        DATE_TRUNC('month', transaction_datetime)::DATE AS month,
        COUNT(*) AS total_transactions,
        COUNT(*) FILTER (WHERE is_fraud) AS fraud_transactions,

        100.0 * COUNT(*) FILTER (WHERE is_fraud)
        / NULLIF(COUNT(*), 0) AS fraud_rate_pct

    FROM public.transactions
    GROUP BY DATE_TRUNC('month', transaction_datetime)::DATE
),
monthly_comparison AS (
    SELECT
        *,
        LAG(fraud_rate_pct) OVER (
            ORDER BY month
        ) AS previous_month_fraud_rate
    FROM monthly_summary
)
SELECT
    month,
    total_transactions,
    fraud_transactions,
    ROUND(fraud_rate_pct, 2) AS fraud_rate_pct,
    ROUND(previous_month_fraud_rate, 2) AS previous_month_rate_pct,

    ROUND(
        fraud_rate_pct - previous_month_fraud_rate,
        2
    ) AS change_percentage_points

FROM monthly_comparison
ORDER BY month;




WITH merchant_metrics AS (
    SELECT
        merchant_id,
        merchant_category,
        COUNT(*) AS total_transactions,
        COUNT(*) FILTER (WHERE is_fraud) AS fraud_transactions,
        COALESCE(
            SUM(transaction_amount) FILTER (WHERE is_fraud),
            0
        ) AS fraudulent_transaction_amount
    FROM public.transactions
    GROUP BY merchant_id, merchant_category
),

category_metrics AS (
    SELECT
        merchant_category,
        COUNT(*) AS category_transactions,
        COUNT(*) FILTER (WHERE is_fraud) AS category_fraud
    FROM public.transactions
    GROUP BY merchant_category
),

peer_comparison AS (
    SELECT
        m.*,

        m.fraud_transactions::NUMERIC
            / NULLIF(m.total_transactions, 0) AS merchant_fraud_rate,

        -- Exclude this merchant from its category benchmark.
        (c.category_fraud - m.fraud_transactions)::NUMERIC
            / NULLIF(
                c.category_transactions - m.total_transactions,
                0
            ) AS peer_fraud_rate

    FROM merchant_metrics AS m
    JOIN category_metrics AS c
        ON m.merchant_category IS NOT DISTINCT FROM c.merchant_category

    WHERE m.total_transactions >= 30
      AND m.fraud_transactions >= 3
),

risk_metrics AS (
    SELECT
        *,

        merchant_fraud_rate
            / NULLIF(peer_fraud_rate, 0) AS peer_rate_lift,

        fraud_transactions
            - (total_transactions * peer_fraud_rate)
            AS excess_fraud_cases

    FROM peer_comparison
    WHERE peer_fraud_rate IS NOT NULL
),

ranked_merchants AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            ORDER BY
                excess_fraud_cases DESC,
                fraudulent_transaction_amount DESC,
                merchant_id,
                merchant_category
        ) AS review_rank

    FROM risk_metrics
    WHERE excess_fraud_cases > 0
)

SELECT
    review_rank,
    merchant_id,
    merchant_category,
    total_transactions,
    fraud_transactions,
    ROUND(100 * merchant_fraud_rate, 2) AS merchant_fraud_rate_pct,
    ROUND(100 * peer_fraud_rate, 2) AS category_peer_rate_pct,
    ROUND(peer_rate_lift, 2) AS peer_rate_lift,
    ROUND(excess_fraud_cases, 2) AS excess_fraud_cases,
    fraudulent_transaction_amount

FROM ranked_merchants
WHERE review_rank <= 20
ORDER BY review_rank;




WITH rolling_activity AS (
    SELECT
        transaction_id,
        customer_id,
        merchant_id,
        transaction_datetime,
        transaction_amount,
        is_fraud,

        COUNT(*) OVER recent_activity AS transactions_in_10min,

        SUM(transaction_amount) OVER recent_activity
            AS amount_in_10min

    FROM public.transactions

    WINDOW recent_activity AS (
        PARTITION BY customer_id
        ORDER BY transaction_datetime
        RANGE BETWEEN INTERVAL '10 minutes' PRECEDING
                  AND CURRENT ROW
    )
),

candidate_transactions AS (
    SELECT *
    FROM rolling_activity
    WHERE transactions_in_10min >= 3
),

merchant_activity AS (
    SELECT
        c.*,
        m.distinct_merchants

    FROM candidate_transactions AS c

    CROSS JOIN LATERAL (
        SELECT
            COUNT(DISTINCT t.merchant_id) AS distinct_merchants

        FROM public.transactions AS t

        WHERE t.customer_id = c.customer_id
          AND t.transaction_datetime BETWEEN
              c.transaction_datetime - INTERVAL '10 minutes'
              AND c.transaction_datetime
    ) AS m

    WHERE m.distinct_merchants >= 2
)

SELECT
    transaction_id,
    customer_id,
    transaction_datetime,
    transaction_amount,
    transactions_in_10min,
    amount_in_10min,
    distinct_merchants,
    is_fraud AS actual_fraud_for_review

FROM merchant_activity

ORDER BY
    transactions_in_10min DESC,
    amount_in_10min DESC,
    transaction_id

LIMIT 50;






WITH customer_activity AS (
    SELECT
        transaction_id,
        customer_id,
        transaction_datetime,

        COUNT(*) OVER (
            PARTITION BY customer_id
            ORDER BY transaction_datetime
            RANGE BETWEEN INTERVAL '10 minutes' PRECEDING
                      AND CURRENT ROW
        ) AS transactions_in_10min

    FROM public.transactions
)

SELECT *
FROM customer_activity
ORDER BY
    transactions_in_10min DESC,
    transaction_datetime
LIMIT 10;



CREATE INDEX IF NOT EXISTS idx_transactions_customer_datetime
ON public.transactions (customer_id, transaction_datetime);





WITH customer_history AS (
    SELECT
        t.transaction_id,
        t.customer_id,
        t.transaction_datetime,
        t.transaction_amount,
        t.is_fraud,

        h.previous_transactions,
        h.previous_avg_amount,
        h.previous_stddev_amount

    FROM public.transactions AS t

    CROSS JOIN LATERAL (
        SELECT
            COUNT(*) AS previous_transactions,
            AVG(p.transaction_amount) AS previous_avg_amount,
            STDDEV_SAMP(p.transaction_amount) AS previous_stddev_amount

        FROM public.transactions AS p

        WHERE p.customer_id = t.customer_id
          AND p.transaction_datetime < t.transaction_datetime
    ) AS h
),

spending_comparison AS (
    SELECT
        *,
        transaction_amount
            / NULLIF(previous_avg_amount, 0) AS amount_ratio,

        (transaction_amount - previous_avg_amount)
            / NULLIF(previous_stddev_amount, 0) AS spending_z_score

    FROM customer_history
    WHERE previous_transactions >= 5
)

SELECT
    transaction_id,
    customer_id,
    transaction_datetime,
    previous_transactions,
    transaction_amount,
    ROUND(previous_avg_amount, 2) AS previous_avg_amount,
    ROUND(amount_ratio, 2) AS amount_ratio,
    ROUND(spending_z_score, 2) AS spending_z_score,
    is_fraud AS actual_fraud_for_review

FROM spending_comparison
WHERE amount_ratio >= 3
ORDER BY amount_ratio DESC, transaction_id
LIMIT 50;




WITH customer_history AS (
    SELECT
        t.transaction_id,
        t.transaction_amount,
        t.is_fraud,
        h.previous_transactions,
        h.previous_avg_amount

    FROM public.transactions AS t

    CROSS JOIN LATERAL (
        SELECT
            COUNT(*) AS previous_transactions,
            AVG(p.transaction_amount) AS previous_avg_amount

        FROM public.transactions AS p

        WHERE p.customer_id = t.customer_id
          AND p.transaction_datetime < t.transaction_datetime
    ) AS h
),

rule_flags AS (
    SELECT
        *,
        (
            previous_transactions >= 5
            AND previous_avg_amount > 0
        ) AS is_eligible,

        COALESCE(
            previous_transactions >= 5
            AND previous_avg_amount > 0
            AND transaction_amount >= 3 * previous_avg_amount,
            FALSE
        ) AS is_alert

    FROM customer_history
),

rule_metrics AS (
    SELECT
        COUNT(*) AS total_transactions,
        COUNT(*) FILTER (WHERE is_eligible) AS eligible_transactions,
        COUNT(*) FILTER (WHERE is_fraud) AS total_fraud,
        COUNT(*) FILTER (
            WHERE is_eligible AND is_fraud
        ) AS eligible_fraud,

        COUNT(*) FILTER (WHERE is_alert) AS total_alerts,

        COUNT(*) FILTER (
            WHERE is_alert AND is_fraud
        ) AS fraud_detected,

        COUNT(*) FILTER (
            WHERE is_alert AND NOT is_fraud
        ) AS false_alerts,

        COUNT(*) FILTER (
            WHERE NOT is_alert AND is_fraud
        ) AS fraud_not_flagged

    FROM rule_flags
)

SELECT
    total_transactions,
    eligible_transactions,
    total_alerts,
    fraud_detected,
    false_alerts,
    fraud_not_flagged,

    ROUND(
        100.0 * eligible_transactions
        / NULLIF(total_transactions, 0), 2
    ) AS coverage_pct,

    ROUND(
        100.0 * fraud_detected
        / NULLIF(total_alerts, 0), 2
    ) AS precision_pct,

    ROUND(
        100.0 * fraud_detected
        / NULLIF(total_fraud, 0), 2
    ) AS overall_recall_pct,

    ROUND(
        100.0 * fraud_detected
        / NULLIF(eligible_fraud, 0), 2
    ) AS eligible_recall_pct

FROM rule_metrics;





WITH monthly_category_metrics AS (
    SELECT
        DATE_TRUNC('month', transaction_datetime)::DATE AS month,
        COALESCE(merchant_category, 'Unknown') AS merchant_category,

        COUNT(*) AS total_transactions,
        COUNT(*) FILTER (WHERE is_fraud) AS fraud_transactions,

        COALESCE(
            SUM(transaction_amount) FILTER (WHERE is_fraud),
            0
        ) AS fraudulent_transaction_amount

    FROM public.transactions
    GROUP BY
        DATE_TRUNC('month', transaction_datetime)::DATE,
        COALESCE(merchant_category, 'Unknown')
),

category_contribution AS (
    SELECT
        *,

        SUM(fraudulent_transaction_amount) OVER (
            PARTITION BY month
        ) AS monthly_fraudulent_amount,

        ROW_NUMBER() OVER (
            PARTITION BY month
            ORDER BY
                fraudulent_transaction_amount DESC,
                fraud_transactions DESC,
                merchant_category
        ) AS category_rank

    FROM monthly_category_metrics
),

ranked_contribution AS (
    SELECT
        *,

        SUM(fraudulent_transaction_amount) OVER (
            PARTITION BY month
            ORDER BY category_rank
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative_fraudulent_amount

    FROM category_contribution
)

SELECT
    month,
    category_rank,
    merchant_category,
    total_transactions,
    fraud_transactions,

    ROUND(
        100.0 * fraud_transactions
        / NULLIF(total_transactions, 0),
        2
    ) AS fraud_rate_pct,

    fraudulent_transaction_amount,

    ROUND(
        100.0 * fraudulent_transaction_amount
        / NULLIF(monthly_fraudulent_amount, 0),
        2
    ) AS monthly_amount_share_pct,

    ROUND(
        100.0 * cumulative_fraudulent_amount
        / NULLIF(monthly_fraudulent_amount, 0),
        2
    ) AS cumulative_share_pct

FROM ranked_contribution
WHERE category_rank <= 3
ORDER BY month, category_rank;





CREATE TABLE public.model_predictions (
    transaction_id       TEXT PRIMARY KEY,
    fraud_score          DOUBLE PRECISION NOT NULL,
    review_rank          INTEGER NOT NULL UNIQUE,
    selected_for_review  BOOLEAN NOT NULL,

    CONSTRAINT fk_prediction_transaction
        FOREIGN KEY (transaction_id)
        REFERENCES public.transactions (transaction_id),

    CONSTRAINT chk_fraud_score
        CHECK (fraud_score >= 0 AND fraud_score <= 1),

    CONSTRAINT chk_review_rank
        CHECK (review_rank >= 1)
);





SELECT
    COUNT(*) AS scored_transactions,
    COUNT(*) FILTER (
        WHERE selected_for_review




WITH evaluation AS (
    SELECT
        t.is_fraud,
        p.selected_for_review
    FROM public.model_predictions AS p
    INNER JOIN public.transactions AS t
        ON p.transaction_id = t.transaction_id
),

metrics AS (
    SELECT
        COUNT(*) AS test_transactions,

        COUNT(*) FILTER (
            WHERE selected_for_review
        ) AS reviewed_transactions,

        COUNT(*) FILTER (
            WHERE selected_for_review AND is_fraud
        ) AS fraud_detected,

        COUNT(*) FILTER (
            WHERE selected_for_review AND NOT is_fraud
        ) AS false_alerts,

        COUNT(*) FILTER (
            WHERE NOT selected_for_review AND is_fraud
        ) AS fraud_missed,

        COUNT(*) FILTER (
            WHERE is_fraud
        ) AS total_fraud

    FROM evaluation
)

SELECT
    test_transactions,
    reviewed_transactions,
    fraud_detected,
    false_alerts,
    fraud_missed,

    ROUND(
        100.0 * fraud_detected
        / NULLIF(reviewed_transactions, 0),
        2
    ) AS precision_pct,

    ROUND(
        100.0 * fraud_detected
        / NULLIF(total_fraud, 0),
        2
    ) AS recall_pct

FROM metrics;
    ) AS selected_transactions
FROM public.model_predictions;



CREATE OR REPLACE VIEW public.vw_monthly_fraud_summary AS
SELECT
    DATE_TRUNC('month', transaction_datetime)::DATE AS month,
    COUNT(*) AS total_transactions,
    COUNT(*) FILTER (WHERE is_fraud) AS fraud_transactions,

    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_fraud)
        / NULLIF(COUNT(*), 0),
        3
    ) AS fraud_rate_pct,

    SUM(transaction_amount) AS total_transaction_amount,

    COALESCE(
        SUM(transaction_amount) FILTER (WHERE is_fraud),
        0
    ) AS fraudulent_transaction_amount

FROM public.transactions
GROUP BY DATE_TRUNC('month', transaction_datetime)::DATE;



SELECT *
FROM public.vw_monthly_fraud_summary
ORDER BY month;




SELECT *
FROM public.vw_test_investigation
WHERE selected_for_review
ORDER BY review_rank
LIMIT 20;