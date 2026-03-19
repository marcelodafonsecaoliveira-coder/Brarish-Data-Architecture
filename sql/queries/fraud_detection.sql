-- =====================================================
-- Brarish Data Platform - Fraud Detection Analytics
-- =====================================================
-- Purpose: Real-time fraud detection queries and alerting
-- Author: Marcelo Fonseca
-- SLA: P99 <1 second query latency
-- =====================================================

-- =====================================================
-- Query 1: High-Risk Transactions (Real-Time Alerting)
-- =====================================================
-- Identifies transactions with fraud_score > 0.8
-- Triggers manual review workflow via Cloud Functions
-- =====================================================

WITH high_risk_transactions AS (
  SELECT 
    t.transaction_id,
    t.customer_sk,
    c.cpf_token,
    c.current_residency_cd,
    t.amount_eur,
    t.amount_brl,
    t.fraud_score,
    t.fraud_reason,
    t.origin_country,
    t.destination_country,
    t.ingestion_timestamp,
    
    -- Enrich with customer history
    AVG(t2.fraud_score) OVER (
      PARTITION BY t.customer_sk 
      ORDER BY t2.ingestion_timestamp
      ROWS BETWEEN 30 PRECEDING AND 1 PRECEDING
    ) as avg_fraud_score_30d,
    
    COUNT(*) OVER (
      PARTITION BY t.customer_sk
      ORDER BY t2.ingestion_timestamp
      RANGE BETWEEN INTERVAL 1 HOUR PRECEDING AND CURRENT ROW
    ) as tx_count_last_hour
    
  FROM `curated.transaction_fact` t
  JOIN `curated.customer_dim` c
    ON t.customer_sk = c.customer_sk
  LEFT JOIN `curated.transaction_fact` t2
    ON t.customer_sk = t2.customer_sk
  
  WHERE t.fraud_score > 0.8
    AND DATE(t.ingestion_timestamp) = CURRENT_DATE()
    AND c.valid_to IS NULL  -- Current customer record only (SCD2)
)

SELECT 
  transaction_id,
  customer_sk,
  cpf_token,
  current_residency_cd,
  amount_eur,
  fraud_score,
  fraud_reason,
  tx_count_last_hour,
  
  -- Risk classification
  CASE 
    WHEN fraud_score > 0.95 THEN 'CRITICAL'
    WHEN fraud_score > 0.9 THEN 'HIGH'
    ELSE 'ELEVATED'
  END as risk_level,
  
  -- Velocity check
  CASE 
    WHEN tx_count_last_hour > 10 THEN 'VELOCITY_ANOMALY'
    ELSE 'NORMAL'
  END as velocity_flag,
  
  -- Amount threshold
  CASE 
    WHEN amount_eur > 10000 THEN 'LARGE_AMOUNT'
    ELSE 'STANDARD'
  END as amount_flag,
  
  ingestion_timestamp
  
FROM high_risk_transactions

ORDER BY fraud_score DESC, ingestion_timestamp DESC

LIMIT 100;


-- =====================================================
-- Query 2: Fraud Rate Trend by Country (BI Dashboard)
-- =====================================================
-- Powers Looker Studio "Fraud Analytics" dashboard
-- Refreshes every 5 minutes via Cloud Scheduler
-- =====================================================

SELECT 
  DATE(t.ingestion_timestamp) as transaction_date,
  t.origin_country,
  t.destination_country,
  
  -- Volume metrics
  COUNT(*) as total_transactions,
  COUNT(DISTINCT t.customer_sk) as unique_customers,
  
  -- Fraud metrics
  SUM(CASE WHEN t.fraud_score > 0.8 THEN 1 ELSE 0 END) as high_risk_count,
  ROUND(SUM(CASE WHEN t.fraud_score > 0.8 THEN 1 ELSE 0 END) / COUNT(*) * 100, 2) as fraud_rate_pct,
  
  -- Financial impact
  SUM(t.amount_eur) as total_volume_eur,
  SUM(CASE WHEN t.fraud_score > 0.8 THEN t.amount_eur ELSE 0 END) as flagged_volume_eur,
  
  -- Average scores
  ROUND(AVG(t.fraud_score), 3) as avg_fraud_score,
  ROUND(AVG(t.processing_latency_ms), 0) as avg_latency_ms,
  
  -- Compliance
  ROUND(SUM(CASE WHEN t.kyc_verified THEN 1 ELSE 0 END) / COUNT(*) * 100, 2) as kyc_verified_pct

