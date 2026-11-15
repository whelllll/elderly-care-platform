SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER VIEW dbo.vw_M2_OrderDetails
AS
SELECT o.order_id, o.elder_id, o.service_id, s.service_name, s.service_type,
       o.order_time, o.appointment_time, o.duration_minutes,
       DATEADD(MINUTE, o.duration_minutes, o.appointment_time) AS service_end,
       o.order_status, o.total_amount, o.service_address,
       o.service_latitude, o.service_longitude, o.allowed_radius_m
FROM dbo.service_order AS o JOIN dbo.service_item AS s ON s.service_id = o.service_id;
GO
CREATE OR ALTER VIEW dbo.vw_M2_ActiveDispatch
AS
SELECT d.dispatch_id, d.order_id, d.caregiver_id, d.dispatch_time, d.accept_time,
       d.dispatch_status, o.service_id, s.service_name, o.order_status, o.service_address,
       o.appointment_time, DATEADD(MINUTE, o.duration_minutes, o.appointment_time) AS service_end
FROM dbo.dispatch_record AS d JOIN dbo.service_order AS o ON o.order_id = d.order_id
JOIN dbo.service_item AS s ON s.service_id = o.service_id
WHERE d.dispatch_status IN (N'待接单', N'已接单');
GO
CREATE OR ALTER VIEW dbo.vw_M2_ServiceSummary
AS
SELECT s.service_id, s.service_name, s.status, COUNT_BIG(o.order_id) AS order_count,
       SUM(CONVERT(BIGINT, IIF(o.order_status = N'已完成', 1, 0))) AS completed_count,
       SUM(CONVERT(BIGINT, IIF(o.order_status = N'已取消', 1, 0))) AS cancelled_count,
       SUM(CASE WHEN o.order_status = N'已完成' THEN o.total_amount ELSE 0 END) AS completed_amount
FROM dbo.service_item AS s LEFT JOIN dbo.service_order AS o ON o.service_id = s.service_id
GROUP BY s.service_id, s.service_name, s.status;
