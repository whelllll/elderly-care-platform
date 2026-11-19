/* ============================================================
   5 条复杂查询（每条连接 3 个及以上关系）
   ============================================================ */

/* Q1：某老人（示例 elder_id=16）近 7 天异常体征及设备信息 */
SELECT
    e.elder_name,
    v.collect_time,
    v.indicator_type,
    v.indicator_value,
    d.device_type,
    d.device_sn
FROM dbo.vital_sign AS v
INNER JOIN dbo.elder_profile AS e ON e.elder_id = v.elder_id
INNER JOIN dbo.monitor_device AS d ON d.device_id = v.device_id
WHERE v.elder_id = 16
  AND v.is_abnormal = 1
  AND v.collect_time >= DATEADD(DAY, -7, SYSDATETIME())
ORDER BY v.collect_time DESC;
GO

/* Q2：各设备类型本月体征异常率 */
SELECT
    d.device_type,
    COUNT_BIG(*) AS vital_count,
    COUNT(DISTINCT e.elder_id) AS elder_count,
    SUM(CASE WHEN v.is_abnormal = 1 THEN 1 ELSE 0 END) AS abnormal_count,
    CAST(100.0 * SUM(CASE WHEN v.is_abnormal = 1 THEN 1 ELSE 0 END)
         / COUNT_BIG(*) AS DECIMAL(5,2)) AS abnormal_rate
FROM dbo.vital_sign AS v
INNER JOIN dbo.monitor_device AS d ON d.device_id = v.device_id
INNER JOIN dbo.elder_profile AS e ON e.elder_id = v.elder_id
WHERE v.collect_time >= DATEFROMPARTS(YEAR(SYSDATETIME()), MONTH(SYSDATETIME()), 1)
GROUP BY d.device_type
ORDER BY abnormal_rate DESC;
GO

/* Q3：超时未响应事件及老人、响应人 */
SELECT
    ev.event_id,
    e.elder_name,
    e.community_name,
    ev.event_level,
    ev.happen_time,
    ev.response_deadline,
    DATEDIFF(MINUTE, ev.response_deadline, SYSDATETIME()) AS overdue_minutes,
    u.real_name AS responder_name
FROM dbo.emergency_event AS ev
INNER JOIN dbo.elder_profile AS e ON e.elder_id = ev.elder_id
LEFT JOIN dbo.sys_user AS u ON u.user_id = ev.responder_id
WHERE ev.event_status = N'待响应'
  AND ev.response_deadline < SYSDATETIME()
ORDER BY ev.response_deadline ASC;
GO

/* Q4：每位老人最近一次血压/心率/血氧 */
WITH latest AS
(
    SELECT
        v.elder_id,
        v.indicator_type,
        v.indicator_value,
        v.collect_time,
        ROW_NUMBER() OVER (
            PARTITION BY v.elder_id, v.indicator_type
            ORDER BY v.collect_time DESC, v.vital_id DESC
        ) AS rn
    FROM dbo.vital_sign AS v
    INNER JOIN dbo.monitor_device AS d ON d.device_id = v.device_id
)
SELECT
    e.elder_name,
    MAX(CASE WHEN l.indicator_type = N'收缩压' THEN l.indicator_value END) AS systolic,
    MAX(CASE WHEN l.indicator_type = N'舒张压' THEN l.indicator_value END) AS diastolic,
    MAX(CASE WHEN l.indicator_type = N'心率'   THEN l.indicator_value END) AS heart_rate,
    MAX(CASE WHEN l.indicator_type = N'血氧'   THEN l.indicator_value END) AS oxygen,
    MAX(l.collect_time) AS latest_time
FROM latest AS l
INNER JOIN dbo.elder_profile AS e ON e.elder_id = l.elder_id
WHERE l.rn = 1
GROUP BY e.elder_id, e.elder_name
ORDER BY e.elder_id;
GO

/* Q5：各社区近 30 天事件等级分布与平均到场时长 */
SELECT
    e.community_name,
    ev.event_level,
    COUNT_BIG(*) AS event_count,
    SUM(CASE WHEN ev.event_status = N'已闭环' THEN 1 ELSE 0 END) AS closed_count,
    COUNT(u.user_id) AS responder_count,
    AVG(CASE WHEN ev.arrive_time IS NOT NULL
             THEN DATEDIFF(MINUTE, ev.happen_time, ev.arrive_time) END) AS avg_arrive_minutes
FROM dbo.emergency_event AS ev
INNER JOIN dbo.elder_profile AS e ON e.elder_id = ev.elder_id
LEFT JOIN dbo.sys_user AS u ON u.user_id = ev.responder_id
WHERE ev.happen_time >= DATEADD(DAY, -30, SYSDATETIME())
GROUP BY e.community_name, ev.event_level
ORDER BY e.community_name, ev.event_level;
GO
