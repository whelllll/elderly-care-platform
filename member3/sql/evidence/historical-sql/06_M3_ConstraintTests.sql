-- 成员3 v4：只在专用测试库执行；禁止在正式库运行。
SET NOCOUNT ON; SET XACT_ABORT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
IF DB_ID()<=4 THROW 51100,N'请选择专用用户测试库。',1;
IF @@TRANCOUNT<>0 THROW 51100,N'请勿在外层事务内运行。',1;

-- 隔离模式：临时表复制01的列/PK/UQ/DEFAULT/CHECK，所有夹具是临时合成值，绝不写入dbo业务表。
-- 未复制/测试跨成员外键；#临时表不支持可信FK，不借此声称联调成功。
-- 每例独立事务，成功或失败均回滚；事务可能消耗临时表IDENTITY号，业务表不受影响。
CREATE TABLE #caregiver (
 [caregiver_id] INT IDENTITY(1,1) NOT NULL,
 [caregiver_name] NVARCHAR(50) NOT NULL,
 [org_id] INT NOT NULL,
 [phone] VARCHAR(20) NOT NULL,
 [service_area] NVARCHAR(200) NOT NULL,
 [employment_status] NVARCHAR(10) NOT NULL CONSTRAINT [DF_M3_caregiver_employment_status_ISO] DEFAULT N'在岗',
 CONSTRAINT [PK_M3_caregiver_ISO] PRIMARY KEY CLUSTERED ([caregiver_id]),
 CONSTRAINT [CK_M3_caregiver_employment_status_enum_ISO] CHECK (employment_status IN (N'在岗', N'停用', N'离职'))
);
CREATE TABLE #caregiver_certificate (
 [certificate_id] INT IDENTITY(1,1) NOT NULL,
 [caregiver_id] INT NOT NULL,
 [certificate_no] NVARCHAR(50) NOT NULL,
 [certificate_type] NVARCHAR(50) NOT NULL,
 [service_id] INT NOT NULL,
 [qualification_level] NVARCHAR(30) NOT NULL,
 [valid_from] DATE NOT NULL,
 [valid_to] DATE NOT NULL,
 [certificate_status] NVARCHAR(10) NOT NULL CONSTRAINT [DF_M3_caregiver_certificate_certificate_status_ISO] DEFAULT N'有效',
 CONSTRAINT [PK_M3_caregiver_certificate_ISO] PRIMARY KEY CLUSTERED ([certificate_id]),
 CONSTRAINT [UQ_M3_certificate_caregiver_no_ISO] UNIQUE (caregiver_id,certificate_no),
 CONSTRAINT [CK_M3_caregiver_certificate_certificate_status_enum_ISO] CHECK (certificate_status IN (N'有效', N'暂停', N'吊销')),
 CONSTRAINT [CK_M3_caregiver_certificate_valid_dates_ISO] CHECK (valid_to >= valid_from)
);
CREATE TABLE #caregiver_schedule (
 [schedule_id] INT IDENTITY(1,1) NOT NULL,
 [caregiver_id] INT NOT NULL,
 [start_time] DATETIME2(0) NOT NULL,
 [end_time] DATETIME2(0) NOT NULL,
 [max_orders] INT NOT NULL,
 [schedule_status] NVARCHAR(10) NOT NULL CONSTRAINT [DF_M3_caregiver_schedule_schedule_status_ISO] DEFAULT N'开放',
 CONSTRAINT [PK_M3_caregiver_schedule_ISO] PRIMARY KEY CLUSTERED ([schedule_id]),
 CONSTRAINT [CK_M3_caregiver_schedule_schedule_status_enum_ISO] CHECK (schedule_status IN (N'开放', N'关闭', N'取消')),
 CONSTRAINT [CK_M3_caregiver_schedule_time_range_ISO] CHECK (end_time > start_time),
 CONSTRAINT [CK_M3_caregiver_schedule_positive_capacity_ISO] CHECK (max_orders > 0)
);
CREATE TABLE #work_record (
 [work_id] INT IDENTITY(1,1) NOT NULL,
 [schedule_id] INT NOT NULL,
 [dispatch_id] INT NOT NULL,
 [check_in_time] DATETIME2(0) NOT NULL,
 [check_out_time] DATETIME2(0) NULL,
 [check_in_location] NVARCHAR(200) NULL,
 [check_out_location] NVARCHAR(200) NULL,
 [fence_result] NVARCHAR(10) NOT NULL CONSTRAINT [DF_M3_work_record_fence_result_ISO] DEFAULT N'待校验',
 [effective_minutes] INT NULL,
 [review_status] NVARCHAR(10) NOT NULL CONSTRAINT [DF_M3_work_record_review_status_ISO] DEFAULT N'待审核',
 [review_note] NVARCHAR(255) NULL,
 CONSTRAINT [PK_M3_work_record_ISO] PRIMARY KEY CLUSTERED ([work_id]),
 CONSTRAINT [UQ_M3_work_dispatch_ISO] UNIQUE (dispatch_id),
 CONSTRAINT [CK_M3_work_record_fence_result_enum_ISO] CHECK (fence_result IN (N'待校验', N'通过', N'未通过')),
 CONSTRAINT [CK_M3_work_record_review_status_enum_ISO] CHECK (review_status IN (N'待审核', N'通过', N'驳回')),
 CONSTRAINT [CK_M3_work_record_checkout_ISO] CHECK (check_out_time IS NULL OR check_out_time > check_in_time),
 CONSTRAINT [CK_M3_work_record_checkout_location_ISO] CHECK (check_out_time IS NOT NULL OR check_out_location IS NULL),
 CONSTRAINT [CK_M3_work_record_minutes_ISO] CHECK (effective_minutes IS NULL OR (check_out_time IS NOT NULL AND effective_minutes >= 0 AND CONVERT(BIGINT,effective_minutes)*60 <= DATEDIFF_BIG(SECOND,check_in_time,check_out_time))),
 CONSTRAINT [CK_M3_work_record_review_ready_ISO] CHECK ((review_status = N'通过' AND check_out_time IS NOT NULL AND effective_minutes IS NOT NULL) OR (review_status IN (N'待审核',N'驳回') AND effective_minutes IS NULL)),
 CONSTRAINT [CK_M3_work_record_abnormal_note_ISO] CHECK (review_status <> N'通过' OR (fence_result = N'通过' AND check_in_location IS NOT NULL AND check_out_location IS NOT NULL) OR (review_note IS NOT NULL AND LEN(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(REPLACE(review_note,NCHAR(9),N''),NCHAR(10),N''),NCHAR(13),N''),NCHAR(12288),N'')))) > 0))
);
CREATE TABLE #Results(id int,name nvarchar(200),expected nvarchar(200),actual nvarchar(2048),status varchar(8));
DECLARE @Error int,@Message nvarchar(2048);

