-- 成员3：护工资质、排班、月度有效工时三个普通视图。
-- 基线：数据字典v4，四表32字段。仅依赖成员3表，不创建其他成员替代表。
-- 在SSMS选择用户数据库，先部署01；03有助于后续访问路径，但索引收益尚未实测。
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
IF DB_ID()<=4 THROW 51311,N'请先选择成员3专用用户数据库。',1;
IF @@TRANCOUNT<>0 THROW 51311,N'请在无外层事务的会话中部署视图。',1;
BEGIN TRY
 BEGIN TRAN;
 IF OBJECT_ID(N'dbo.caregiver',N'U') IS NULL
  OR OBJECT_ID(N'dbo.caregiver_certificate',N'U') IS NULL
  OR OBJECT_ID(N'dbo.caregiver_schedule',N'U') IS NULL
  OR OBJECT_ID(N'dbo.work_record',N'U') IS NULL
  THROW 51311,N'缺少成员3基础表，请先部署01。',1;
 IF OBJECT_ID(N'dbo.v_M3_CaregiverQualifications') IS NOT NULL
  OR OBJECT_ID(N'dbo.v_M3_CaregiverSchedules') IS NOT NULL
  OR OBJECT_ID(N'dbo.v_M3_MonthlyEffectiveWork') IS NOT NULL
  THROW 51311,N'目标视图或同名对象已存在，停止且不覆盖。',1;

 -- 资格台账保留全部状态/有效期；查询方按预约日期与项目编号筛选，不把“当前有效”硬编码。
 EXEC sys.sp_executesql N'CREATE VIEW dbo.v_M3_CaregiverQualifications
 AS
 SELECT c.caregiver_id,c.caregiver_name,c.org_id,c.service_area,c.employment_status,
        q.certificate_id,q.certificate_no,q.certificate_type,q.service_id,
        q.qualification_level,q.valid_from,q.valid_to,q.certificate_status
 FROM dbo.caregiver AS c
 INNER JOIN dbo.caregiver_certificate AS q ON q.caregiver_id=c.caregiver_id;';

 -- 保留开放/关闭/取消班次供查询与追溯；max_orders为上限，不冒充剩余容量。
 EXEC sys.sp_executesql N'CREATE VIEW dbo.v_M3_CaregiverSchedules
 AS
 SELECT c.caregiver_id,c.caregiver_name,c.org_id,c.service_area,c.employment_status,
        s.schedule_id,s.start_time,s.end_time,s.max_orders,s.schedule_status
 FROM dbo.caregiver AS c
 INNER JOIN dbo.caregiver_schedule AS s ON s.caregiver_id=c.caregiver_id;';

 -- 以签到月份整条归属，跨月不拆分；异常围栏人工认可后也可计入，不额外筛掉fence_result。
 -- 不根据当前在岗/证书/班次状态过滤历史认可工时。零分钟通过记录仍是一条有效审核记录。
 EXEC sys.sp_executesql N'CREATE VIEW dbo.v_M3_MonthlyEffectiveWork
 AS
 SELECT c.caregiver_id,c.caregiver_name,c.org_id,c.service_area,
        DATEFROMPARTS(YEAR(w.check_in_time),MONTH(w.check_in_time),1) AS work_month,
        COUNT_BIG(*) AS approved_record_count,
        SUM(CONVERT(BIGINT,w.effective_minutes)) AS effective_minutes_total,
        CONVERT(DECIMAL(20,2),SUM(CONVERT(BIGINT,w.effective_minutes))/60.0) AS effective_hours_total
 FROM dbo.caregiver AS c
 INNER JOIN dbo.caregiver_schedule AS s ON s.caregiver_id=c.caregiver_id
 INNER JOIN dbo.work_record AS w ON w.schedule_id=s.schedule_id
 WHERE w.review_status=N''通过'' AND w.effective_minutes IS NOT NULL
 GROUP BY c.caregiver_id,c.caregiver_name,c.org_id,c.service_area,
          DATEFROMPARTS(YEAR(w.check_in_time),MONTH(w.check_in_time),1);';
 COMMIT;
 PRINT N'三个成员3视图已创建；创建成功不代表实际业务统计或性能已验证。';
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK;
 THROW;
END CATCH;
