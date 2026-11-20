-- 成员3 v4：只在专用测试库执行；禁止在正式库运行。
SET NOCOUNT ON; SET XACT_ABORT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
IF DB_ID()<=4 THROW 51100,N'请选择专用用户测试库。',1;
IF @@TRANCOUNT<>0 THROW 51100,N'请勿在外层事务内运行。',1;

-- 三阶段：BASE 22护工/24证书/22排班；CHECKIN插入20待审核签到；M2 START后FINALIZE更新原20条工时。
-- 项目下架仅阻止成员2创建新订单，不阻止已存在订单派单/接单/履行；本脚本不创建订单。
-- 默认不写入。仅在确认目标为专用测试库后改为1，并填写实际已存在的业务键。
DECLARE @AllowWrite bit=0, @Stage varchar(8)='BASE';
DECLARE @OrgName nvarchar(100)=N'阳光社区养老服务中心',@OrgAddress nvarchar(200)=N'阳光社区服务街道1号'; -- 真实机构复合唯一业务键
DECLARE @ServiceName nvarchar(50)=NULL,@ServiceType nvarchar(30)=NULL;
DECLARE @Community nvarchar(200)=N'阳光社区';
DECLARE @BaseDate date='20300105'; -- 成员2预约须与下面排班预览一致
IF @Stage NOT IN ('BASE','CHECKIN','FINALIZE') THROW 51100,N'Stage只能为BASE/CHECKIN/FINALIZE。',1;
IF @AllowWrite=0 BEGIN
 SELECT N'BLOCKED：默认不写入，请先确认专用测试库及父表/外键/业务键；详见测试用例清单。' AS status;
 SELECT @Stage AS stage,@OrgName AS required_org_name,@OrgAddress AS required_org_address,@ServiceName AS required_service_name,@ServiceType AS required_service_type;
 RETURN;
END;
-- 不创建任何替代父表。缺少父表/列时在动态SQL编译前停止。
IF OBJECT_ID(N'dbo.service_org',N'U') IS NULL OR (COL_LENGTH(N'dbo.service_org',N'org_name') IS NULL OR COL_LENGTH(N'dbo.service_org',N'org_address') IS NULL OR COL_LENGTH(N'dbo.service_org',N'org_status') IS NULL OR COL_LENGTH(N'dbo.service_org',N'service_area') IS NULL)
 THROW 51101,N'缺少成员1实际service_org或机构名称/地址业务键；须成员1确认，禁止猜测ID。',1;
IF OBJECT_ID(N'dbo.service_item',N'U') IS NULL THROW 51101,N'缺少成员2真实service_item。',1;
IF @OrgName IS NULL OR @OrgAddress IS NULL OR @ServiceName IS NULL OR @ServiceType IS NULL
 THROW 51101,N'请填写成员1/2已存在且确认供测试使用的业务键。',1;
DECLARE @OrgID int,@ServiceID int,@Matches int,@OrgStatus nvarchar(10),@OrgArea nvarchar(200);
EXEC sys.sp_executesql N'SELECT @n=COUNT(*),@id=MIN(org_id),@status=MIN(org_status),@area=MIN(service_area) FROM dbo.service_org WHERE org_name=@name AND org_address=@address;',
 N'@name nvarchar(100),@address nvarchar(200),@n int OUTPUT,@id int OUTPUT,@status nvarchar(10) OUTPUT,@area nvarchar(200) OUTPUT',@OrgName,@OrgAddress,@Matches OUTPUT,@OrgID OUTPUT,@OrgStatus OUTPUT,@OrgArea OUTPUT;
IF @Matches<>1 THROW 51101,N'机构业务键未唯一命中，暂缓写入。',1;
IF @OrgStatus IS NULL OR @OrgStatus NOT IN(N'正常',N'停用')
 THROW 51101,N'机构状态缺失或不符合成员1最终枚举。',1;
IF @OrgStatus<>N'正常' THROW 51101,N'本测试批次仅使用正常机构；停用机构暂缓，历史服务善后须另行确认。',1;
IF @Community IS NULL OR LEN(LTRIM(RTRIM(@Community)))=0
 OR DATALENGTH(@Community)<>DATALENGTH(LTRIM(RTRIM(@Community)))
 OR CHARINDEX(N'-',@Community COLLATE Latin1_General_100_BIN2)>0 OR LEN(@Community)>198
 THROW 51101,N'社区必须为无首尾空格的单个标准名称，不含地址分隔符，且可容纳详细地址。',1;
