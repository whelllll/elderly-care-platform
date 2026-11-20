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

-- 依赖：成员1service_org、成员2service_item和dispatch_record已建立；键须INT、非空且可引用。
-- 缺依赖时整体报错回滚，绝不建替代表、不跳过应有外键、不WITH NOCHECK。
-- 只添加成员3三条出向外键。下方注释的反向外键由成员2在其部署脚本执行。
BEGIN TRY
 BEGIN TRANSACTION;
 IF OBJECT_ID(N'dbo.caregiver',N'U') IS NULL OR OBJECT_ID(N'dbo.service_org',N'U') IS NULL THROW 51002,N'缺少 dbo.caregiver 或 dbo.service_org；请先完成对应成员建表。',1;
 IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID(N'dbo.service_org') AND name=N'org_id' AND system_type_id=56 AND is_nullable=0) THROW 51002,N'dbo.service_org.org_id 必须是非空INT可引用键。',1;
 IF OBJECT_ID(N'dbo.caregiver_certificate',N'U') IS NULL OR OBJECT_ID(N'dbo.service_item',N'U') IS NULL THROW 51002,N'缺少 dbo.caregiver_certificate 或 dbo.service_item；请先完成对应成员建表。',1;
 IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID(N'dbo.service_item') AND name=N'service_id' AND system_type_id=56 AND is_nullable=0) THROW 51002,N'dbo.service_item.service_id 必须是非空INT可引用键。',1;
 IF OBJECT_ID(N'dbo.work_record',N'U') IS NULL OR OBJECT_ID(N'dbo.dispatch_record',N'U') IS NULL THROW 51002,N'缺少 dbo.work_record 或 dbo.dispatch_record；请先完成对应成员建表。',1;
 IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID(N'dbo.dispatch_record') AND name=N'dispatch_id' AND system_type_id=56 AND is_nullable=0) THROW 51002,N'dbo.dispatch_record.dispatch_id 必须是非空INT可引用键。',1;
 ALTER TABLE dbo.[caregiver] WITH CHECK ADD CONSTRAINT [FK_M3_caregiver_org_id] FOREIGN KEY ([org_id]) REFERENCES dbo.[service_org]([org_id]) ON DELETE NO ACTION ON UPDATE NO ACTION;
 ALTER TABLE dbo.[caregiver_certificate] WITH CHECK ADD CONSTRAINT [FK_M3_caregiver_certificate_service_id] FOREIGN KEY ([service_id]) REFERENCES dbo.[service_item]([service_id]) ON DELETE NO ACTION ON UPDATE NO ACTION;
 ALTER TABLE dbo.[work_record] WITH CHECK ADD CONSTRAINT [FK_M3_work_record_dispatch_id] FOREIGN KEY ([dispatch_id]) REFERENCES dbo.[dispatch_record]([dispatch_id]) ON DELETE NO ACTION ON UPDATE NO ACTION;
 COMMIT TRANSACTION;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;

/* 以下仅供成员2整合，不随本文件执行。先确认其脚本尚未添加等价外键，避免重复。
ALTER TABLE dbo.dispatch_record WITH CHECK ADD CONSTRAINT FK_dispatch_record_caregiver_id FOREIGN KEY (caregiver_id) REFERENCES dbo.caregiver(caregiver_id) ON DELETE NO ACTION ON UPDATE NO ACTION;
ALTER TABLE dbo.dispatch_record WITH CHECK ADD CONSTRAINT FK_dispatch_record_schedule_id FOREIGN KEY (schedule_id) REFERENCES dbo.caregiver_schedule(schedule_id) ON DELETE NO ACTION ON UPDATE NO ACTION;
成员2负责schedule_id INT NOT NULL及历史数据回填；order_id不设普通UNIQUE，按其最终版筛选唯一索引限制有效派单。
*/
