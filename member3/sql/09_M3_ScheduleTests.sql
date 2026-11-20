-- 指定已有、获准测试的护工编号；默认NULL不写入。
-- 不创建机构表，不猜测其他成员ID。每个用例独立事务并回滚。
SET NOCOUNT ON; SET XACT_ABORT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
IF DB_ID()<=4 OR @@TRANCOUNT<>0 THROW 51202,N'请选择专用测试库并结束外层事务。',1;
DECLARE @TestCaregiverID int=NULL,@OtherCaregiverID int=NULL;
IF @TestCaregiverID IS NULL OR @OtherCaregiverID IS NULL BEGIN
 SELECT N'BLOCKED：请提供两名已存在且无排班的专用测试护工；不得填猜测的机构或护工ID。' AS status; RETURN;
END;
IF @TestCaregiverID=@OtherCaregiverID OR (SELECT COUNT(*) FROM dbo.caregiver WHERE caregiver_id IN(@TestCaregiverID,@OtherCaregiverID))<>2
 THROW 51202,N'需两名不同且存在的专用测试护工。',1;
IF EXISTS(SELECT 1 FROM dbo.caregiver_schedule WHERE caregiver_id IN(@TestCaregiverID,@OtherCaregiverID))
 THROW 51202,N'专用测试护工已有排班，请换用空夹具，不删除原记录。',1;
IF NOT EXISTS(SELECT 1 FROM sys.triggers WHERE object_id=OBJECT_ID(N'dbo.TR_M3_Schedule_NoOverlap') AND is_disabled=0)
 THROW 51202,N'必须先启用08触发器。',1;
IF OBJECT_ID(N'tempdb..#ScheduleResults') IS NOT NULL DROP TABLE #ScheduleResults;
CREATE TABLE #ScheduleResults(id int,name nvarchar(200),status varchar(8),detail nvarchar(2048));
DECLARE @Err int,@Msg nvarchar(2048);

-- S01 正常新增
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 08:00:00'',''20310105 12:00:00'',2,N''开放'');',N'@c int,@other int',@TestCaregiverID,@OtherCaregiverID;
 ROLLBACK;
 INSERT #ScheduleResults VALUES(1,N'正常新增','PASS',N'语句成功，已回滚');
END TRY
BEGIN CATCH
 SELECT @Err=ERROR_NUMBER(),@Msg=ERROR_MESSAGE(); IF XACT_STATE()<>0 ROLLBACK;
 INSERT #ScheduleResults VALUES(1,N'正常新增',CASE WHEN @Err=-1 THEN 'PASS' ELSE 'FAIL' END,@Msg);
END CATCH;

-- S02 部分重叠
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 08:00:00'',''20310105 12:00:00'',2,N''开放'');DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 11:00:00'',''20310105 13:00:00'',2,N''开放'');',N'@c int,@other int',@TestCaregiverID,@OtherCaregiverID;
 ROLLBACK;
 INSERT #ScheduleResults VALUES(2,N'部分重叠','FAIL',N'语句成功，已回滚');
END TRY
BEGIN CATCH
 SELECT @Err=ERROR_NUMBER(),@Msg=ERROR_MESSAGE(); IF XACT_STATE()<>0 ROLLBACK;
 INSERT #ScheduleResults VALUES(2,N'部分重叠',CASE WHEN @Err=51201 THEN 'PASS' ELSE 'FAIL' END,@Msg);
END CATCH;

-- S03 完全包含
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 08:00:00'',''20310105 12:00:00'',2,N''开放'');DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 09:00:00'',''20310105 10:00:00'',2,N''开放'');',N'@c int,@other int',@TestCaregiverID,@OtherCaregiverID;
 ROLLBACK;
 INSERT #ScheduleResults VALUES(3,N'完全包含','FAIL',N'语句成功，已回滚');
END TRY
BEGIN CATCH
 SELECT @Err=ERROR_NUMBER(),@Msg=ERROR_MESSAGE(); IF XACT_STATE()<>0 ROLLBACK;
 INSERT #ScheduleResults VALUES(3,N'完全包含',CASE WHEN @Err=51201 THEN 'PASS' ELSE 'FAIL' END,@Msg);
END CATCH;

-- S04 被新班次包住
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 08:00:00'',''20310105 12:00:00'',2,N''开放'');DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 07:00:00'',''20310105 13:00:00'',2,N''开放'');',N'@c int,@other int',@TestCaregiverID,@OtherCaregiverID;
 ROLLBACK;
 INSERT #ScheduleResults VALUES(4,N'被新班次包住','FAIL',N'语句成功，已回滚');