-- 成员1正式种子包含“康宁社区、安宁社区”；本测试仅按顿号分词精确匹配，不做子串猜测。
IF @OrgArea IS NULL OR NOT EXISTS(SELECT 1 FROM STRING_SPLIT(@OrgArea,N'、')
 WHERE LTRIM(RTRIM(value)) COLLATE Latin1_General_100_BIN2=@Community COLLATE Latin1_General_100_BIN2
 AND DATALENGTH(LTRIM(RTRIM(value)))=DATALENGTH(@Community))
 THROW 51101,N'机构服务区域未精确覆盖测试社区；不支持的范围格式须先向成员1确认。',1;

EXEC sys.sp_executesql N'SELECT @n=COUNT(*),@id=MIN(service_id) FROM dbo.service_item WHERE service_name=@name AND service_type=@type;',
 N'@name nvarchar(50),@type nvarchar(30),@n int OUTPUT,@id int OUTPUT',@ServiceName,@ServiceType,@Matches OUTPUT,@ServiceID OUTPUT;
IF @Matches<>1 THROW 51101,N'服务项目业务键未唯一命中项目，暂缓写入。',1;
-- 两个BASE外部外键必须启用且可信，不能因父表存在就当作参照完整性已落实。
IF (SELECT COUNT(*) FROM sys.foreign_keys WHERE name IN(N'FK_M3_caregiver_org_id',N'FK_M3_caregiver_certificate_service_id') AND is_disabled=0 AND is_not_trusted=0)<>2
 THROW 51101,N'请先部署并核对机构/项目两条真实外键。',1;

