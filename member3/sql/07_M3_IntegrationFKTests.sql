-- 真实dbo外键测试：只在专用整合测试库执行；不修改成员1/2表。
-- 需05的BASE/WORK记录及真实可信外键。缺前置时逐项SKIP，不假造父表或ID。
SET NOCOUNT ON; SET XACT_ABORT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_WARNINGS ON;
SET ANSI_PADDING ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
IF DB_ID()<=4 OR @@TRANCOUNT<>0 THROW 51107,N'请选择专用测试库并结束外层事务。',1;
DECLARE @AllowIntegrationWrite bit=0;
IF @AllowIntegrationWrite=0 BEGIN
 SELECT N'BLOCKED：真实外键DML测试默认关闭；确认05批次和父表后开启。' AS status;
 RETURN;
END;
DECLARE @Cases TABLE(id int,t sysname,c sysname,pk sysname,target sysname,target_col sysname,fk sysname);
INSERT @Cases VALUES
(1,N'caregiver',N'org_id',N'caregiver_id',N'service_org',N'org_id',N'FK_M3_caregiver_org_id'),
(2,N'caregiver_certificate',N'caregiver_id',N'certificate_id',N'caregiver',N'caregiver_id',N'FK_M3_caregiver_certificate_caregiver_id'),
(3,N'caregiver_certificate',N'service_id',N'certificate_id',N'service_item',N'service_id',N'FK_M3_caregiver_certificate_service_id'),
(4,N'caregiver_schedule',N'caregiver_id',N'schedule_id',N'caregiver',N'caregiver_id',N'FK_M3_caregiver_schedule_caregiver_id'),
(5,N'work_record',N'schedule_id',N'work_id',N'caregiver_schedule',N'schedule_id',N'FK_M3_work_record_schedule_id'),
(6,N'work_record',N'dispatch_id',N'work_id',N'dispatch_record',N'dispatch_id',N'FK_M3_work_record_dispatch_id');
DECLARE @Results TABLE(id int,name nvarchar(250),status varchar(8),detail nvarchar(2048));
DECLARE @i int=1,@t sysname,@c sysname,@pk sysname,@target sysname,@tc sysname,@fk sysname,@sql nvarchar(max),@row int,@bad int,@msg nvarchar(2048),@err int;
WHILE @i<=6 BEGIN
 SELECT @t=t,@c=c,@pk=pk,@target=target,@tc=target_col,@fk=fk FROM @Cases WHERE id=@i;
 SET @row=NULL; SET @bad=NULL;
 IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE parent_object_id=OBJECT_ID(N'dbo.'+@t) AND name=@fk AND is_disabled=0 AND is_not_trusted=0)
  INSERT @Results VALUES(@i,@t+N'.'+@c,'SKIP',N'目标外键缺失/禁用/不可信，先完成整合');
 ELSE BEGIN
  -- 只挑选明确标记的05测试批次，不更新任意已有真实业务行。
  IF @t=N'caregiver' SELECT @row=MIN(caregiver_id) FROM dbo.caregiver WHERE caregiver_name LIKE N'M3T2030护工%';
  IF @t=N'caregiver_certificate' SELECT @row=MIN(certificate_id) FROM dbo.caregiver_certificate WHERE certificate_no LIKE N'M3T2030-%';
  IF @t=N'caregiver_schedule' SELECT @row=MIN(s.schedule_id) FROM dbo.caregiver_schedule s JOIN dbo.caregiver c ON c.caregiver_id=s.caregiver_id WHERE c.caregiver_name LIKE N'M3T2030护工%';
  IF @t=N'work_record' SELECT @row=MIN(w.work_id) FROM dbo.work_record w JOIN dbo.caregiver_schedule s ON s.schedule_id=w.schedule_id JOIN dbo.caregiver c ON c.caregiver_id=s.caregiver_id WHERE c.caregiver_name LIKE N'M3T2030护工%';
  IF @row IS NULL INSERT @Results VALUES(@i,@t+N'.'+@c,'SKIP',N'缺少05指定测试批次记录');
  ELSE BEGIN
   -- 从父表实际内容查找不存在的值；不是假定父表合法自增ID。
   SET @sql=N'DECLARE @x bigint=-2147483648; WHILE EXISTS(SELECT 1 FROM dbo.'+QUOTENAME(@target)+N' WHERE '+QUOTENAME(@tc)+N'=@x) SET @x+=1; IF @x>2147483647 THROW 51107,N''无可用非法测试值'',1; SET @out=CONVERT(int,@x);';
   EXEC sys.sp_executesql @sql,N'@out int OUTPUT',@bad OUTPUT;
   BEGIN TRY
    BEGIN TRAN;
    SET @sql=N'UPDATE dbo.'+QUOTENAME(@t)+N' SET '+QUOTENAME(@c)+N'=@bad WHERE '+QUOTENAME(@pk)+N'=@row; IF @@ROWCOUNT<>1 THROW 51107,N''测试行不唯一或已变更'',1;';
    EXEC sys.sp_executesql @sql,N'@bad int,@row int',@bad,@row;
    ROLLBACK;
    INSERT @Results VALUES(@i,@t+N'.'+@c,'FAIL',N'非法外键写入未被拒绝，已回滚');
   END TRY
   BEGIN CATCH
    SELECT @err=ERROR_NUMBER(),@msg=ERROR_MESSAGE();
    IF XACT_STATE()<>0 ROLLBACK;
    INSERT @Results VALUES(@i,@t+N'.'+@c,CASE WHEN @err=547 AND CHARINDEX(@fk,@msg)>0 THEN 'PASS' ELSE 'FAIL' END,@msg);
   END CATCH;
  END;
 END;
 SET @i+=1;
END;
SELECT * FROM @Results ORDER BY id;
-- 派单→护工/班次的反向外键归成员2；本脚本只展示状态，不更改或测试写入其表。
SELECT name,is_disabled,is_not_trusted,delete_referential_action_desc FROM sys.foreign_keys
WHERE parent_object_id=OBJECT_ID(N'dbo.dispatch_record') AND referenced_object_id IN(OBJECT_ID(N'dbo.caregiver'),OBJECT_ID(N'dbo.caregiver_schedule'));
IF EXISTS(SELECT 1 FROM @Results WHERE status='FAIL') THROW 51107,N'真实外键测试失败，参见结果。',1;
-- 全部SKIP不代表成功；无PASS的项目必须继续列为未执行。