FROM `curated.transaction_fact` t

WHERE DATE(t.ingestion_timestamp) >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)

GROUP BY 
  transaction_date,
  origin_country,
  destination_country

HAVING total_transactions >= 10  -- Filter out low-volume corridors

ORDER BY 
  transaction_date DESC,
  fraud_rate_pct DESC;


-- =====================================================
-- Query 3: Customer Fraud History (Forensic Analysis)
-- =====================================================
-- Used by fraud investigators for deep-dive analysis
-- Supports residency change correlation with fraud
-- =====================================================

WITH customer_timeline AS (
  SELECT 
    t.customer_sk,
    c.cpf_token,
    c.residency_cd,
    c.valid_from as residency_start,
    c.valid_to as residency_end,
    
    -- Transaction aggregations per residency period
    COUNT(*) as tx_count,
    SUM(t.amount_eur) as total_volume_eur,
    AVG(t.fraud_score) as avg_fraud_score,
    SUM(CASE WHEN t.fraud_score > 0.8 THEN 1 ELSE 0 END) as high_risk_tx_count,
    
    MIN(t.ingestion_timestamp) as first_tx_timestamp,
    MAX(t.ingestion_timestamp) as last_tx_timestamp
    
  FROM `curated.customer_dim` c
  LEFT JOIN `curated.transaction_fact` t
    ON c.customer_sk = t.customer_sk
    AND t.ingestion_timestamp BETWEEN c.valid_from AND COALESCE(c.valid_to, CURRENT_TIMESTAMP())
  
  WHERE c.cpf_token = @customer_cpf_token  -- Parameter from investigation UI
  
  GROUP BY 
    t.customer_sk,
    c.cpf_token,
    c.residency_cd,
    c.valid_from,
    c.valid_to
)

SELECT 
  cpf_token,
  residency_cd,
  residency_start,
  residency_end,
  
  -- Behavioral metrics
  tx_count,
  total_volume_eur,
  ROUND(avg_fraud_score, 3) as avg_fraud_score,
  high_risk_tx_count,
  ROUND(high_risk_tx_count / NULLIF(tx_count, 0) * 100, 2) as fraud_tx_pct,
  
  -- Time analysis
  first_tx_timestamp,
  last_tx_timestamp,
  DATE_DIFF(COALESCE(residency_end, CURRENT_TIMESTAMP()), residency_start, DAY) as residency_duration_days,
  
  -- Red flags
  CASE 
    WHEN high_risk_tx_count > 0 AND tx_count <= 5 THEN '🚨 Immediate fraud after onboarding'
    WHEN ROUND(high_risk_tx_count / NULLIF(tx_count, 0) * 100, 2) > 30 THEN '⚠️ High fraud rate'
    WHEN residency_end IS NOT NULL AND tx_count = 0 THEN '❓ Residency change without transactions'
    ELSE '✅ Normal pattern'
  END as investigation_notes

FROM customer_timeline

ORDER BY residency_start DESC;


-- =====================================================
-- Query 4: Pareto Analysis (80/20 Rule)
-- =====================================================
-- Identifies top 10% customers generating 80% fraud alerts
-- Used for targeted intervention strategies
-- =====================================================

WITH customer_fraud_metrics AS (
  SELECT 
    t.customer_sk,
    c.cpf_token,
    c.current_residency_cd,
    
    COUNT(*) as total_tx,
    SUM(CASE WHEN t.fraud_score > 0.8 THEN 1 ELSE 0 END) as fraud_alerts,
    SUM(t.amount_eur) as lifetime_volume_eur,
    
    -- Customer lifetime value vs risk
    SUM(t.amount_eur) / NULLIF(SUM(CASE WHEN t.fraud_score > 0.8 THEN 1 ELSE 0 END), 0) as value_per_alert
    
  FROM `curated.transaction_fact` t
  JOIN `curated.customer_dim` c
    ON t.customer_sk = c.customer_sk
  WHERE c.valid_to IS NULL  -- Current records only
  
  GROUP BY 
    t.customer_sk,
    c.cpf_token,
    c.current_residency_cd
  
  HAVING fraud_alerts > 0
),

ranked_customers AS (
  SELECT 
    *,
    SUM(fraud_alerts) OVER () as total_fraud_alerts,
    SUM(fraud_alerts) OVER (ORDER BY fraud_alerts DESC) as cumulative_fraud_alerts,
    ROW_NUMBER() OVER (ORDER BY fraud_alerts DESC) as customer_rank,
    COUNT(*) OVER () as total_customers
  FROM customer_fraud_metrics
)