END TRY
BEGIN CATCH
 SELECT @Err=ERROR_NUMBER(),@Msg=ERROR_MESSAGE(); IF XACT_STATE()<>0 ROLLBACK;
 INSERT #ScheduleResults VALUES(4,N'被新班次包住',CASE WHEN @Err=51201 THEN 'PASS' ELSE 'FAIL' END,@Msg);
END CATCH;

-- S05 相同区间
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 08:00:00'',''20310105 12:00:00'',2,N''开放'');DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 08:00:00'',''20310105 12:00:00'',2,N''开放'');',N'@c int,@other int',@TestCaregiverID,@OtherCaregiverID;
 ROLLBACK;
 INSERT #ScheduleResults VALUES(5,N'相同区间','FAIL',N'语句成功，已回滚');
END TRY
BEGIN CATCH
 SELECT @Err=ERROR_NUMBER(),@Msg=ERROR_MESSAGE(); IF XACT_STATE()<>0 ROLLBACK;
 INSERT #ScheduleResults VALUES(5,N'相同区间',CASE WHEN @Err=51201 THEN 'PASS' ELSE 'FAIL' END,@Msg);
END CATCH;

-- S06 右侧相邻允许
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 08:00:00'',''20310105 12:00:00'',2,N''开放'');DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 12:00:00'',''20310105 16:00:00'',2,N''开放'');',N'@c int,@other int',@TestCaregiverID,@OtherCaregiverID;
 ROLLBACK;
 INSERT #ScheduleResults VALUES(6,N'右侧相邻允许','PASS',N'语句成功，已回滚');
END TRY
BEGIN CATCH
 SELECT @Err=ERROR_NUMBER(),@Msg=ERROR_MESSAGE(); IF XACT_STATE()<>0 ROLLBACK;
 INSERT #ScheduleResults VALUES(6,N'右侧相邻允许',CASE WHEN @Err=-1 THEN 'PASS' ELSE 'FAIL' END,@Msg);
END CATCH;

-- S07 左侧相邻允许
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 08:00:00'',''20310105 12:00:00'',2,N''开放'');DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 06:00:00'',''20310105 08:00:00'',2,N''开放'');',N'@c int,@other int',@TestCaregiverID,@OtherCaregiverID;
 ROLLBACK;
 INSERT #ScheduleResults VALUES(7,N'左侧相邻允许','PASS',N'语句成功，已回滚');
END TRY
BEGIN CATCH
 SELECT @Err=ERROR_NUMBER(),@Msg=ERROR_MESSAGE(); IF XACT_STATE()<>0 ROLLBACK;
 INSERT #ScheduleResults VALUES(7,N'左侧相邻允许',CASE WHEN @Err=-1 THEN 'PASS' ELSE 'FAIL' END,@Msg);
END CATCH;

-- S08 新增取消班不冲突
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 08:00:00'',''20310105 12:00:00'',2,N''开放'');DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 09:00:00'',''20310105 10:00:00'',2,N''取消'');',N'@c int,@other int',@TestCaregiverID,@OtherCaregiverID;
 ROLLBACK;
 INSERT #ScheduleResults VALUES(8,N'新增取消班不冲突','PASS',N'语句成功，已回滚');
END TRY
BEGIN CATCH
 SELECT @Err=ERROR_NUMBER(),@Msg=ERROR_MESSAGE(); IF XACT_STATE()<>0 ROLLBACK;
 INSERT #ScheduleResults VALUES(8,N'新增取消班不冲突',CASE WHEN @Err=-1 THEN 'PASS' ELSE 'FAIL' END,@Msg);
END CATCH;

-- S09 已有取消班不参与
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 08:00:00'',''20310105 12:00:00'',2,N''取消'');INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 09:00:00'',''20310105 10:00:00'',2,N''开放'');',N'@c int,@other int',@TestCaregiverID,@OtherCaregiverID;
 ROLLBACK;
 INSERT #ScheduleResults VALUES(9,N'已有取消班不参与','PASS',N'语句成功，已回滚');