-- T001: caregiver主键重复
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
SET IDENTITY_INSERT #caregiver ON; BEGIN TRY INSERT #caregiver (caregiver_id,caregiver_name,org_id,phone,service_area,employment_status) SELECT caregiver_id,caregiver_name,org_id,phone,service_area,employment_status FROM #caregiver; SET IDENTITY_INSERT #caregiver OFF; END TRY BEGIN CATCH SET IDENTITY_INSERT #caregiver OFF; THROW; END CATCH;';
 ROLLBACK;
 INSERT #Results VALUES(1,N'caregiver主键重复',N'错误2627包含PK_M3_caregiver',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(1,N'caregiver主键重复',N'错误2627包含PK_M3_caregiver',@Message,CASE WHEN @Error=2627 AND CHARINDEX(N'PK_M3_caregiver',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T002: caregiver.caregiver_name拒绝NULL
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
UPDATE #caregiver SET [caregiver_name]=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(2,N'caregiver.caregiver_name拒绝NULL',N'错误515包含caregiver_name',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(2,N'caregiver.caregiver_name拒绝NULL',N'错误515包含caregiver_name',@Message,CASE WHEN @Error=515 AND CHARINDEX(N'caregiver_name',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T003: caregiver.org_id拒绝NULL
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
UPDATE #caregiver SET [org_id]=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(3,N'caregiver.org_id拒绝NULL',N'错误515包含org_id',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(3,N'caregiver.org_id拒绝NULL',N'错误515包含org_id',@Message,CASE WHEN @Error=515 AND CHARINDEX(N'org_id',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T004: caregiver.phone拒绝NULL
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
UPDATE #caregiver SET [phone]=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(4,N'caregiver.phone拒绝NULL',N'错误515包含phone',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(4,N'caregiver.phone拒绝NULL',N'错误515包含phone',@Message,CASE WHEN @Error=515 AND CHARINDEX(N'phone',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T005: caregiver.service_area拒绝NULL
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
UPDATE #caregiver SET [service_area]=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(5,N'caregiver.service_area拒绝NULL',N'错误515包含service_area',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(5,N'caregiver.service_area拒绝NULL',N'错误515包含service_area',@Message,CASE WHEN @Error=515 AND CHARINDEX(N'service_area',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T006: caregiver.employment_status拒绝NULL
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
UPDATE #caregiver SET [employment_status]=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(6,N'caregiver.employment_status拒绝NULL',N'错误515包含employment_status',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(6,N'caregiver.employment_status拒绝NULL',N'错误515包含employment_status',@Message,CASE WHEN @Error=515 AND CHARINDEX(N'employment_status',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T007: caregiver_certificate主键重复
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_certificate(caregiver_id,certificate_no,certificate_type,service_id,qualification_level,valid_from,valid_to) VALUES(@c,N''ISO-C'',N''培训证书'',-1,N''初级'',''20300101'',''20301231'');
SET IDENTITY_INSERT #caregiver_certificate ON; BEGIN TRY INSERT #caregiver_certificate (certificate_id,caregiver_id,certificate_no,certificate_type,service_id,qualification_level,valid_from,valid_to,certificate_status) SELECT certificate_id,caregiver_id,certificate_no,certificate_type,service_id,qualification_level,valid_from,valid_to,certificate_status FROM #caregiver_certificate; SET IDENTITY_INSERT #caregiver_certificate OFF; END TRY BEGIN CATCH SET IDENTITY_INSERT #caregiver_certificate OFF; THROW; END CATCH;';
 ROLLBACK;
 INSERT #Results VALUES(7,N'caregiver_certificate主键重复',N'错误2627包含PK_M3_caregiver_certificate',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(7,N'caregiver_certificate主键重复',N'错误2627包含PK_M3_caregiver_certificate',@Message,CASE WHEN @Error=2627 AND CHARINDEX(N'PK_M3_caregiver_certificate',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T008: caregiver_certificate.caregiver_id拒绝NULL
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_certificate(caregiver_id,certificate_no,certificate_type,service_id,qualification_level,valid_from,valid_to) VALUES(@c,N''ISO-C'',N''培训证书'',-1,N''初级'',''20300101'',''20301231'');
UPDATE #caregiver_certificate SET [caregiver_id]=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(8,N'caregiver_certificate.caregiver_id拒绝NULL',N'错误515包含caregiver_id',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(8,N'caregiver_certificate.caregiver_id拒绝NULL',N'错误515包含caregiver_id',@Message,CASE WHEN @Error=515 AND CHARINDEX(N'caregiver_id',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T009: caregiver_certificate.certificate_no拒绝NULL
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_certificate(caregiver_id,certificate_no,certificate_type,service_id,qualification_level,valid_from,valid_to) VALUES(@c,N''ISO-C'',N''培训证书'',-1,N''初级'',''20300101'',''20301231'');
UPDATE #caregiver_certificate SET [certificate_no]=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(9,N'caregiver_certificate.certificate_no拒绝NULL',N'错误515包含certificate_no',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(9,N'caregiver_certificate.certificate_no拒绝NULL',N'错误515包含certificate_no',@Message,CASE WHEN @Error=515 AND CHARINDEX(N'certificate_no',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T010: caregiver_certificate.certificate_type拒绝NULL
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_certificate(caregiver_id,certificate_no,certificate_type,service_id,qualification_level,valid_from,valid_to) VALUES(@c,N''ISO-C'',N''培训证书'',-1,N''初级'',''20300101'',''20301231'');
UPDATE #caregiver_certificate SET [certificate_type]=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(10,N'caregiver_certificate.certificate_type拒绝NULL',N'错误515包含certificate_type',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(10,N'caregiver_certificate.certificate_type拒绝NULL',N'错误515包含certificate_type',@Message,CASE WHEN @Error=515 AND CHARINDEX(N'certificate_type',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T011: caregiver_certificate.service_id拒绝NULL
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_certificate(caregiver_id,certificate_no,certificate_type,service_id,qualification_level,valid_from,valid_to) VALUES(@c,N''ISO-C'',N''培训证书'',-1,N''初级'',''20300101'',''20301231'');
UPDATE #caregiver_certificate SET [service_id]=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(11,N'caregiver_certificate.service_id拒绝NULL',N'错误515包含service_id',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(11,N'caregiver_certificate.service_id拒绝NULL',N'错误515包含service_id',@Message,CASE WHEN @Error=515 AND CHARINDEX(N'service_id',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T012: caregiver_certificate.qualification_level拒绝NULL
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_certificate(caregiver_id,certificate_no,certificate_type,service_id,qualification_level,valid_from,valid_to) VALUES(@c,N''ISO-C'',N''培训证书'',-1,N''初级'',''20300101'',''20301231'');
UPDATE #caregiver_certificate SET [qualification_level]=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(12,N'caregiver_certificate.qualification_level拒绝NULL',N'错误515包含qualification_level',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(12,N'caregiver_certificate.qualification_level拒绝NULL',N'错误515包含qualification_level',@Message,CASE WHEN @Error=515 AND CHARINDEX(N'qualification_level',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T013: caregiver_certificate.valid_from拒绝NULL
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_certificate(caregiver_id,certificate_no,certificate_type,service_id,qualification_level,valid_from,valid_to) VALUES(@c,N''ISO-C'',N''培训证书'',-1,N''初级'',''20300101'',''20301231'');
UPDATE #caregiver_certificate SET [valid_from]=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(13,N'caregiver_certificate.valid_from拒绝NULL',N'错误515包含valid_from',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(13,N'caregiver_certificate.valid_from拒绝NULL',N'错误515包含valid_from',@Message,CASE WHEN @Error=515 AND CHARINDEX(N'valid_from',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T014: caregiver_certificate.valid_to拒绝NULL
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_certificate(caregiver_id,certificate_no,certificate_type,service_id,qualification_level,valid_from,valid_to) VALUES(@c,N''ISO-C'',N''培训证书'',-1,N''初级'',''20300101'',''20301231'');
UPDATE #caregiver_certificate SET [valid_to]=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(14,N'caregiver_certificate.valid_to拒绝NULL',N'错误515包含valid_to',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(14,N'caregiver_certificate.valid_to拒绝NULL',N'错误515包含valid_to',@Message,CASE WHEN @Error=515 AND CHARINDEX(N'valid_to',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T015: caregiver_certificate.certificate_status拒绝NULL
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_certificate(caregiver_id,certificate_no,certificate_type,service_id,qualification_level,valid_from,valid_to) VALUES(@c,N''ISO-C'',N''培训证书'',-1,N''初级'',''20300101'',''20301231'');
UPDATE #caregiver_certificate SET [certificate_status]=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(15,N'caregiver_certificate.certificate_status拒绝NULL',N'错误515包含certificate_status',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(15,N'caregiver_certificate.certificate_status拒绝NULL',N'错误515包含certificate_status',@Message,CASE WHEN @Error=515 AND CHARINDEX(N'certificate_status',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T016: caregiver_schedule主键重复
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
SET IDENTITY_INSERT #caregiver_schedule ON; BEGIN TRY INSERT #caregiver_schedule (schedule_id,caregiver_id,start_time,end_time,max_orders,schedule_status) SELECT schedule_id,caregiver_id,start_time,end_time,max_orders,schedule_status FROM #caregiver_schedule; SET IDENTITY_INSERT #caregiver_schedule OFF; END TRY BEGIN CATCH SET IDENTITY_INSERT #caregiver_schedule OFF; THROW; END CATCH;';
 ROLLBACK;
 INSERT #Results VALUES(16,N'caregiver_schedule主键重复',N'错误2627包含PK_M3_caregiver_schedule',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(16,N'caregiver_schedule主键重复',N'错误2627包含PK_M3_caregiver_schedule',@Message,CASE WHEN @Error=2627 AND CHARINDEX(N'PK_M3_caregiver_schedule',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T017: caregiver_schedule.caregiver_id拒绝NULL
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
UPDATE #caregiver_schedule SET [caregiver_id]=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(17,N'caregiver_schedule.caregiver_id拒绝NULL',N'错误515包含caregiver_id',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(17,N'caregiver_schedule.caregiver_id拒绝NULL',N'错误515包含caregiver_id',@Message,CASE WHEN @Error=515 AND CHARINDEX(N'caregiver_id',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T018: caregiver_schedule.start_time拒绝NULL
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
UPDATE #caregiver_schedule SET [start_time]=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(18,N'caregiver_schedule.start_time拒绝NULL',N'错误515包含start_time',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(18,N'caregiver_schedule.start_time拒绝NULL',N'错误515包含start_time',@Message,CASE WHEN @Error=515 AND CHARINDEX(N'start_time',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T019: caregiver_schedule.end_time拒绝NULL
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
UPDATE #caregiver_schedule SET [end_time]=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(19,N'caregiver_schedule.end_time拒绝NULL',N'错误515包含end_time',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(19,N'caregiver_schedule.end_time拒绝NULL',N'错误515包含end_time',@Message,CASE WHEN @Error=515 AND CHARINDEX(N'end_time',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T020: caregiver_schedule.max_orders拒绝NULL
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
UPDATE #caregiver_schedule SET [max_orders]=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(20,N'caregiver_schedule.max_orders拒绝NULL',N'错误515包含max_orders',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(20,N'caregiver_schedule.max_orders拒绝NULL',N'错误515包含max_orders',@Message,CASE WHEN @Error=515 AND CHARINDEX(N'max_orders',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T021: caregiver_schedule.schedule_status拒绝NULL
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
UPDATE #caregiver_schedule SET [schedule_status]=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(21,N'caregiver_schedule.schedule_status拒绝NULL',N'错误515包含schedule_status',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(21,N'caregiver_schedule.schedule_status拒绝NULL',N'错误515包含schedule_status',@Message,CASE WHEN @Error=515 AND CHARINDEX(N'schedule_status',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T022: work_record主键重复
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
SET IDENTITY_INSERT #work_record ON; BEGIN TRY INSERT #work_record (work_id,schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status,review_note) SELECT work_id,schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status,review_note FROM #work_record; SET IDENTITY_INSERT #work_record OFF; END TRY BEGIN CATCH SET IDENTITY_INSERT #work_record OFF; THROW; END CATCH;';
 ROLLBACK;
 INSERT #Results VALUES(22,N'work_record主键重复',N'错误2627包含PK_M3_work_record',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(22,N'work_record主键重复',N'错误2627包含PK_M3_work_record',@Message,CASE WHEN @Error=2627 AND CHARINDEX(N'PK_M3_work_record',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T023: work_record.schedule_id拒绝NULL
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
UPDATE #work_record SET [schedule_id]=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(23,N'work_record.schedule_id拒绝NULL',N'错误515包含schedule_id',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(23,N'work_record.schedule_id拒绝NULL',N'错误515包含schedule_id',@Message,CASE WHEN @Error=515 AND CHARINDEX(N'schedule_id',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T024: work_record.dispatch_id拒绝NULL
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
UPDATE #work_record SET [dispatch_id]=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(24,N'work_record.dispatch_id拒绝NULL',N'错误515包含dispatch_id',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(24,N'work_record.dispatch_id拒绝NULL',N'错误515包含dispatch_id',@Message,CASE WHEN @Error=515 AND CHARINDEX(N'dispatch_id',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T025: work_record.check_in_time拒绝NULL
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
UPDATE #work_record SET [check_in_time]=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(25,N'work_record.check_in_time拒绝NULL',N'错误515包含check_in_time',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(25,N'work_record.check_in_time拒绝NULL',N'错误515包含check_in_time',@Message,CASE WHEN @Error=515 AND CHARINDEX(N'check_in_time',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T026: work_record.fence_result拒绝NULL
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
UPDATE #work_record SET [fence_result]=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(26,N'work_record.fence_result拒绝NULL',N'错误515包含fence_result',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(26,N'work_record.fence_result拒绝NULL',N'错误515包含fence_result',@Message,CASE WHEN @Error=515 AND CHARINDEX(N'fence_result',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T027: work_record.review_status拒绝NULL
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
UPDATE #work_record SET [review_status]=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(27,N'work_record.review_status拒绝NULL',N'错误515包含review_status',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(27,N'work_record.review_status拒绝NULL',N'错误515包含review_status',@Message,CASE WHEN @Error=515 AND CHARINDEX(N'review_status',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T028: 证书两列唯一键
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_certificate(caregiver_id,certificate_no,certificate_type,service_id,qualification_level,valid_from,valid_to) VALUES(@c,N''ISO-C'',N''培训证书'',-1,N''初级'',''20300101'',''20301231'');
INSERT #caregiver_certificate(caregiver_id,certificate_no,certificate_type,service_id,qualification_level,valid_from,valid_to) VALUES(@c,N''ISO-C'',N''培训证书'',-1,N''初级'',''20300101'',''20301231'');
';
 ROLLBACK;
 INSERT #Results VALUES(28,N'证书两列唯一键',N'错误2627包含UQ_M3_certificate_caregiver_no',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(28,N'证书两列唯一键',N'错误2627包含UQ_M3_certificate_caregiver_no',@Message,CASE WHEN @Error=2627 AND CHARINDEX(N'UQ_M3_certificate_caregiver_no',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T029: 工时派单唯一键
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
';
 ROLLBACK;
 INSERT #Results VALUES(29,N'工时派单唯一键',N'错误2627包含UQ_M3_work_dispatch',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(29,N'工时派单唯一键',N'错误2627包含UQ_M3_work_dispatch',@Message,CASE WHEN @Error=2627 AND CHARINDEX(N'UQ_M3_work_dispatch',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T030: caregiver.employment_status_enum employment_status=N'未知'
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
UPDATE #caregiver SET employment_status=N''未知'';';
 ROLLBACK;
 INSERT #Results VALUES(30,N'caregiver.employment_status_enum employment_status=N''未知''',N'错误547包含CK_M3_caregiver_employment_status_enum',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(30,N'caregiver.employment_status_enum employment_status=N''未知''',N'错误547包含CK_M3_caregiver_employment_status_enum',@Message,CASE WHEN @Error=547 AND CHARINDEX(N'CK_M3_caregiver_employment_status_enum',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T031: caregiver_certificate.certificate_status_enum certificate_status=N'未知'
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_certificate(caregiver_id,certificate_no,certificate_type,service_id,qualification_level,valid_from,valid_to) VALUES(@c,N''ISO-C'',N''培训证书'',-1,N''初级'',''20300101'',''20301231'');
UPDATE #caregiver_certificate SET certificate_status=N''未知'';';
 ROLLBACK;
 INSERT #Results VALUES(31,N'caregiver_certificate.certificate_status_enum certificate_status=N''未知''',N'错误547包含CK_M3_caregiver_certificate_certificate_status_enum',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(31,N'caregiver_certificate.certificate_status_enum certificate_status=N''未知''',N'错误547包含CK_M3_caregiver_certificate_certificate_status_enum',@Message,CASE WHEN @Error=547 AND CHARINDEX(N'CK_M3_caregiver_certificate_certificate_status_enum',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T032: caregiver_certificate.valid_dates valid_to='20290101'
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_certificate(caregiver_id,certificate_no,certificate_type,service_id,qualification_level,valid_from,valid_to) VALUES(@c,N''ISO-C'',N''培训证书'',-1,N''初级'',''20300101'',''20301231'');
UPDATE #caregiver_certificate SET valid_to=''20290101'';';
 ROLLBACK;
 INSERT #Results VALUES(32,N'caregiver_certificate.valid_dates valid_to=''20290101''',N'错误547包含CK_M3_caregiver_certificate_valid_dates',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(32,N'caregiver_certificate.valid_dates valid_to=''20290101''',N'错误547包含CK_M3_caregiver_certificate_valid_dates',@Message,CASE WHEN @Error=547 AND CHARINDEX(N'CK_M3_caregiver_certificate_valid_dates',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T033: caregiver_schedule.schedule_status_enum schedule_status=N'未知'
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
UPDATE #caregiver_schedule SET schedule_status=N''未知'';';
 ROLLBACK;
 INSERT #Results VALUES(33,N'caregiver_schedule.schedule_status_enum schedule_status=N''未知''',N'错误547包含CK_M3_caregiver_schedule_schedule_status_enum',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(33,N'caregiver_schedule.schedule_status_enum schedule_status=N''未知''',N'错误547包含CK_M3_caregiver_schedule_schedule_status_enum',@Message,CASE WHEN @Error=547 AND CHARINDEX(N'CK_M3_caregiver_schedule_schedule_status_enum',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T034: caregiver_schedule.time_range end_time=start_time
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
UPDATE #caregiver_schedule SET end_time=start_time;';
 ROLLBACK;
 INSERT #Results VALUES(34,N'caregiver_schedule.time_range end_time=start_time',N'错误547包含CK_M3_caregiver_schedule_time_range',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(34,N'caregiver_schedule.time_range end_time=start_time',N'错误547包含CK_M3_caregiver_schedule_time_range',@Message,CASE WHEN @Error=547 AND CHARINDEX(N'CK_M3_caregiver_schedule_time_range',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T035: caregiver_schedule.positive_capacity max_orders=0
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
UPDATE #caregiver_schedule SET max_orders=0;';
 ROLLBACK;
 INSERT #Results VALUES(35,N'caregiver_schedule.positive_capacity max_orders=0',N'错误547包含CK_M3_caregiver_schedule_positive_capacity',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(35,N'caregiver_schedule.positive_capacity max_orders=0',N'错误547包含CK_M3_caregiver_schedule_positive_capacity',@Message,CASE WHEN @Error=547 AND CHARINDEX(N'CK_M3_caregiver_schedule_positive_capacity',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T036: work_record.fence_result_enum fence_result=N'未知'
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
UPDATE #work_record SET fence_result=N''未知'';';
 ROLLBACK;
 INSERT #Results VALUES(36,N'work_record.fence_result_enum fence_result=N''未知''',N'错误547包含CK_M3_work_record_fence_result_enum',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(36,N'work_record.fence_result_enum fence_result=N''未知''',N'错误547包含CK_M3_work_record_fence_result_enum',@Message,CASE WHEN @Error=547 AND CHARINDEX(N'CK_M3_work_record_fence_result_enum',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T037: work_record.review_status_enum review_status=N'未知'
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
UPDATE #work_record SET review_status=N''未知'';';
 ROLLBACK;
 INSERT #Results VALUES(37,N'work_record.review_status_enum review_status=N''未知''',N'错误547包含CK_M3_work_record_review_status_enum',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(37,N'work_record.review_status_enum review_status=N''未知''',N'错误547包含CK_M3_work_record_review_status_enum',@Message,CASE WHEN @Error=547 AND CHARINDEX(N'CK_M3_work_record_review_status_enum',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T038: work_record.checkout check_out_time=check_in_time
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
UPDATE #work_record SET check_out_time=check_in_time;';
 ROLLBACK;
 INSERT #Results VALUES(38,N'work_record.checkout check_out_time=check_in_time',N'错误547包含CK_M3_work_record_checkout',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(38,N'work_record.checkout check_out_time=check_in_time',N'错误547包含CK_M3_work_record_checkout',@Message,CASE WHEN @Error=547 AND CHARINDEX(N'CK_M3_work_record_checkout',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T039: work_record.minutes effective_minutes=-1
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
UPDATE #work_record SET effective_minutes=-1;';
 ROLLBACK;
 INSERT #Results VALUES(39,N'work_record.minutes effective_minutes=-1',N'错误547包含CK_M3_work_record_minutes',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(39,N'work_record.minutes effective_minutes=-1',N'错误547包含CK_M3_work_record_minutes',@Message,CASE WHEN @Error=547 AND CHARINDEX(N'CK_M3_work_record_minutes',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T040: work_record.minutes effective_minutes=61
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
UPDATE #work_record SET effective_minutes=61;';
 ROLLBACK;
 INSERT #Results VALUES(40,N'work_record.minutes effective_minutes=61',N'错误547包含CK_M3_work_record_minutes',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(40,N'work_record.minutes effective_minutes=61',N'错误547包含CK_M3_work_record_minutes',@Message,CASE WHEN @Error=547 AND CHARINDEX(N'CK_M3_work_record_minutes',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T041: work_record.minutes effective_minutes=2147483647
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
UPDATE #work_record SET effective_minutes=2147483647;';
 ROLLBACK;
 INSERT #Results VALUES(41,N'work_record.minutes effective_minutes=2147483647',N'错误547包含CK_M3_work_record_minutes',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(41,N'work_record.minutes effective_minutes=2147483647',N'错误547包含CK_M3_work_record_minutes',@Message,CASE WHEN @Error=547 AND CHARINDEX(N'CK_M3_work_record_minutes',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T042: work_record.review_ready effective_minutes=NULL
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
UPDATE #work_record SET effective_minutes=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(42,N'work_record.review_ready effective_minutes=NULL',N'错误547包含CK_M3_work_record_review_ready',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(42,N'work_record.review_ready effective_minutes=NULL',N'错误547包含CK_M3_work_record_review_ready',@Message,CASE WHEN @Error=547 AND CHARINDEX(N'CK_M3_work_record_review_ready',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T043: work_record.review_ready review_status=N'待审核'
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
UPDATE #work_record SET review_status=N''待审核'';';
 ROLLBACK;
 INSERT #Results VALUES(43,N'work_record.review_ready review_status=N''待审核''',N'错误547包含CK_M3_work_record_review_ready',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(43,N'work_record.review_ready review_status=N''待审核''',N'错误547包含CK_M3_work_record_review_ready',@Message,CASE WHEN @Error=547 AND CHARINDEX(N'CK_M3_work_record_review_ready',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T044: work_record.abnormal_note fence_result=N'未通过'
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
UPDATE #work_record SET fence_result=N''未通过'';';
 ROLLBACK;
 INSERT #Results VALUES(44,N'work_record.abnormal_note fence_result=N''未通过''',N'错误547包含CK_M3_work_record_abnormal_note',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(44,N'work_record.abnormal_note fence_result=N''未通过''',N'错误547包含CK_M3_work_record_abnormal_note',@Message,CASE WHEN @Error=547 AND CHARINDEX(N'CK_M3_work_record_abnormal_note',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T045: work_record.abnormal_note check_out_location=NULL
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
UPDATE #work_record SET check_out_location=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(45,N'work_record.abnormal_note check_out_location=NULL',N'错误547包含CK_M3_work_record_abnormal_note',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(45,N'work_record.abnormal_note check_out_location=NULL',N'错误547包含CK_M3_work_record_abnormal_note',@Message,CASE WHEN @Error=547 AND CHARINDEX(N'CK_M3_work_record_abnormal_note',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T046: 未签退不能有签退位置
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
UPDATE #work_record SET check_out_time=NULL,effective_minutes=NULL,review_status=N''待审核'';';
 ROLLBACK;
 INSERT #Results VALUES(46,N'未签退不能有签退位置',N'错误547包含checkout_location',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(46,N'未签退不能有签退位置',N'错误547包含checkout_location',@Message,CASE WHEN @Error=547 AND CHARINDEX(N'checkout_location',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T047: 无签退不能认可工时
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
UPDATE #work_record SET check_out_time=NULL,check_out_location=NULL;';
 ROLLBACK;
 INSERT #Results VALUES(47,N'无签退不能认可工时',N'错误547包含minutes',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(47,N'无签退不能认可工时',N'错误547包含minutes',@Message,CASE WHEN @Error=547 AND CHARINDEX(N'minutes',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T048: 空白异常说明拒绝
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
UPDATE #work_record SET fence_result=N''未通过'',review_note=NCHAR(9)+NCHAR(10)+N''　 '';';
 ROLLBACK;
 INSERT #Results VALUES(48,N'空白异常说明拒绝',N'错误547包含abnormal_note',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(48,N'空白异常说明拒绝',N'错误547包含abnormal_note',@Message,CASE WHEN @Error=547 AND CHARINDEX(N'abnormal_note',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T049: caregiver默认值
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
IF NOT EXISTS(SELECT 1 FROM #caregiver WHERE employment_status=N''在岗'') THROW 51999,N''默认值不符'',1;';
 ROLLBACK;
 INSERT #Results VALUES(49,N'caregiver默认值',N'成功并回滚',N'语句成功',N'PASS');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(49,N'caregiver默认值',N'成功并回滚',@Message,CASE WHEN @Error=-1 AND CHARINDEX(N'',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T050: caregiver_certificate默认值
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_certificate(caregiver_id,certificate_no,certificate_type,service_id,qualification_level,valid_from,valid_to) VALUES(@c,N''ISO-C'',N''培训证书'',-1,N''初级'',''20300101'',''20301231'');
IF NOT EXISTS(SELECT 1 FROM #caregiver_certificate WHERE certificate_status=N''有效'') THROW 51999,N''默认值不符'',1;';
 ROLLBACK;
 INSERT #Results VALUES(50,N'caregiver_certificate默认值',N'成功并回滚',N'语句成功',N'PASS');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(50,N'caregiver_certificate默认值',N'成功并回滚',@Message,CASE WHEN @Error=-1 AND CHARINDEX(N'',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T051: caregiver_schedule默认值
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
IF NOT EXISTS(SELECT 1 FROM #caregiver_schedule WHERE schedule_status=N''开放'') THROW 51999,N''默认值不符'',1;';
 ROLLBACK;
 INSERT #Results VALUES(51,N'caregiver_schedule默认值',N'成功并回滚',N'语句成功',N'PASS');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(51,N'caregiver_schedule默认值',N'成功并回滚',@Message,CASE WHEN @Error=-1 AND CHARINDEX(N'',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T052: 工时两个默认值
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time) VALUES(@s,-1,''20300105 08:00:00''); IF NOT EXISTS(SELECT 1 FROM #work_record WHERE fence_result=N''待校验'' AND review_status=N''待审核'' AND effective_minutes IS NULL) THROW 51999,N''默认值不符'',1;';
 ROLLBACK;
 INSERT #Results VALUES(52,N'工时两个默认值',N'成功并回滚',N'语句成功',N'PASS');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(52,N'工时两个默认值',N'成功并回滚',@Message,CASE WHEN @Error=-1 AND CHARINDEX(N'',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T053: 有效期同日合法
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_certificate(caregiver_id,certificate_no,certificate_type,service_id,qualification_level,valid_from,valid_to) VALUES(@c,N''ISO-C'',N''培训证书'',-1,N''初级'',''20300101'',''20301231'');
UPDATE #caregiver_certificate SET valid_to=valid_from;';
 ROLLBACK;
 INSERT #Results VALUES(53,N'有效期同日合法',N'成功并回滚',N'语句成功',N'PASS');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(53,N'有效期同日合法',N'成功并回滚',@Message,CASE WHEN @Error=-1 AND CHARINDEX(N'',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T054: 实际不足一分钟认可零分钟
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
UPDATE #work_record SET check_out_time=DATEADD(SECOND,59,check_in_time),effective_minutes=0;';
 ROLLBACK;
 INSERT #Results VALUES(54,N'实际不足一分钟认可零分钟',N'成功并回滚',N'语句成功',N'PASS');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(54,N'实际不足一分钟认可零分钟',N'成功并回滚',@Message,CASE WHEN @Error=-1 AND CHARINDEX(N'',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T055: 分钟边界不得计为一分钟
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
UPDATE #work_record SET check_out_time=DATEADD(SECOND,59,check_in_time),effective_minutes=1;';
 ROLLBACK;
 INSERT #Results VALUES(55,N'分钟边界不得计为一分钟',N'错误547包含minutes',N'语句成功',N'FAIL');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(55,N'分钟边界不得计为一分钟',N'错误547包含minutes',@Message,CASE WHEN @Error=547 AND CHARINDEX(N'minutes',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T056: 异常通过保留结果及说明
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
UPDATE #work_record SET fence_result=N''未通过'',review_note=N''测试核实依据'',effective_minutes=30;';
 ROLLBACK;
 INSERT #Results VALUES(56,N'异常通过保留结果及说明',N'成功并回滚',N'语句成功',N'PASS');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(56,N'异常通过保留结果及说明',N'成功并回滚',@Message,CASE WHEN @Error=-1 AND CHARINDEX(N'',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T057: 缺定位通过须说明的合法情况
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
UPDATE #work_record SET check_in_location=NULL,review_note=N''已人工核实'';';
 ROLLBACK;
 INSERT #Results VALUES(57,N'缺定位通过须说明的合法情况',N'成功并回滚',N'语句成功',N'PASS');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(57,N'缺定位通过须说明的合法情况',N'成功并回滚',@Message,CASE WHEN @Error=-1 AND CHARINDEX(N'',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T058: 驳回有效分钟为空合法
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20300105 08:00:00'',''20300105 12:00:00'',2); DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());
INSERT #work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status) VALUES(@s,-1,''20300105 08:00:00'',''20300105 09:00:00'',N''39.99,116.33'',N''39.99,116.33'',N''通过'',60,N''通过'');
UPDATE #work_record SET review_status=N''驳回'',effective_minutes=NULL,fence_result=N''未通过'';';
 ROLLBACK;
 INSERT #Results VALUES(58,N'驳回有效分钟为空合法',N'成功并回滚',N'语句成功',N'PASS');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(58,N'驳回有效分钟为空合法',N'成功并回滚',@Message,CASE WHEN @Error=-1 AND CHARINDEX(N'',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- T059: 同护工不同证书合法
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT #caregiver(caregiver_name,org_id,phone,service_area) VALUES(N''隔离护工'',-1,''00000000000'',N''隔离社区''); DECLARE @c int=CONVERT(int,SCOPE_IDENTITY());
INSERT #caregiver_certificate(caregiver_id,certificate_no,certificate_type,service_id,qualification_level,valid_from,valid_to) VALUES(@c,N''ISO-C'',N''培训证书'',-1,N''初级'',''20300101'',''20301231'');
INSERT #caregiver_certificate(caregiver_id,certificate_no,certificate_type,service_id,qualification_level,valid_from,valid_to) VALUES(@c,N''ISO-C2'',N''培训证书'',-1,N''中级'',''20300101'',''20301231'');';
 ROLLBACK;
 INSERT #Results VALUES(59,N'同护工不同证书合法',N'成功并回滚',N'语句成功',N'PASS');
END TRY
BEGIN CATCH
 SELECT @Error=ERROR_NUMBER(),@Message=ERROR_MESSAGE();
 IF XACT_STATE()<>0 ROLLBACK;
 INSERT #Results VALUES(59,N'同护工不同证书合法',N'成功并回滚',@Message,CASE WHEN @Error=-1 AND CHARINDEX(N'',@Message)>0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;
SELECT * FROM #Results ORDER BY id; SELECT status,COUNT(*) AS cases FROM #Results GROUP BY status; IF EXISTS(SELECT 1 FROM #Results WHERE status='FAIL') THROW 51106,N'隔离声明式约束测试存在失败，参见结果。',1;
-- 外键、真实dbo插入和业务并发未在上述临时副本中验证。
