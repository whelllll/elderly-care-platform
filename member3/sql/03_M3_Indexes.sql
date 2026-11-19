-- 成员3护工与排班管理；以数据字典v4为准，SQL Server 2016+。
-- 在SSMS明确选择目标用户数据库后执行；本脚本不创建/删除数据库、不迁移旧数据。
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
IF DB_ID() <= 4 THROW 51000, N'请先选择专用用户数据库，不可在系统数据库执行。', 1;
IF @@TRANCOUNT <> 0 THROW 51000, N'请在无外层事务的会话中执行部署脚本。', 1;

BEGIN TRY
 BEGIN TRANSACTION;
 CREATE NONCLUSTERED INDEX [IX_M3_certificate_eligibility] ON dbo.[caregiver_certificate] (caregiver_id, service_id, certificate_status, valid_to) INCLUDE (valid_from, certificate_type, qualification_level);
 CREATE NONCLUSTERED INDEX [IX_M3_schedule_caregiver_start] ON dbo.[caregiver_schedule] (caregiver_id, start_time) INCLUDE (end_time, schedule_status, max_orders);
 CREATE NONCLUSTERED INDEX [IX_M3_work_schedule_time] ON dbo.[work_record] (schedule_id, check_in_time) INCLUDE (review_status, effective_minutes);
 CREATE NONCLUSTERED INDEX [IX_M3_work_approved_month] ON dbo.[work_record] (check_in_time, schedule_id) INCLUDE (effective_minutes) WHERE review_status = N'通过';
 COMMIT TRANSACTION;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;
-- 不为主键、证书两列唯一键或dispatch_id唯一键重复建索引。性能待实测。