END TRY
BEGIN CATCH
 SELECT @Err=ERROR_NUMBER(),@Msg=ERROR_MESSAGE(); IF XACT_STATE()<>0 ROLLBACK;
 INSERT #ScheduleResults VALUES(9,N'已有取消班不参与',CASE WHEN @Err=-1 THEN 'PASS' ELSE 'FAIL' END,@Msg);
END CATCH;

-- S10 关闭班仍参与
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 08:00:00'',''20310105 12:00:00'',2,N''关闭'');INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 09:00:00'',''20310105 10:00:00'',2,N''开放'');',N'@c int,@other int',@TestCaregiverID,@OtherCaregiverID;
 ROLLBACK;
 INSERT #ScheduleResults VALUES(10,N'关闭班仍参与','FAIL',N'语句成功，已回滚');
END TRY
BEGIN CATCH
 SELECT @Err=ERROR_NUMBER(),@Msg=ERROR_MESSAGE(); IF XACT_STATE()<>0 ROLLBACK;
 INSERT #ScheduleResults VALUES(10,N'关闭班仍参与',CASE WHEN @Err=51201 THEN 'PASS' ELSE 'FAIL' END,@Msg);
END CATCH;

-- S11 仅修改自身不误报
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 08:00:00'',''20310105 12:00:00'',2,N''开放'');DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());UPDATE dbo.caregiver_schedule SET start_time=''20310105 08:30:00'' WHERE schedule_id=@s;',N'@c int,@other int',@TestCaregiverID,@OtherCaregiverID;
 ROLLBACK;
 INSERT #ScheduleResults VALUES(11,N'仅修改自身不误报','PASS',N'语句成功，已回滚');
END TRY
BEGIN CATCH
 SELECT @Err=ERROR_NUMBER(),@Msg=ERROR_MESSAGE(); IF XACT_STATE()<>0 ROLLBACK;
 INSERT #ScheduleResults VALUES(11,N'仅修改自身不误报',CASE WHEN @Err=-1 THEN 'PASS' ELSE 'FAIL' END,@Msg);
END CATCH;

-- S12 修改为重叠
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 08:00:00'',''20310105 12:00:00'',2,N''开放'');DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 12:00:00'',''20310105 16:00:00'',2,N''开放'');UPDATE dbo.caregiver_schedule SET start_time=''20310105 11:00:00'' WHERE schedule_id=CONVERT(int,SCOPE_IDENTITY());',N'@c int,@other int',@TestCaregiverID,@OtherCaregiverID;
 ROLLBACK;
 INSERT #ScheduleResults VALUES(12,N'修改为重叠','FAIL',N'语句成功，已回滚');
END TRY
BEGIN CATCH
 SELECT @Err=ERROR_NUMBER(),@Msg=ERROR_MESSAGE(); IF XACT_STATE()<>0 ROLLBACK;
 INSERT #ScheduleResults VALUES(12,N'修改为重叠',CASE WHEN @Err=51201 THEN 'PASS' ELSE 'FAIL' END,@Msg);
END CATCH;

-- S13 取消后可新增
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 08:00:00'',''20310105 12:00:00'',2,N''开放'');DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());UPDATE dbo.caregiver_schedule SET schedule_status=N''取消'' WHERE schedule_id=@s;INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 08:00:00'',''20310105 12:00:00'',2,N''开放'');',N'@c int,@other int',@TestCaregiverID,@OtherCaregiverID;
 ROLLBACK;
 INSERT #ScheduleResults VALUES(13,N'取消后可新增','PASS',N'语句成功，已回滚');
END TRY
BEGIN CATCH
 SELECT @Err=ERROR_NUMBER(),@Msg=ERROR_MESSAGE(); IF XACT_STATE()<>0 ROLLBACK;
 INSERT #ScheduleResults VALUES(13,N'取消后可新增',CASE WHEN @Err=-1 THEN 'PASS' ELSE 'FAIL' END,@Msg);
END CATCH;

-- S14 恢复取消班会冲突
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 08:00:00'',''20310105 12:00:00'',2,N''取消'');DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 08:00:00'',''20310105 12:00:00'',2,N''开放'');UPDATE dbo.caregiver_schedule SET schedule_status=N''开放'' WHERE schedule_id=@s;',N'@c int,@other int',@TestCaregiverID,@OtherCaregiverID;
 ROLLBACK;
 INSERT #ScheduleResults VALUES(14,N'恢复取消班会冲突','FAIL',N'语句成功，已回滚');