-- 同连接分阶段执行时清理本脚本自己的会话临时表。
IF OBJECT_ID(N'tempdb..#F') IS NOT NULL DROP TABLE #F;
IF OBJECT_ID(N'tempdb..#W') IS NOT NULL DROP TABLE #W;
IF OBJECT_ID(N'tempdb..#CG') IS NOT NULL DROP TABLE #CG;
IF OBJECT_ID(N'tempdb..#N') IS NOT NULL DROP TABLE #N;
CREATE TABLE #N(n int PRIMARY KEY);
INSERT #N VALUES(1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12),(13),(14),(15),(16),(17),(18),(19),(20),(21),(22);
CREATE TABLE #CG(n int PRIMARY KEY,caregiver_id int UNIQUE);
BEGIN TRY
 BEGIN TRANSACTION;
 -- 前置查询后可能发生状态/地域变更：在本批写入事务中锁定机构并重新核对，失败整批回滚。
 EXEC sys.sp_executesql N'IF NOT EXISTS(SELECT 1 FROM dbo.service_org WITH(UPDLOCK,HOLDLOCK)
 WHERE org_id=@id AND org_name=@name AND org_address=@address AND org_status=N''正常''
 AND service_area=@area AND DATALENGTH(service_area)=DATALENGTH(@area))
 THROW 51101,N''机构状态或地域已变化，请重新核实参数。'',1;',
 N'@id int,@name nvarchar(100),@address nvarchar(200),@area nvarchar(200)',@OrgID,@OrgName,@OrgAddress,@OrgArea;

 IF @Stage='BASE' BEGIN
  -- 名称和证书前缀只用于本测试批次；重跑拒绝，不覆盖或删除既有数据。
  IF EXISTS(SELECT 1 FROM dbo.caregiver WITH(UPDLOCK,HOLDLOCK) WHERE caregiver_name LIKE N'M3T2030护工%')
   THROW 51102,N'测试批次已经存在；请检查原记录，不重复插入。',1;
  INSERT dbo.caregiver(caregiver_name,org_id,phone,service_area,employment_status)
  SELECT N'M3T2030护工'+RIGHT('00'+CONVERT(varchar(2),n),2),@OrgID,'000000000'+RIGHT('00'+CONVERT(varchar(2),n),2),@Community,
   CASE n WHEN 21 THEN N'停用' WHEN 22 THEN N'离职' ELSE N'在岗' END FROM #N;
 END;
 INSERT #CG SELECT n.n,c.caregiver_id FROM #N n JOIN dbo.caregiver c ON c.caregiver_name=N'M3T2030护工'+RIGHT('00'+CONVERT(varchar(2),n.n),2) AND c.org_id=@OrgID;
 IF (SELECT COUNT(*) FROM #CG)<>22 THROW 51102,N'需先成功生成BASE批次，且护工标记不得重复。',1;
 IF @Stage='BASE' BEGIN
  INSERT dbo.caregiver_certificate(caregiver_id,certificate_no,certificate_type,service_id,qualification_level,valid_from,valid_to,certificate_status)
  SELECT caregiver_id,N'M3T2030-C'+RIGHT('00'+CONVERT(varchar(2),n),2),N'养老护理员职业技能等级证书',@ServiceID,
   CASE n%3 WHEN 0 THEN N'高级' WHEN 1 THEN N'初级' ELSE N'中级' END,
   '20290101',CASE WHEN n>20 THEN CONVERT(date,'20291231') ELSE CONVERT(date,'20311231') END,
   CASE n WHEN 21 THEN N'暂停' WHEN 22 THEN N'吊销' ELSE N'有效' END FROM #CG;
  INSERT dbo.caregiver_certificate(caregiver_id,certificate_no,certificate_type,service_id,qualification_level,valid_from,valid_to,certificate_status)
   SELECT caregiver_id,N'M3T2030-EXTRA-A',N'养老护理培训证书',@ServiceID,N'初级','20290101','20311231',N'有效' FROM #CG WHERE n=1
   UNION ALL SELECT caregiver_id,N'M3T2030-EXTRA-B',N'养老护理培训证书',@ServiceID,N'中级','20280101','20291231',N'暂停' FROM #CG WHERE n=1;
  INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status)
  SELECT caregiver_id,DATEADD(HOUR,8,CONVERT(datetime2(0),DATEADD(DAY,n-1,@BaseDate))),
   DATEADD(HOUR,12,CONVERT(datetime2(0),DATEADD(DAY,n-1,@BaseDate))),2,N'开放' FROM #CG WHERE n<=20;
  -- 同护工相邻班次首尾衔接；取消班次不参与工作记录。均无重叠。
  INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status)
   SELECT caregiver_id,DATEADD(HOUR,12,CONVERT(datetime2(0),@BaseDate)),DATEADD(HOUR,16,CONVERT(datetime2(0),@BaseDate)),1,N'关闭' FROM #CG WHERE n=1
   UNION ALL SELECT caregiver_id,DATEADD(HOUR,16,CONVERT(datetime2(0),@BaseDate)),DATEADD(HOUR,20,CONVERT(datetime2(0),@BaseDate)),1,N'取消' FROM #CG WHERE n=1;
 END ELSE BEGIN
  IF OBJECT_ID(N'dbo.dispatch_record',N'U') IS NULL OR COL_LENGTH(N'dbo.dispatch_record',N'schedule_id') IS NULL OR OBJECT_ID(N'dbo.service_order',N'U') IS NULL
   THROW 51103,N'成员2真实派单/订单及schedule_id尚未就绪，暂缓CHECKIN/FINALIZE。',1;
  IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name=N'FK_M3_work_record_dispatch_id' AND is_disabled=0 AND is_not_trusted=0)
   THROW 51103,N'工时到实际派单的可信外键未建立。',1;
  IF (SELECT COUNT(*) FROM sys.foreign_keys WHERE parent_object_id=OBJECT_ID(N'dbo.dispatch_record') AND referenced_object_id IN(OBJECT_ID(N'dbo.caregiver'),OBJECT_ID(N'dbo.caregiver_schedule')) AND is_disabled=0 AND is_not_trusted=0)<>2
   THROW 51103,N'需成员2先部署派单到护工及班次的两条可信反向外键。',1;
  -- 每名在岗测试护工仅一条由成员2指定供测试使用的已接单派单，避免任取真实业务记录。
  CREATE TABLE #W(n int PRIMARY KEY,dispatch_id int UNIQUE,schedule_id int,t datetime2(0),duration_minutes int,lat decimal(10,7),lon decimal(10,7));
  EXEC sys.sp_executesql N'
   INSERT #W SELECT g.n,d.dispatch_id,d.schedule_id,o.appointment_time,o.duration_minutes,o.service_latitude,o.service_longitude
   FROM #CG g JOIN dbo.caregiver c ON c.caregiver_id=g.caregiver_id
   JOIN dbo.dispatch_record d WITH(UPDLOCK,HOLDLOCK) ON d.caregiver_id=g.caregiver_id
   JOIN dbo.caregiver_schedule s ON s.schedule_id=d.schedule_id AND s.caregiver_id=g.caregiver_id
   JOIN dbo.service_order o ON o.order_id=d.order_id
   WHERE g.n<=20 AND d.dispatch_status=N''已接单'' AND d.remark=N''M3T2030联调专用''
   AND ((@stage=''CHECKIN'' AND o.order_status=N''待服务'') OR (@stage=''FINALIZE'' AND o.order_status=N''服务中'')) AND c.employment_status=N''在岗''
   AND s.schedule_status=N''开放'' AND o.service_id=@sid
   -- 实际护工社区必须等于本批社区，订单地址的首个英文连字符前缀再与实际护工社区精确比较。
   AND c.service_area COLLATE Latin1_General_100_BIN2=@community COLLATE Latin1_General_100_BIN2
   AND DATALENGTH(c.service_area)=DATALENGTH(@community)
   AND CHARINDEX(N''-'',o.service_address COLLATE Latin1_General_100_BIN2)>1
   AND LEFT(o.service_address,CASE WHEN CHARINDEX(N''-'',o.service_address COLLATE Latin1_General_100_BIN2)>0 THEN CHARINDEX(N''-'',o.service_address COLLATE Latin1_General_100_BIN2)-1 ELSE 0 END) COLLATE Latin1_General_100_BIN2=c.service_area COLLATE Latin1_General_100_BIN2
   AND DATALENGTH(LEFT(o.service_address,CASE WHEN CHARINDEX(N''-'',o.service_address COLLATE Latin1_General_100_BIN2)>0 THEN CHARINDEX(N''-'',o.service_address COLLATE Latin1_General_100_BIN2)-1 ELSE 0 END))=DATALENGTH(c.service_area)
   AND LEN(LTRIM(RTRIM(SUBSTRING(o.service_address,CHARINDEX(N''-'',o.service_address COLLATE Latin1_General_100_BIN2)+1,200))))>0
   AND o.duration_minutes BETWEEN 1 AND 240 AND o.appointment_time>=s.start_time AND DATEADD(MINUTE,o.duration_minutes,o.appointment_time)<=s.end_time
   AND o.service_latitude BETWEEN -89 AND 89 AND o.service_longitude BETWEEN -180 AND 180 AND o.allowed_radius_m BETWEEN 1 AND 1000
   AND ((@stage=''CHECKIN'' AND NOT EXISTS(SELECT 1 FROM dbo.work_record w WITH(UPDLOCK,HOLDLOCK) WHERE w.dispatch_id=d.dispatch_id))
    OR (@stage=''FINALIZE'' AND EXISTS(SELECT 1 FROM dbo.work_record w WITH(UPDLOCK,HOLDLOCK) WHERE w.dispatch_id=d.dispatch_id AND w.schedule_id=d.schedule_id AND w.check_in_time=o.appointment_time AND w.check_out_time IS NULL AND w.effective_minutes IS NULL AND w.review_status=N''待审核'' AND w.review_note LIKE N''M3T2030 CHECKIN:%'')))
   AND EXISTS(SELECT 1 FROM dbo.caregiver_certificate cert WHERE cert.caregiver_id=c.caregiver_id AND cert.service_id=o.service_id AND cert.certificate_status=N''有效'' AND CONVERT(date,o.appointment_time) BETWEEN cert.valid_from AND cert.valid_to)
   AND NOT EXISTS(SELECT 1 FROM dbo.dispatch_record dx JOIN dbo.service_order ox ON ox.order_id=dx.order_id WHERE dx.caregiver_id=d.caregiver_id AND dx.dispatch_id<>d.dispatch_id AND dx.dispatch_status IN(N''待接单'',N''已接单'') AND ox.appointment_time<DATEADD(MINUTE,o.duration_minutes,o.appointment_time) AND o.appointment_time<DATEADD(MINUTE,ox.duration_minutes,ox.appointment_time))
   AND (SELECT COUNT(*) FROM dbo.dispatch_record z WHERE z.schedule_id=s.schedule_id AND z.dispatch_status IN(N''待接单'',N''已接单''))<=s.max_orders;',
   N'@sid int,@community nvarchar(200),@stage varchar(8)',@ServiceID,@Community,@Stage;
  IF (SELECT COUNT(*) FROM #W)<>20 THROW 51103,N'需要20名测试护工各一条匹配当前阶段的有效专用派单/原始签到；不足时整体回滚。',1;
  CREATE TABLE #F(schedule_id int,dispatch_id int PRIMARY KEY,check_in_time datetime2(0),check_out_time datetime2(0),check_in_location nvarchar(200),check_out_location nvarchar(200),fence_result nvarchar(10),effective_minutes int,review_status nvarchar(10),review_note nvarchar(255));
  INSERT #F(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status,review_note)
  SELECT schedule_id,dispatch_id,t,CASE WHEN n%6=0 THEN NULL ELSE DATEADD(MINUTE,duration_minutes,t) END,
   CASE WHEN n%6=3 THEN NULL WHEN n%6=4 THEN CONVERT(nvarchar(30),lat+1)+N','+CONVERT(nvarchar(30),lon) ELSE CONVERT(nvarchar(30),lat)+N','+CONVERT(nvarchar(30),lon) END,
   CASE WHEN n%6 IN(0,5) THEN NULL ELSE CONVERT(nvarchar(30),lat)+N','+CONVERT(nvarchar(30),lon) END,
   CASE WHEN n%6=3 THEN N'待校验' WHEN n%6=4 THEN N'未通过' ELSE N'通过' END,
   CASE WHEN n%6 IN(1,5) THEN duration_minutes WHEN n%6=2 THEN duration_minutes/2 ELSE NULL END,
   CASE WHEN n%6 IN(1,2,5) THEN N'通过' WHEN n%6=4 THEN N'驳回' ELSE N'待审核' END,
   CASE n%6 WHEN 3 THEN N'签到位置缺失，等待人工复核' WHEN 4 THEN N'签到位置越界，复核驳回' WHEN 5 THEN N'测试场景：签退定位缺失，已核实服务记录与双方证明，按实际时长认可；保留定位缺失事实' WHEN 0 THEN N'尚未签退，不认定有效工时' ELSE N'测试场景：常规审核' END
  FROM #W;
  IF @Stage='CHECKIN' BEGIN
   -- 仅新增首次签到；签退/有效工时为空，所有审核状态均待审核，不提前认定最终结果。
   INSERT dbo.work_record(schedule_id,dispatch_id,check_in_time,check_out_time,check_in_location,check_out_location,fence_result,effective_minutes,review_status,review_note)
   SELECT schedule_id,dispatch_id,check_in_time,NULL,check_in_location,NULL,fence_result,NULL,N'待审核',
    N'M3T2030 CHECKIN:首次签到，签退和工时待后续阶段；定位状态='+fence_result FROM #F;
   IF @@ROWCOUNT<>20 THROW 51103,N'CHECKIN必须新增20条首次签到。',1;
  END ELSE BEGIN
   -- 禁止更换既有签到时间/位置或将原围栏异常改为通过。
   IF EXISTS(SELECT f.dispatch_id FROM #F f JOIN dbo.work_record w ON w.dispatch_id=f.dispatch_id
    WHERE EXISTS(SELECT w.schedule_id,w.check_in_time,w.check_in_location,w.fence_result
     EXCEPT SELECT f.schedule_id,f.check_in_time,f.check_in_location,f.fence_result))
    THROW 51103,N'原签到/定位/围栏已被更改，停止FINALIZE，需人工核实。',1;
   UPDATE w SET check_out_time=f.check_out_time,check_out_location=f.check_out_location,
    effective_minutes=f.effective_minutes,review_status=f.review_status,
    review_note=N'M3T2030 FINALIZE:'+f.review_note
   FROM dbo.work_record w JOIN #F f ON f.dispatch_id=w.dispatch_id AND f.schedule_id=w.schedule_id
   WHERE w.review_status=N'待审核' AND w.check_out_time IS NULL AND w.effective_minutes IS NULL
    AND w.review_note LIKE N'M3T2030 CHECKIN:%';
   IF @@ROWCOUNT<>20 THROW 51103,N'FINALIZE必须更新原20条签到，禁止重复插入或覆盖已处理记录。',1;
  END;

 END;
 COMMIT;
 SELECT @Stage AS completed_stage;
 SELECT c.caregiver_id,c.caregiver_name,s.schedule_id,s.start_time,s.end_time,s.schedule_status
 FROM dbo.caregiver c JOIN dbo.caregiver_schedule s ON s.caregiver_id=c.caregiver_id WHERE c.caregiver_name LIKE N'M3T2030护工%' ORDER BY c.caregiver_name,s.start_time;

-- 同连接分阶段执行时清理本脚本自己的会话临时表。
IF OBJECT_ID(N'tempdb..#F') IS NOT NULL DROP TABLE #F;
IF OBJECT_ID(N'tempdb..#W') IS NOT NULL DROP TABLE #W;
IF OBJECT_ID(N'tempdb..#CG') IS NOT NULL DROP TABLE #CG;
IF OBJECT_ID(N'tempdb..#N') IS NOT NULL DROP TABLE #N;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK;
-- 同连接分阶段执行时清理本脚本自己的会话临时表。
IF OBJECT_ID(N'tempdb..#F') IS NOT NULL DROP TABLE #F;
IF OBJECT_ID(N'tempdb..#W') IS NOT NULL DROP TABLE #W;
IF OBJECT_ID(N'tempdb..#CG') IS NOT NULL DROP TABLE #CG;
IF OBJECT_ID(N'tempdb..#N') IS NOT NULL DROP TABLE #N;

 THROW;
END CATCH;
