-- 新增规则，不改变表、字段或01—07；SQL Server 2016+。
-- 在专用用户数据库先部署01及03。首次部署使用，不覆盖已有同名触发器。
SET NOCOUNT ON; SET XACT_ABORT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON;
IF DB_ID()<=4 OR @@TRANCOUNT<>0 THROW 51200,N'请选择用户数据库并结束外层事务。',1;
BEGIN TRY
 BEGIN TRAN;
 IF OBJECT_ID(N'dbo.caregiver_schedule',N'U') IS NULL OR OBJECT_ID(N'dbo.caregiver',N'U') IS NULL
  THROW 51200,N'请先部署成员3基础表。',1;
 IF OBJECT_ID(N'dbo.TR_M3_Schedule_NoOverlap') IS NOT NULL THROW 51200,N'同名触发器已存在，未覆盖。',1;
 -- 部署时锁定排班表，既有非法排班须先核实处理，不删除或自动更正。
 IF EXISTS(SELECT 1 FROM dbo.caregiver_schedule a WITH(TABLOCKX,HOLDLOCK)
  JOIN dbo.caregiver_schedule b ON a.caregiver_id=b.caregiver_id AND a.schedule_id<b.schedule_id
  WHERE a.schedule_status<>N'取消' AND b.schedule_status<>N'取消'
   AND a.start_time<b.end_time AND b.start_time<a.end_time)
  THROW 51200,N'已有未取消排班重叠，请核实原数据；未部署触发器。',1;
 EXEC sys.sp_executesql N'CREATE TRIGGER dbo.TR_M3_Schedule_NoOverlap
ON dbo.caregiver_schedule
AFTER INSERT, UPDATE
AS
BEGIN
 SET NOCOUNT ON;
 IF NOT EXISTS(SELECT 1 FROM inserted) RETURN;
 -- 包含原护工和新护工；跨护工批量修改按统一编号顺序获取锁。
 DECLARE @Affected TABLE(caregiver_id int PRIMARY KEY);
 INSERT @Affected SELECT caregiver_id FROM inserted UNION SELECT caregiver_id FROM deleted;
 DECLARE @CaregiverID int,@LockedID int;
 DECLARE CaregiverLocks CURSOR LOCAL FAST_FORWARD FOR SELECT caregiver_id FROM @Affected ORDER BY caregiver_id;
 OPEN CaregiverLocks;
 FETCH NEXT FROM CaregiverLocks INTO @CaregiverID;
 WHILE @@FETCH_STATUS=0 BEGIN
  -- 同一护工的并发写操作串行复核，锁保留到调用事务结束。
  SELECT @LockedID=caregiver_id FROM dbo.caregiver WITH(UPDLOCK,HOLDLOCK)
   WHERE caregiver_id=@CaregiverID;
  FETCH NEXT FROM CaregiverLocks INTO @CaregiverID;
 END;
 CLOSE CaregiverLocks; DEALLOCATE CaregiverLocks;
 -- 使用锁定读取当前数据及键范围，避免快照读遗漏并发已提交班次。
 -- 自身按编号排除；开放/关闭都参与，只有取消不参与。
 IF EXISTS(
  SELECT 1 FROM dbo.caregiver_schedule a WITH(UPDLOCK,HOLDLOCK)
  JOIN dbo.caregiver_schedule b WITH(UPDLOCK,HOLDLOCK)
   ON a.caregiver_id=b.caregiver_id AND a.schedule_id<b.schedule_id
   AND a.start_time<b.end_time AND b.start_time<a.end_time
  JOIN @Affected f ON f.caregiver_id=a.caregiver_id
  WHERE a.schedule_status<>N''取消'' AND b.schedule_status<>N''取消''
 ) THROW 51201,N''同一护工未取消的排班区间不能重叠；允许相邻班次首尾衔接。'',1;
END;';
 COMMIT;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK;
 THROW;
END CATCH;