END TRY
BEGIN CATCH
 SELECT @Err=ERROR_NUMBER(),@Msg=ERROR_MESSAGE(); IF XACT_STATE()<>0 ROLLBACK;
 INSERT #ScheduleResults VALUES(14,N'恢复取消班会冲突',CASE WHEN @Err=51201 THEN 'PASS' ELSE 'FAIL' END,@Msg);
END CATCH;

-- S15 不同护工允许同时段
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 08:00:00'',''20310105 12:00:00'',2,N''开放'');DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@other,''20310105 08:00:00'',''20310105 12:00:00'',2,N''开放'');',N'@c int,@other int',@TestCaregiverID,@OtherCaregiverID;
 ROLLBACK;
 INSERT #ScheduleResults VALUES(15,N'不同护工允许同时段','PASS',N'语句成功，已回滚');
END TRY
BEGIN CATCH
 SELECT @Err=ERROR_NUMBER(),@Msg=ERROR_MESSAGE(); IF XACT_STATE()<>0 ROLLBACK;
 INSERT #ScheduleResults VALUES(15,N'不同护工允许同时段',CASE WHEN @Err=-1 THEN 'PASS' ELSE 'FAIL' END,@Msg);
END CATCH;

-- S16 修改护工产生冲突
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@c,''20310105 08:00:00'',''20310105 12:00:00'',2,N''开放'');DECLARE @s int=CONVERT(int,SCOPE_IDENTITY());INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status) VALUES(@other,''20310105 08:00:00'',''20310105 12:00:00'',2,N''开放'');UPDATE dbo.caregiver_schedule SET caregiver_id=@c WHERE schedule_id=CONVERT(int,SCOPE_IDENTITY());',N'@c int,@other int',@TestCaregiverID,@OtherCaregiverID;
 ROLLBACK;
 INSERT #ScheduleResults VALUES(16,N'修改护工产生冲突','FAIL',N'语句成功，已回滚');
END TRY
BEGIN CATCH
 SELECT @Err=ERROR_NUMBER(),@Msg=ERROR_MESSAGE(); IF XACT_STATE()<>0 ROLLBACK;
 INSERT #ScheduleResults VALUES(16,N'修改护工产生冲突',CASE WHEN @Err=51201 THEN 'PASS' ELSE 'FAIL' END,@Msg);
END CATCH;

-- S17 多行同批互相重叠
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20310105 08:00:00'',''20310105 12:00:00'',2),(@c,''20310105 11:00:00'',''20310105 13:00:00'',2);',N'@c int,@other int',@TestCaregiverID,@OtherCaregiverID;
 ROLLBACK;
 INSERT #ScheduleResults VALUES(17,N'多行同批互相重叠','FAIL',N'语句成功，已回滚');
END TRY
BEGIN CATCH
 SELECT @Err=ERROR_NUMBER(),@Msg=ERROR_MESSAGE(); IF XACT_STATE()<>0 ROLLBACK;
 INSERT #ScheduleResults VALUES(17,N'多行同批互相重叠',CASE WHEN @Err=51201 THEN 'PASS' ELSE 'FAIL' END,@Msg);
END CATCH;

-- S18 多行相邻合法
BEGIN TRY
 BEGIN TRAN;
 EXEC sys.sp_executesql N'INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders) VALUES(@c,''20310105 08:00:00'',''20310105 12:00:00'',2),(@c,''20310105 12:00:00'',''20310105 16:00:00'',2);',N'@c int,@other int',@TestCaregiverID,@OtherCaregiverID;
 ROLLBACK;
 INSERT #ScheduleResults VALUES(18,N'多行相邻合法','PASS',N'语句成功，已回滚');
END TRY
BEGIN CATCH
 SELECT @Err=ERROR_NUMBER(),@Msg=ERROR_MESSAGE(); IF XACT_STATE()<>0 ROLLBACK;
 INSERT #ScheduleResults VALUES(18,N'多行相邻合法',CASE WHEN @Err=-1 THEN 'PASS' ELSE 'FAIL' END,@Msg);
END CATCH;
SELECT * FROM #ScheduleResults ORDER BY id; SELECT status,COUNT(*) AS cases FROM #ScheduleResults GROUP BY status; DECLARE @Failed bit=CASE WHEN EXISTS(SELECT 1 FROM #ScheduleResults WHERE status='FAIL') THEN 1 ELSE 0 END; DROP TABLE #ScheduleResults; IF @Failed=1 THROW 51202,N'排班测试存在失败',1;