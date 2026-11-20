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
 IF OBJECT_ID(N'dbo.caregiver') IS NOT NULL THROW 51001,N'对象 dbo.caregiver 已存在；未覆盖，请核对版本或选择空库。',1;
 IF OBJECT_ID(N'dbo.caregiver_certificate') IS NOT NULL THROW 51001,N'对象 dbo.caregiver_certificate 已存在；未覆盖，请核对版本或选择空库。',1;
 IF OBJECT_ID(N'dbo.caregiver_schedule') IS NOT NULL THROW 51001,N'对象 dbo.caregiver_schedule 已存在；未覆盖，请核对版本或选择空库。',1;
 IF OBJECT_ID(N'dbo.work_record') IS NOT NULL THROW 51001,N'对象 dbo.work_record 已存在；未覆盖，请核对版本或选择空库。',1;

 -- caregiver：6字段；跨模块外键留至02脚本。
 CREATE TABLE dbo.[caregiver] (
 [caregiver_id] INT IDENTITY(1,1) NOT NULL,
 [caregiver_name] NVARCHAR(50) NOT NULL,
 [org_id] INT NOT NULL,
 [phone] VARCHAR(20) NOT NULL,
 [service_area] NVARCHAR(200) NOT NULL,
 [employment_status] NVARCHAR(10) NOT NULL CONSTRAINT [DF_M3_caregiver_employment_status] DEFAULT N'在岗',
 CONSTRAINT [PK_M3_caregiver] PRIMARY KEY CLUSTERED ([caregiver_id]),
 CONSTRAINT [CK_M3_caregiver_employment_status_enum] CHECK (employment_status IN (N'在岗', N'停用', N'离职'))
 );

 -- caregiver_certificate：9字段；跨模块外键留至02脚本。
 CREATE TABLE dbo.[caregiver_certificate] (
 [certificate_id] INT IDENTITY(1,1) NOT NULL,
 [caregiver_id] INT NOT NULL,
 [certificate_no] NVARCHAR(50) NOT NULL,
 [certificate_type] NVARCHAR(50) NOT NULL,
 [service_id] INT NOT NULL,
 [qualification_level] NVARCHAR(30) NOT NULL,
 [valid_from] DATE NOT NULL,
 [valid_to] DATE NOT NULL,
 [certificate_status] NVARCHAR(10) NOT NULL CONSTRAINT [DF_M3_caregiver_certificate_certificate_status] DEFAULT N'有效',
 CONSTRAINT [PK_M3_caregiver_certificate] PRIMARY KEY CLUSTERED ([certificate_id]),
 CONSTRAINT [UQ_M3_certificate_caregiver_no] UNIQUE (caregiver_id,certificate_no),
 CONSTRAINT [CK_M3_caregiver_certificate_certificate_status_enum] CHECK (certificate_status IN (N'有效', N'暂停', N'吊销')),
 CONSTRAINT [CK_M3_caregiver_certificate_valid_dates] CHECK (valid_to >= valid_from),
 CONSTRAINT [FK_M3_caregiver_certificate_caregiver_id] FOREIGN KEY ([caregiver_id]) REFERENCES dbo.[caregiver]([caregiver_id]) ON DELETE NO ACTION ON UPDATE NO ACTION
 );

 -- caregiver_schedule：6字段；跨模块外键留至02脚本。
 CREATE TABLE dbo.[caregiver_schedule] (
 [schedule_id] INT IDENTITY(1,1) NOT NULL,
 [caregiver_id] INT NOT NULL,
 [start_time] DATETIME2(0) NOT NULL,
 [end_time] DATETIME2(0) NOT NULL,
 [max_orders] INT NOT NULL,
 [schedule_status] NVARCHAR(10) NOT NULL CONSTRAINT [DF_M3_caregiver_schedule_schedule_status] DEFAULT N'开放',
 CONSTRAINT [PK_M3_caregiver_schedule] PRIMARY KEY CLUSTERED ([schedule_id]),
 CONSTRAINT [CK_M3_caregiver_schedule_schedule_status_enum] CHECK (schedule_status IN (N'开放', N'关闭', N'取消')),
 CONSTRAINT [CK_M3_caregiver_schedule_time_range] CHECK (end_time > start_time),
 CONSTRAINT [CK_M3_caregiver_schedule_positive_capacity] CHECK (max_orders > 0),
 CONSTRAINT [FK_M3_caregiver_schedule_caregiver_id] FOREIGN KEY ([caregiver_id]) REFERENCES dbo.[caregiver]([caregiver_id]) ON DELETE NO ACTION ON UPDATE NO ACTION
 );

 -- work_record：11字段；跨模块外键留至02脚本。
 CREATE TABLE dbo.[work_record] (
 [work_id] INT IDENTITY(1,1) NOT NULL,
 [schedule_id] INT NOT NULL,
 [dispatch_id] INT NOT NULL,
 [check_in_time] DATETIME2(0) NOT NULL,
 [check_out_time] DATETIME2(0) NULL,
 [check_in_location] NVARCHAR(200) NULL,
 [check_out_location] NVARCHAR(200) NULL,
 [fence_result] NVARCHAR(10) NOT NULL CONSTRAINT [DF_M3_work_record_fence_result] DEFAULT N'待校验',
 [effective_minutes] INT NULL,
 [review_status] NVARCHAR(10) NOT NULL CONSTRAINT [DF_M3_work_record_review_status] DEFAULT N'待审核',
 [review_note] NVARCHAR(255) NULL,
 CONSTRAINT [PK_M3_work_record] PRIMARY KEY CLUSTERED ([work_id]),
 CONSTRAINT [UQ_M3_work_dispatch] UNIQUE (dispatch_id),
 CONSTRAINT [CK_M3_work_record_fence_result_enum] CHECK (fence_result IN (N'待校验', N'通过', N'未通过')),
 CONSTRAINT [CK_M3_work_record_review_status_enum] CHECK (review_status IN (N'待审核', N'通过', N'驳回')),
 CONSTRAINT [CK_M3_work_record_checkout] CHECK (check_out_time IS NULL OR check_out_time > check_in_time),
 CONSTRAINT [CK_M3_work_record_checkout_location] CHECK (check_out_time IS NOT NULL OR check_out_location IS NULL),
 CONSTRAINT [CK_M3_work_record_minutes] CHECK (effective_minutes IS NULL OR (check_out_time IS NOT NULL AND effective_minutes >= 0 AND CONVERT(BIGINT,effective_minutes)*60 <= DATEDIFF_BIG(SECOND,check_in_time,check_out_time))),
 CONSTRAINT [CK_M3_work_record_review_ready] CHECK ((review_status = N'通过' AND check_out_time IS NOT NULL AND effective_minutes IS NOT NULL) OR (review_status IN (N'待审核',N'驳回') AND effective_minutes IS NULL)),
 CONSTRAINT [CK_M3_work_record_abnormal_note] CHECK (review_status <> N'通过' OR (fence_result = N'通过' AND check_in_location IS NOT NULL AND check_out_location IS NOT NULL) OR (review_note IS NOT NULL AND LEN(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(REPLACE(review_note,NCHAR(9),N''),NCHAR(10),N''),NCHAR(13),N''),NCHAR(12288),N'')))) > 0)),
 CONSTRAINT [FK_M3_work_record_schedule_id] FOREIGN KEY ([schedule_id]) REFERENCES dbo.[caregiver_schedule]([schedule_id]) ON DELETE NO ACTION ON UPDATE NO ACTION
 );
 COMMIT TRANSACTION;
 PRINT N'四表及内部声明式约束部署完成；跨模块外键尚须执行02。';
END TRY
BEGIN CATCH
 IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;
