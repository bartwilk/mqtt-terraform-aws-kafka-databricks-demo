-- =========================================================
-- View 1: Hourly anomaly rate (last 7 days)
-- Use as a LINE chart (x = hour_ts, y = anomaly_rate)
-- =========================================================

CREATE OR REPLACE VIEW iot.gold.vw_iot_anomaly_rate_hourly AS
WITH base AS (
  SELECT
    window_end,
    is_anomaly
  FROM iot.gold.device_anomalies
  WHERE window_end >= current_timestamp() - INTERVAL 7 DAYS
)
SELECT
  date_trunc('hour', window_end)                        AS hour_ts,
  COUNT(*)                                              AS total_windows,
  SUM(CASE WHEN is_anomaly = 1 THEN 1 ELSE 0 END)       AS anomaly_count,
  SUM(CASE WHEN is_anomaly = 1 THEN 1.0 ELSE 0.0 END)
    / COUNT(*)                                          AS anomaly_rate
FROM base
GROUP BY date_trunc('hour', window_end)
ORDER BY hour_ts;


-- =========================================================
-- View 2: Top risky devices (last 24 hours)
-- Use as TABLE & BAR chart (x = device_id, y = avg_anomaly_score)
-- =========================================================

CREATE OR REPLACE VIEW iot.gold.vw_iot_top_risky_devices_24h AS
WITH last24 AS (
  SELECT *
  FROM iot.gold.device_anomalies
  WHERE window_end >= current_timestamp() - INTERVAL 1 DAY
)
SELECT
  device_id,
  COUNT(*) AS window_count,
  SUM(CASE WHEN is_anomaly = 1 THEN 1 ELSE 0 END) AS anomaly_windows,
  AVG(anomaly_score)                               AS avg_anomaly_score,
  MAX(anomaly_score)                               AS max_anomaly_score,
  AVG(temp_avg_5m)                                 AS avg_temp,
  AVG(vib_avg_5m)                                  AS avg_vibration,
  MAX(risk_max_5m)                                 AS max_risk_score
FROM last24
GROUP BY device_id
HAVING anomaly_windows > 0
ORDER BY avg_anomaly_score DESC
LIMIT 50;


-- =========================================================
-- View 3: Recent anomalies detail (last 24 hours)
-- Use as TABLE widget for drill-down in the dashboard
-- =========================================================

CREATE OR REPLACE VIEW iot.gold.vw_iot_recent_anomalies_24h AS
SELECT
  device_id,
  window_start,
  window_end,
  temp_avg_5m,
  temp_std_5m,
  vib_avg_5m,
  pressure_avg_5m,
  risk_max_5m,
  anomaly_score,
  is_anomaly,
  scored_at
FROM iot.gold.device_anomalies
WHERE is_anomaly = 1
  AND window_end >= current_timestamp() - INTERVAL 1 DAY
ORDER BY window_end DESC
LIMIT 500;


-- =========================================================
-- View 4: Temperature vs anomaly score (for scatter / heatmap)
-- Good for root-cause style visualization
-- =========================================================

CREATE OR REPLACE VIEW iot.gold.vw_iot_temp_vs_anomaly AS
SELECT
  device_id,
  window_end                               AS ts,
  temp_avg_5m,
  vib_avg_5m,
  pressure_avg_5m,
  risk_max_5m,
  anomaly_score,
  is_anomaly
FROM iot.gold.device_anomalies
WHERE window_end >= current_timestamp() - INTERVAL 7 DAYS;