SELECT 
  customer_rank,
  cpf_token,
  current_residency_cd,
  total_tx,
  fraud_alerts,
  lifetime_volume_eur,
  
  -- Pareto metrics
  ROUND(fraud_alerts / total_fraud_alerts * 100, 2) as pct_of_total_alerts,
  ROUND(cumulative_fraud_alerts / total_fraud_alerts * 100, 2) as cumulative_pct,
  ROUND(customer_rank / total_customers * 100, 1) as customer_percentile,
  
  -- Value vs risk tradeoff
  ROUND(value_per_alert, 2) as eur_value_per_alert,
  
  -- Pareto classification
  CASE 
    WHEN cumulative_fraud_alerts / total_fraud_alerts <= 0.8 THEN '🎯 TOP 20% (High Priority)'
    ELSE 'Lower Priority'
  END as intervention_priority

FROM ranked_customers

ORDER BY customer_rank

LIMIT 100;


-- =====================================================
-- Query 5: ML Model Feature Engineering
-- =====================================================
-- Prepares features for BigQuery ML fraud detection model
-- Runs daily to retrain model with fresh data
-- =====================================================

CREATE OR REPLACE VIEW `curated.fraud_model_features` AS

WITH customer_history AS (
  SELECT 
    customer_sk,
    COUNT(*) as historical_tx_count,
    AVG(fraud_score) as historical_avg_fraud_score,
    MAX(fraud_score) as historical_max_fraud_score,
    SUM(CASE WHEN fraud_score > 0.8 THEN 1 ELSE 0 END) as historical_fraud_count
  FROM `curated.transaction_fact`
  WHERE ingestion_timestamp < TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
  GROUP BY customer_sk
)

SELECT 
  -- Label (target variable)
  CASE WHEN t.fraud_score > 0.8 THEN 1 ELSE 0 END as fraud_label,
  
  -- Transaction features
  t.amount_eur,
  t.amount_brl,
  t.fx_rate,
  EXTRACT(HOUR FROM t.ingestion_timestamp) as hour_of_day,
  EXTRACT(DAYOFWEEK FROM t.ingestion_timestamp) as day_of_week,
  
  -- Geographic features
  t.origin_country,
  t.destination_country,
  CASE WHEN t.origin_country = t.destination_country THEN 1 ELSE 0 END as domestic_flag,
  
  -- Customer features
  c.current_residency_cd,
  DATE_DIFF(CURRENT_DATE(), DATE(c.valid_from), DAY) as days_since_residency_change,
  
  -- Historical behavior features
  COALESCE(h.historical_tx_count, 0) as customer_historical_tx_count,
  COALESCE(h.historical_avg_fraud_score, 0) as customer_avg_fraud_score,
  COALESCE(h.historical_fraud_count, 0) as customer_prior_fraud_count,
  
  -- Compliance features
  t.kyc_verified,
  t.pci_compliant

FROM `curated.transaction_fact` t
JOIN `curated.customer_dim` c
  ON t.customer_sk = c.customer_sk
LEFT JOIN customer_history h
  ON t.customer_sk = h.customer_sk

WHERE DATE(t.ingestion_timestamp) >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
  AND c.valid_to IS NULL;  -- Current customer records only


-- =====================================================
-- SLA Monitoring Query
-- =====================================================
-- Tracks P99 latency compliance (<1 second target)
-- Runs every 5 minutes via Cloud Monitoring
-- =====================================================

SELECT 
  DATE(ingestion_timestamp) as query_date,
  APPROX_QUANTILES(processing_latency_ms, 100)[OFFSET(99)] as p99_latency_ms,
  APPROX_QUANTILES(processing_latency_ms, 100)[OFFSET(95)] as p95_latency_ms,
  APPROX_QUANTILES(processing_latency_ms, 100)[OFFSET(50)] as p50_latency_ms,
  
  -- SLA compliance
  CASE 
    WHEN APPROX_QUANTILES(processing_latency_ms, 100)[OFFSET(99)] < 1000 THEN '✅ SLA_MET'
    ELSE '❌ SLA_BREACH'
  END as sla_status,
  
  COUNT(*) as total_transactions

FROM `curated.transaction_fact`

WHERE DATE(ingestion_timestamp) >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)

GROUP BY query_date

ORDER BY query_date DESC;
