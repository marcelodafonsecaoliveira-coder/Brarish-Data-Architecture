-- Brarish Data Architecture — SQL Queries
-- Author: Marcelo da Fonseca Oliveira
-- City Colleges of Dublin | 2026

-- 1. Data Quality Completeness Check
SELECT
  SAFE_DIVIDE(COUNT(transaction_id), 55000) > 0.98 AS passes_check
FROM Transaction_Fact
WHERE date = CURRENT_DATE();

-- 2. Fraud Rate KPI by Residency and Hour
SELECT
  c.residency_cd,
  EXTRACT(HOUR FROM t.transaction_timestamp) AS hour_of_day,
  COUNT(t.transaction_sk)                    AS total_transactions,
  COUNTIF(t.fraud_score >= 0.8)              AS flagged_transactions,
  SAFE_DIVIDE(
    COUNTIF(t.fraud_score >= 0.8),
    COUNT(t.transaction_sk)
  )                                          AS fraud_rate
FROM Transaction_Fact t
JOIN Customer_Dim c ON t.customer_sk = c.customer_sk
WHERE t.date = CURRENT_DATE()
GROUP BY c.residency_cd, hour_of_day
ORDER BY fraud_rate DESC;

-- 3. Tax Leakage KPI by Fiscal Quarter
SELECT
  d.fiscal_year_ie,
  d.quarter,
  c.residency_cd                          AS country,
  SUM(t.tax_withheld)                     AS total_tax_withheld,
  SUM(t.amount_eur * tr.rate_pct)         AS expected_tax,
  SAFE_DIVIDE(
    SUM(t.amount_eur * tr.rate_pct) - SUM(t.tax_withheld),
    SUM(t.amount_eur * tr.rate_pct)
  )                                       AS leakage_pct
FROM Transaction_Fact t
JOIN Customer_Dim  c  ON t.customer_sk   = c.customer_sk
JOIN Date_Dim      d  ON t.date_sk       = d.date_sk
JOIN TaxRate_Dim   tr ON t.tax_period_sk = tr.tax_period_sk
GROUP BY d.fiscal_year_ie, d.quarter, c.residency_cd
ORDER BY leakage_pct DESC;

-- 4. Top Customers Generating Fraud Alerts
SELECT
  c.customer_sk,
  c.residency_cd,
  COUNT(t.transaction_sk)       AS total_transactions,
  COUNTIF(t.fraud_score >= 0.8) AS fraud_alerts,
  ROUND(AVG(t.fraud_score), 4)  AS avg_fraud_score
FROM Transaction_Fact t
JOIN Customer_Dim c ON t.customer_sk = c.customer_sk
GROUP BY c.customer_sk, c.residency_cd
ORDER BY fraud_alerts DESC
LIMIT 50;
