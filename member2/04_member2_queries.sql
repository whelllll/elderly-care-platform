-- 指定统计区间时使用左闭右开 [@From, @Until)。两个参数可留空。
DECLARE @From DATETIME2(0) = NULL, @Until DATETIME2(0) = NULL;
IF @From IS NOT NULL AND @Until IS NOT NULL AND @From >= @Until
    THROW 51300, N'查询开始时间必须早于结束时间。', 1;

-- 三表查询一：订单及最新派单。保留尚无派单记录的订单，显示派单历史计数。
WITH DispatchHistory AS (
    SELECT d.order_id, d.dispatch_id, d.caregiver_id, d.dispatch_status, d.dispatch_time,
           COUNT_BIG(*) OVER (PARTITION BY d.order_id) AS dispatch_count,
           ROW_NUMBER() OVER (PARTITION BY d.order_id ORDER BY d.dispatch_time DESC, d.dispatch_id DESC) AS rn
    FROM dbo.dispatch_record AS d
)
SELECT o.order_id, o.elder_id, s.service_name, s.service_type, o.order_status, o.total_amount,
       o.appointment_time, DATEADD(MINUTE, o.duration_minutes, o.appointment_time) AS service_end,
       o.service_address, d.dispatch_id, d.caregiver_id, d.dispatch_status,
       COALESCE(d.dispatch_count, 0) AS dispatch_count
FROM dbo.service_order AS o
JOIN dbo.service_item AS s ON s.service_id = o.service_id
LEFT JOIN DispatchHistory AS d ON d.order_id = o.order_id AND d.rn = 1
WHERE (@From IS NULL OR @From <= o.appointment_time) AND (@Until IS NULL OR o.appointment_time < @Until)
ORDER BY o.appointment_time, o.order_id;

-- 三表查询二：按项目汇总。先按订单归并派单，避免订单金额随改派记录重复累加。
WITH DispatchTotals AS (
    SELECT order_id, COUNT_BIG(*) AS dispatch_count,
           SUM(CONVERT(BIGINT, IIF(dispatch_status IN (N'已拒绝', N'已撤回'), 1, 0))) AS released_count
    FROM dbo.dispatch_record GROUP BY order_id
)
SELECT s.service_id, s.service_name, COUNT_BIG(o.order_id) AS order_count,
       SUM(CONVERT(BIGINT, IIF(o.order_status = N'已完成', 1, 0))) AS completed_count,
       SUM(CONVERT(BIGINT, IIF(o.order_status = N'已取消', 1, 0))) AS cancelled_count,
       SUM(COALESCE(d.dispatch_count, 0)) AS dispatch_count,
       SUM(COALESCE(d.released_count, 0)) AS released_dispatch_count,
       SUM(CASE WHEN o.order_status = N'已完成' THEN o.total_amount ELSE 0 END) AS completed_amount
FROM dbo.service_item AS s
LEFT JOIN dbo.service_order AS o ON o.service_id = s.service_id
    AND (@From IS NULL OR @From <= o.appointment_time) AND (@Until IS NULL OR o.appointment_time < @Until)
LEFT JOIN DispatchTotals AS d ON d.order_id = o.order_id
GROUP BY s.service_id, s.service_name
ORDER BY order_count DESC, s.service_id;
