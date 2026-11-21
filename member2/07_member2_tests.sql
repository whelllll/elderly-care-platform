-- 在 SSMS 选定独立 v3 测试库或整合测试库；本脚本不切换数据库。
-- 独立库先执行01、02、06、03、04、05；整合库需部署成员1/3正式表、成员4账号及成员5的01/02/05/06。
-- 整合库可跳过成员2的03：执行8项真实接口测试；独立库保留32项模拟接口测试。
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
IF @@TRANCOUNT <> 0 THROW 51400, N'请在没有未提交事务的窗口运行测试。', 1;

DECLARE @columns TABLE (table_name SYSNAME, expected_count INT);
INSERT @columns VALUES (N'service_item', 9), (N'service_order', 15), (N'dispatch_record', 10);
IF EXISTS (SELECT 1 FROM @columns AS t WHERE t.expected_count <>
           (SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.' + t.table_name, N'U')))
    THROW 51401, N'三张表的列数应为 9、15、10。', 1;

DECLARE @fks TABLE (child_table SYSNAME, child_col SYSNAME, parent_table SYSNAME, parent_col SYSNAME);
INSERT @fks VALUES
    (N'service_order', N'elder_id', N'elder_profile', N'elder_id'),
    (N'service_order', N'service_id', N'service_item', N'service_id'),
    (N'dispatch_record', N'order_id', N'service_order', N'order_id'),
    (N'dispatch_record', N'caregiver_id', N'caregiver', N'caregiver_id'),
    (N'dispatch_record', N'schedule_id', N'caregiver_schedule', N'schedule_id'),
    (N'caregiver_certificate', N'service_id', N'service_item', N'service_id'),
    (N'work_record', N'dispatch_id', N'dispatch_record', N'dispatch_id');
IF EXISTS (
    SELECT 1 FROM @fks AS l
    WHERE NOT EXISTS (
        SELECT 1 FROM sys.foreign_keys AS f JOIN sys.foreign_key_columns AS k ON k.constraint_object_id = f.object_id
        WHERE f.parent_object_id = OBJECT_ID(N'dbo.' + l.child_table)
          AND f.referenced_object_id = OBJECT_ID(N'dbo.' + l.parent_table)
          AND COL_NAME(f.parent_object_id, k.parent_column_id) = l.child_col
          AND COL_NAME(f.referenced_object_id, k.referenced_column_id) = l.parent_col
          AND f.is_disabled = 0 AND f.is_not_trusted = 0 AND f.is_not_for_replication = 0
          AND f.delete_referential_action = 0 AND f.update_referential_action = 0
          AND NOT EXISTS (SELECT 1 FROM sys.foreign_key_columns AS x
                          WHERE x.constraint_object_id = f.object_id AND x.constraint_column_id > 1)
    )
) THROW 51402, N'至少一条成员2相关外键缺失、未启用、未受信任或使用级联。', 1;

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.dispatch_record') AND name = N'UX_M2_dispatch_active_order'
        AND is_unique = 1 AND has_filter = 1 AND is_disabled = 0
) THROW 51403, N'缺少有效派单筛选唯一索引。', 1;

IF OBJECT_ID(N'dbo.usp_M2_CreateOrder', N'P') IS NULL
    OR OBJECT_ID(N'dbo.usp_M2_OrderAction', N'P') IS NULL OR OBJECT_ID(N'dbo.usp_M2_CheckFence', N'P') IS NULL
    OR OBJECT_ID(N'dbo.vw_M2_OrderDetails', N'V') IS NULL
    OR OBJECT_ID(N'dbo.vw_M2_ActiveDispatch', N'V') IS NULL
    OR OBJECT_ID(N'dbo.vw_M2_ServiceSummary', N'V') IS NULL
    THROW 51404, N'缺少视图或存储过程。', 1;

IF EXISTS (SELECT order_id FROM dbo.dispatch_record WHERE dispatch_status IN (N'待接单', N'已接单')
           GROUP BY order_id HAVING COUNT(*) > 1)
    THROW 51405, N'已有订单存在多条有效派单。', 1;

DECLARE @standalone BIT = IIF(EXISTS (SELECT 1 FROM sys.extended_properties
    WHERE class = 0 AND name = N'M2_fixture_v3'), 1, 0);
DECLARE @items INT, @orders INT, @dispatches INT;
SELECT @items = COUNT(*) FROM dbo.service_item WHERE description LIKE N'M2:v1:item:[0-9][0-9]';
SELECT @orders = COUNT(*) FROM dbo.service_order WHERE remark LIKE N'M2:v1:order:[0-9][0-9]';
SELECT @dispatches = COUNT(*) FROM dbo.dispatch_record WHERE remark LIKE N'M2:v1:dispatch:[0-9][0-9]';
-- 正式库允许第一批只初始化项目；出现完整03的订单/派单标识后才要求三类样例齐备。
IF (@standalone = 1 OR @orders + @dispatches > 0)
    AND (@items <> 20 OR @orders <> 20 OR @dispatches <> 20)
    THROW 51406, N'样例标识应分别匹配 20 条服务项目、订单和派单。', 1;

IF OBJECT_ID(N'dbo.usp_M5_LockScope', N'P') IS NULL
    OR OBJECT_ID(N'dbo.vw_M5_CaregiverBlocked', N'V') IS NULL
    OR OBJECT_ID(N'dbo.vw_M5_OrgBlocked', N'V') IS NULL
    THROW 51423, N'成员5最新接口未完整部署，不能通过派单接口验收。', 1;

SELECT @items AS sample_services, @orders AS sample_orders, @dispatches AS sample_dispatches;
SELECT N'PASS 部署验收' AS result,
    (SELECT COUNT_BIG(*) FROM dbo.vw_M2_OrderDetails) AS order_view_rows,
    (SELECT COUNT_BIG(*) FROM dbo.vw_M2_ActiveDispatch) AS dispatch_view_rows,
    (SELECT COUNT_BIG(*) FROM dbo.vw_M2_ServiceSummary) AS summary_view_rows;

IF @standalone = 0
BEGIN
    -- 动态批次隔离正式表字段，避免独立模拟库在编译时引用不存在的列。
    EXEC sys.sp_executesql N'SET NOCOUNT ON;
-- 正式分支只调用已部署接口，不创建、删除或替换任何成员的过程、视图或触发器。
IF COL_LENGTH(N''dbo.caregiver'', N''org_id'') IS NULL
    OR COL_LENGTH(N''dbo.caregiver'', N''phone'') IS NULL
    OR COL_LENGTH(N''dbo.caregiver_certificate'', N''certificate_type'') IS NULL
    OR COL_LENGTH(N''dbo.rectification'', N''submit_time'') IS NULL
    OR OBJECT_ID(N''dbo.usp_M5_CreateRectification'', N''P'') IS NULL
    OR OBJECT_ID(N''dbo.usp_M5_ReviewRectification'', N''P'') IS NULL
    OR NOT EXISTS (SELECT 1 FROM sys.triggers WHERE object_id = OBJECT_ID(N''dbo.TR_M5_Rect_SyncFlag'') AND is_disabled = 0)
    THROW 51440, N''正式整合依赖不完整：需要成员3正式表、成员5创建/复查过程及已启用的整改同步触发器。'', 1;

DECLARE @inspector INT, @reviewer INT, @elder INT, @community NVARCHAR(50);
-- 角色与状态是必要条件；不取任意账号，也不写死user_id。
SELECT TOP (1) @inspector = user_id FROM dbo.sys_user
WHERE role_code = N''CIVIL_SUPERVISOR'' AND user_status = N''正常'' AND lock_until IS NULL AND login_fail_count < 5
ORDER BY CASE WHEN username = N''civil_sup'' THEN 0 ELSE 1 END, user_id;
SELECT TOP (1) @reviewer = user_id FROM dbo.sys_user
WHERE role_code = N''STREET_SUPERVISOR'' AND user_status = N''正常'' AND lock_until IS NULL AND login_fail_count < 5
ORDER BY CASE WHEN username = N''street_sup'' THEN 0 ELSE 1 END, user_id;
IF @inspector IS NULL OR @reviewer IS NULL
    THROW 51440, N''缺少正常可用的民政抽查账号或街道复查账号，请先部署成员4测试账号。'', 1;
SELECT TOP (1) @elder = elder_id, @community = community_name FROM dbo.elder_profile
WHERE archive_status = N''正常'' AND NULLIF(TRIM(community_name), N'''') IS NOT NULL
  AND CHARINDEX(N''-'', community_name) = 0 AND DATALENGTH(community_name) = DATALENGTH(TRIM(community_name))
ORDER BY elder_id;
IF @elder IS NULL THROW 51440, N''缺少可用于测试的正常老人档案及合法社区名称。'', 1;

DECLARE @cases TABLE(case_id INT PRIMARY KEY, test_name NVARCHAR(100), expected_error INT);
INSERT @cases VALUES
 (1,N''正常派单、同护工满班改派及跨护工改派'',0),
 (2,N''T13真实护工级整改限制新派单'',51121),
 (3,N''机构级整改覆盖旗下护工且不影响其他机构'',51121),
 (4,N''机构限制拒绝改派且调用方回滚前原派单未变'',51121),
 (5,N''真实护工整改提交及复查通过后恢复派单'',0),
 (6,N''真实机构整改提交及复查通过后恢复派单'',0),
 (7,N''机构受限后已有派单仍可接单开始及完成'',0),
 (8,N''护工限制拒绝改派且调用方回滚前原派单未变'',51121);
DECLARE @results TABLE(case_id INT, test_name NVARCHAR(100), result VARCHAR(4));
DECLARE @case INT = 1, @expected INT, @caught INT, @message NVARCHAR(2048), @stage NVARCHAR(40),
 @tag NVARCHAR(40), @orgA INT, @orgB INT, @cgA INT, @cgA2 INT, @cgB INT,
 @service INT, @order INT, @dispatch INT, @old INT, @schedule INT, @target INT,
 @inspection INT, @rectify INT, @flag CHAR(1), @start DATETIME2(0), @finish DATETIME2(0),
 @address NVARCHAR(200), @scope NVARCHAR(4), @inspection_type NVARCHAR(6),
 @inspection_cg INT, @inspection_order INT, @before_status NVARCHAR(20), @before_count INT,
 @rejection_unchanged BIT, @fixture_rows INT;

WHILE @case <= 8
BEGIN
 SELECT @expected = expected_error FROM @cases WHERE case_id = @case;
 SELECT @caught = 0, @message = NULL, @stage = N''准备'', @dispatch = NULL, @old = NULL,
        @rejection_unchanged = 0, @flag = NULL,
        @tag = N''M2I:'' + REPLACE(CONVERT(NVARCHAR(36), NEWID()), N''-'', N''''),
        @start = DATEADD(DAY, 3, SYSDATETIME());
 SET @finish = DATEADD(MINUTE, 30, @start);
 SET @address = @community + N''-M2正式整合测试'';
 BEGIN TRY
  BEGIN TRAN;
  INSERT dbo.service_org(org_name,contact_person,contact_phone,org_address,service_area,org_status,remark)
  VALUES(@tag+N''A'',N''整合测试'',''13800000001'',@tag+N''A地址'',@community,N''正常'',@tag);
  SET @orgA = CONVERT(INT,SCOPE_IDENTITY());
  INSERT dbo.service_org(org_name,contact_person,contact_phone,org_address,service_area,org_status,remark)
  VALUES(@tag+N''B'',N''整合测试'',''13800000002'',@tag+N''B地址'',@community,N''正常'',@tag);
  SET @orgB = CONVERT(INT,SCOPE_IDENTITY());
  INSERT dbo.caregiver(caregiver_name,org_id,phone,service_area,employment_status)
  VALUES(@tag+N''A1'',@orgA,''13800000003'',@community,N''在岗'');
  SET @cgA = CONVERT(INT,SCOPE_IDENTITY());
  INSERT dbo.caregiver(caregiver_name,org_id,phone,service_area,employment_status)
  VALUES(@tag+N''A2'',@orgA,''13800000004'',@community,N''在岗'');
  SET @cgA2 = CONVERT(INT,SCOPE_IDENTITY());
  INSERT dbo.caregiver(caregiver_name,org_id,phone,service_area,employment_status)
  VALUES(@tag+N''B1'',@orgB,''13800000005'',@community,N''在岗'');
  SET @cgB = CONVERT(INT,SCOPE_IDENTITY());
  INSERT dbo.service_item(service_name,service_type,price,duration,description,status,charge_unit,is_subsidizable)
  VALUES(@tag,N''家政'',80,30,@tag,N''上架'',N''次'',1);
  SET @service = CONVERT(INT,SCOPE_IDENTITY());
  INSERT dbo.caregiver_certificate(caregiver_id,certificate_no,certificate_type,service_id,qualification_level,valid_from,valid_to,certificate_status)
  VALUES(@cgA,@tag+N''A1'',N''养老护理员'',@service,N''初级'',CONVERT(DATE,@start),CONVERT(DATE,@start),N''有效''),
        (@cgA2,@tag+N''A2'',N''养老护理员'',@service,N''初级'',CONVERT(DATE,@start),CONVERT(DATE,@start),N''有效''),
        (@cgB,@tag+N''B1'',N''养老护理员'',@service,N''初级'',CONVERT(DATE,@start),CONVERT(DATE,@start),N''有效'');
  INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status)
  VALUES(@cgA,@start,DATEADD(HOUR,8,@start),1,N''开放'');
  SET @schedule = CONVERT(INT,SCOPE_IDENTITY());
  INSERT dbo.caregiver_schedule(caregiver_id,start_time,end_time,max_orders,schedule_status)
  VALUES(@cgA2,@start,DATEADD(HOUR,8,@start),2,N''开放''),(@cgB,@start,DATEADD(HOUR,8,@start),2,N''开放'');
  EXEC dbo.usp_M2_CreateOrder @elder,@service,@start,@address,@order OUTPUT,
       @Latitude=39.99,@Longitude=116.33,@RadiusM=100;
  IF @case IN (1,4,7,8)
  BEGIN
   EXEC dbo.usp_M2_OrderAction @order,''DISPATCH'',@cgA,@dispatch OUTPUT;
   SET @old = @dispatch;
  END;
  SELECT @before_status=order_status FROM dbo.service_order WHERE order_id=@order;
  SELECT @before_count=COUNT(*) FROM dbo.dispatch_record WHERE order_id=@order;

  IF @case <> 1
  BEGIN
   SET @scope=IIF(@case IN (2,5,8),N''护工'',N''机构'');
   SET @target=IIF(@case IN (4,8),@cgA2,@cgA);
   SET @inspection_type=IIF(@scope=N''护工'',N''护工'',N''订单'');
   SET @inspection_cg=IIF(@scope=N''护工'',@target,NULL);
   SET @inspection_order=IIF(@scope=N''机构'',@order,NULL);
   INSERT dbo.quality_inspection(object_type,order_id,caregiver_id,inspect_method,inspect_source,inspect_time,
          inspector_id,inspector_org,inspect_result,rectify_flag,rectify_deadline,inspect_status,remark)
   VALUES(@inspection_type,@inspection_order,@inspection_cg,N''系统稽核'',N''专项整治'',SYSDATETIME(),
          @inspector,N''M2正式整合测试'',N''不合格'',''Y'',DATEADD(DAY,7,CONVERT(DATE,SYSDATETIME())),N''已完成'',@tag);
   SET @inspection=CONVERT(INT,SCOPE_IDENTITY());
   EXEC dbo.usp_M5_CreateRectification @inspection_id=@inspection,@caregiver_id=@inspection_cg,@org_id=@orgA,
        @problem_desc=N''M2真实接口整合测试'',@rectify_id=@rectify OUTPUT;
   IF NOT EXISTS(SELECT 1 FROM dbo.rectification WHERE rectify_id=@rectify AND restrict_flag=''Y'')
      THROW 51441,N''正式整改创建后未开启限制。'',1;
   IF @scope=N''机构'' AND
      ((SELECT COUNT(*) FROM dbo.vw_M5_CaregiverBlocked WHERE caregiver_id IN (@cgA,@cgA2))<>2
       OR NOT EXISTS(SELECT 1 FROM dbo.vw_M5_OrgBlocked WHERE org_id=@orgA))
      THROW 51441,N''机构级限制未同时覆盖机构及旗下全部测试护工；请核对成员5视图部署。'',1;
   IF @scope=N''护工'' AND
      (NOT EXISTS(SELECT 1 FROM dbo.vw_M5_CaregiverBlocked WHERE caregiver_id=@target)
       OR EXISTS(SELECT 1 FROM dbo.vw_M5_OrgBlocked WHERE org_id=@orgA))
      THROW 51441,N''护工级限制未生效或错误扩展为机构级限制。'',1;
   IF EXISTS(SELECT 1 FROM dbo.vw_M5_CaregiverBlocked WHERE caregiver_id=@cgB)
      THROW 51441,N''整改错误影响了其他机构的护工。'',1;
  END;

  IF @case IN (5,6)
  BEGIN
   -- 当前成员5没有提交过程，按正式表约束显式提交；绝不手动设置restrict_flag。
   UPDATE dbo.rectification SET submit_time=SYSDATETIME(),rectify_status=N''待复查''
   WHERE rectify_id=@rectify;
   EXEC dbo.usp_M5_ReviewRectification @rectify_id=@rectify,@reviewer_id=@reviewer,@review_result=N''通过'',
        @remark=N''M2测试：已提交整改后复查'',@restrict_flag=@flag OUTPUT;
   IF @flag IS NULL OR @flag<>''N''
      OR NOT EXISTS(SELECT 1 FROM dbo.rectification WHERE rectify_id=@rectify AND release_time IS NOT NULL)
      OR EXISTS(SELECT 1 FROM dbo.vw_M5_CaregiverBlocked WHERE caregiver_id IN (@cgA,@cgA2))
      OR EXISTS(SELECT 1 FROM dbo.vw_M5_OrgBlocked WHERE org_id=@orgA)
      THROW 51442,N''真实复查通过后限制未正确解除。'',1;
  END;

  SET @stage=N''业务操作'';
  IF @case IN (2,3,4,8)
  BEGIN
   IF @case IN (4,8)
    EXEC dbo.usp_M2_OrderAction @order,''REASSIGN'',@cgA2,@dispatch OUTPUT,@Reason=N''整合测试受限改派'';
   ELSE
    EXEC dbo.usp_M2_OrderAction @order,''DISPATCH'',@cgA,@dispatch OUTPUT;
  END
  ELSE IF @case=1
  BEGIN
   EXEC dbo.usp_M2_OrderAction @order,''REASSIGN'',@cgA,@dispatch OUTPUT,@Reason=N''整合测试同护工满班改派'';
   IF @dispatch IS NULL OR @dispatch=@old
      OR NOT EXISTS(SELECT 1 FROM dbo.dispatch_record WHERE dispatch_id=@old AND dispatch_status=N''已撤回'')
      OR (SELECT COUNT(*) FROM dbo.dispatch_record WHERE schedule_id=@schedule AND dispatch_status IN(N''待接单'',N''已接单''))<>1
      THROW 51443,N''真实同护工同班次改派未正确替换旧派单。'',1;
   SET @old=@dispatch;
   EXEC dbo.usp_M2_OrderAction @order,''REASSIGN'',@cgA2,@dispatch OUTPUT,@Reason=N''整合测试跨护工改派'';
   IF NOT EXISTS(SELECT 1 FROM dbo.dispatch_record WHERE dispatch_id=@old AND dispatch_status=N''已撤回'')
      OR NOT EXISTS(SELECT 1 FROM dbo.dispatch_record WHERE dispatch_id=@dispatch AND caregiver_id=@cgA2 AND dispatch_status=N''待接单'')
      THROW 51443,N''真实跨护工改派失败。'',1;
  END
  ELSE IF @case=7
  BEGIN
   EXEC dbo.usp_M2_OrderAction @order,''ACCEPT'',@DispatchID=@dispatch OUTPUT;
   INSERT dbo.work_record(schedule_id,dispatch_id,check_in_time,check_in_location,fence_result,review_status)
   VALUES(@schedule,@dispatch,@start,N''39.99,116.33'',N''通过'',N''待审核'');
   EXEC dbo.usp_M2_OrderAction @order,''START'',@DispatchID=@dispatch OUTPUT;
   UPDATE dbo.work_record SET check_out_time=@finish,check_out_location=N''39.99,116.33'',
          effective_minutes=30,review_status=N''通过'' WHERE dispatch_id=@dispatch;
   EXEC dbo.usp_M2_OrderAction @order,''COMPLETE'',@DispatchID=@dispatch OUTPUT,
        @Confirmed=1,@ServiceRecord=N''M2正式整合测试完成服务'';
   IF NOT EXISTS(SELECT 1 FROM dbo.service_order WHERE order_id=@order AND order_status=N''已完成'' AND confirm_status=N''已确认'')
      OR NOT EXISTS(SELECT 1 FROM dbo.vw_M5_OrgBlocked WHERE org_id=@orgA)
      THROW 51444,N''整改限制阻断了在途订单或被错误解除。'',1;
  END
  ELSE
   EXEC dbo.usp_M2_OrderAction @order,''DISPATCH'',@cgA,@dispatch OUTPUT;

  IF @expected=0 AND (@dispatch IS NULL OR NOT EXISTS(SELECT 1 FROM dbo.dispatch_record WHERE dispatch_id=@dispatch AND order_id=@order))
     THROW 51443,N''成功业务操作没有生成或保留有效派单。'',1;
  IF @@TRANCOUNT<>1 OR XACT_STATE()<>1 THROW 51445,N''正式接口擅自改变测试外层事务。'',1;
  ROLLBACK;
 END TRY
 BEGIN CATCH
  SELECT @caught=ERROR_NUMBER(),@message=ERROR_MESSAGE();
  IF @expected=51121 AND @caught=51121 AND @stage=N''业务操作'' AND @@TRANCOUNT=1
     AND EXISTS(SELECT 1 FROM dbo.service_order WHERE order_id=@order AND order_status=@before_status)
     AND (SELECT COUNT(*) FROM dbo.dispatch_record WHERE order_id=@order)=@before_count
     AND (@old IS NULL OR EXISTS(SELECT 1 FROM dbo.dispatch_record WHERE dispatch_id=@old AND dispatch_status=N''待接单''))
     SET @rejection_unchanged=1;
  IF XACT_STATE()<>0 ROLLBACK;
 END CATCH;
 IF @caught<>@expected OR (@expected=51121 AND @rejection_unchanged<>1)
 BEGIN
  SELECT N''真实接口整合'' AS test_scope,case_id,test_name,result FROM @results ORDER BY case_id;
  SELECT N''真实接口整合'' AS test_scope,case_id,test_name,N''FAIL'' AS result,@stage AS failure_stage,
         @caught AS actual_error,@message AS detail FROM @cases WHERE case_id=@case;
  SET @message=CONCAT(N''真实整合用例 '',@case,N'' 失败；阶段：'',@stage,N''；错误号：'',@caught,N''；'',@message);
  THROW 51446,@message,1;
 END;
 -- 预期失败与成功用例都必须由调用方回滚，不删除用户已有数据。
 SELECT @fixture_rows=COUNT(*) FROM dbo.service_org WHERE org_id IN(@orgA,@orgB);
 IF @fixture_rows<>0 OR EXISTS(SELECT 1 FROM dbo.service_item WHERE service_id=@service)
    OR EXISTS(SELECT 1 FROM dbo.caregiver WHERE caregiver_id IN(@cgA,@cgA2,@cgB))
    OR EXISTS(SELECT 1 FROM dbo.service_order WHERE order_id=@order)
    THROW 51447,N''正式整合测试回滚后仍存在本用例夹具。'',1;
 INSERT @results SELECT case_id,test_name,''PASS'' FROM @cases WHERE case_id=@case;
 SET @case+=1;
END;
SELECT N''真实接口整合'' AS test_scope,case_id,test_name,result FROM @results ORDER BY case_id;
PRINT N''PASS 8项真实接口整合测试。测试夹具已回滚；IDENTITY编号可能出现空号。'';';
    RETURN; -- 正式整合用例完成后退出，不执行下面的独立故障注入。
END;


IF NOT EXISTS (SELECT 1 FROM sys.extended_properties WHERE class = 0 AND name = N'M2_fixture_m5_contract')
    THROW 51424, N'请使用包含最新成员5模拟接口的新独立测试库。', 1;

DECLARE @tests TABLE (case_id INT PRIMARY KEY, name NVARCHAR(80), expected_error INT);
INSERT @tests VALUES
    (1,N'快照、改派、围栏、接单至完成、班次首尾相邻',0),
    (2,N'社区精确匹配',51110),
    (3,N'证书有效期',51111),
    (4,N'有效派单服务区间冲突',51113),
    (5,N'已完成服务仍占用班次累计容量',51114),
    (6,N'部分填写围栏字段',547),
    (7,N'老人跨模块外键',547),
    (8,N'直接插入第二条有效派单',2601),
    (9,N'改派失败恢复原派单',51110),
    (10,N'未签到禁止开始服务',51117),
    (11,N'预约必须完整落在开放班次',51112),
    (12,N'撤派和取消不得用于服务中订单',51107),
    (13,N'整改限制接单',51121),
    (14,N'未确认不得完成订单',51122),
    (15,N'再次派单必须填写改派原因',51119),
    (16,N'订单地址必须属于老人所在社区',51118),
    (17,N'缺少服务记录不得完成订单',51123),
    (18,N'机构级限制禁止派单',51121),
    (19,N'护工复查通过后恢复派单',0),
    (20,N'限制不阻断在途订单且解除后恢复新单',0),
    (21,N'缺少共同加锁入口拒绝派单',51120),
    (22,N'缺少机构限制视图拒绝派单',51120),
    (23,N'缺少护工限制视图拒绝派单',51120),
    (24,N'共同加锁失败拒绝派单',51124),
    (25,N'机构受限改派失败恢复原派单',51121),
    (26,N'同护工同班次满容量改派排除原派单',0),
    (27,N'同护工改派仍检查其他订单冲突',51113),
    (28,N'同班次改派仍统计其他派单容量',51114),
    (29,N'插入失败后外层事务保留并由调用方回滚',51431),
    (30,N'成功改派不提交外层事务且调用方可回滚',0);

DECLARE @results TABLE (case_id INT, test_name NVARCHAR(80), result VARCHAR(4));
DECLARE @case_id INT = 1, @caught INT, @message NVARCHAR(2048),
        @elder_id INT, @service_id INT, @caregiver_id INT, @alternate_id INT,
        @schedule_id INT, @alternate_schedule INT, @order_id INT, @second_order INT,
        @dispatch_id INT, @second_dispatch INT, @old_dispatch INT, @persistent_order INT,
        @start DATETIME2(0), @adjacent DATETIME2(0), @shift_end DATETIME2(0),
        @from DATE, @to DATE, @fence NVARCHAR(10), @distance FLOAT, @minutes INT,
        @capacity INT, @region NVARCHAR(200), @day_difference INT, @absent_elder INT = -2147483648;

SELECT @elder_id = elder_id FROM dbo.elder_profile WHERE elder_name = N'M2测试老人';
SELECT @service_id = service_id FROM dbo.service_item WHERE description = N'M2:v1:item:01';
SELECT @minutes = duration FROM dbo.service_item WHERE service_id = @service_id;
SELECT @persistent_order = order_id FROM dbo.service_order WHERE remark = N'M2:v1:order:19';
SELECT @old_dispatch = dispatch_id FROM dbo.dispatch_record
WHERE order_id = @persistent_order AND dispatch_status = N'待接单';

WHILE @case_id <= 30
BEGIN
    SET @caught = 0;
    SET @dispatch_id = NULL;
    SET @second_dispatch = NULL;
    SET @message = NULL;
    SET @start = DATEADD(DAY, 2, SYSDATETIME());
    SET @adjacent = DATEADD(MINUTE, @minutes, @start);
    SET @shift_end = DATEADD(HOUR, 8, @start);
    SET @from = CONVERT(DATE, @start);
    SET @to = @from;
    SET @day_difference = IIF(@case_id = 3, -1, 1);
    SET @to = DATEADD(DAY, @day_difference, @to);
    SET @from = DATEADD(DAY, -1, @from);
    SET @capacity = CASE WHEN @case_id IN (5, 26) THEN 1 WHEN @case_id = 28 THEN 2 ELSE 4 END;
    SET @region = IIF(@case_id = 2, N'清华园社区 ', N'清华园社区');

    BEGIN TRY
        BEGIN TRAN;
        INSERT dbo.caregiver (caregiver_name, service_area, employment_status)
            VALUES (N'M2过程测试护工', @region, N'在岗');
        SET @caregiver_id = CONVERT(INT, SCOPE_IDENTITY());
        INSERT dbo.caregiver (caregiver_name, service_area, employment_status)
            VALUES (N'M2过程测试改派护工', IIF(@case_id = 9, N'另一社区', N'清华园社区'), N'在岗');
        SET @alternate_id = CONVERT(INT, SCOPE_IDENTITY());
        INSERT dbo.caregiver_certificate
            (caregiver_id, certificate_no, service_id, qualification_level, valid_from, valid_to, certificate_status)
        VALUES (@caregiver_id, N'M2-ASSERT-A', @service_id, N'测试', @from, @to, N'有效'),
               (@alternate_id, N'M2-ASSERT-B', @service_id, N'测试', @from, @to, N'有效');
        INSERT dbo.caregiver_schedule (caregiver_id, start_time, end_time, max_orders, schedule_status)
        VALUES (@caregiver_id, @start, @shift_end, @capacity, IIF(@case_id = 11, N'关闭', N'开放'));
        SET @schedule_id = CONVERT(INT, SCOPE_IDENTITY());
        INSERT dbo.caregiver_schedule (caregiver_id, start_time, end_time, max_orders, schedule_status)
        VALUES (@alternate_id, @start, @shift_end, @capacity, N'开放');
        SET @alternate_schedule = CONVERT(INT, SCOPE_IDENTITY());
        -- 只在带版本标记的独立库向模拟接口注入数据，不依赖 sys_user/抽查数据。
        IF @case_id IN (13, 18, 19, 25)
        BEGIN
            INSERT dbo.rectification (caregiver_id, org_id, rectify_scope, rectify_status, restrict_flag)
            VALUES (IIF(@case_id IN (13, 19), @caregiver_id, NULL), 1,
                    IIF(@case_id IN (13, 19), N'护工', N'机构'), N'待整改', 'Y');
            IF @case_id = 19
                UPDATE dbo.rectification SET rectify_status = N'复查通过', restrict_flag = 'N'
                WHERE caregiver_id = @caregiver_id;
        END;
        -- DDL 故障注入也处于本用例事务内，统一回滚恢复接口。
        IF @case_id = 21 EXEC(N'DROP PROCEDURE dbo.usp_M5_LockScope;');
        IF @case_id = 22 EXEC(N'DROP VIEW dbo.vw_M5_OrgBlocked;');
        IF @case_id = 23 EXEC(N'DROP VIEW dbo.vw_M5_CaregiverBlocked;');
        IF @case_id = 24
            EXEC(N'ALTER PROCEDURE dbo.usp_M5_LockScope
                @org_id INT, @caregiver_id INT = NULL, @locked BIT OUTPUT, @reason NVARCHAR(100) OUTPUT
                AS BEGIN SET @locked = 0; SET @reason = N''模拟归属变化或加锁失败。''; END;');
        IF @case_id = 25
        BEGIN
            -- 执行顺序检查：若限制判断前尝试任何订单/派单写入，立即报51430，
            -- 不能靠最终回滚掩盖“先写后检查”。与循环后的最终状态检查分别验证。
            EXEC(N'CREATE TRIGGER dbo.TR_M2_Test_NoDispatchWrite ON dbo.dispatch_record AFTER INSERT, UPDATE
                AS BEGIN SET NOCOUNT ON; THROW 51430, N''限制拒绝前发生派单写入。'', 1; END;');
            EXEC(N'CREATE TRIGGER dbo.TR_M2_Test_NoOrderWrite ON dbo.service_order AFTER INSERT, UPDATE
                AS BEGIN SET NOCOUNT ON; THROW 51430, N''限制拒绝前发生订单写入。'', 1; END;');
        END;
        IF @case_id = 29
            EXEC(N'CREATE TRIGGER dbo.TR_M2_Test_InsertFailure ON dbo.dispatch_record AFTER INSERT AS
                BEGIN
                    SET NOCOUNT ON;
                    IF EXISTS (SELECT 1 FROM inserted WHERE reassign_reason = N''M2:insert-failure'')
                    BEGIN
                        IF NOT EXISTS (SELECT 1 FROM dbo.dispatch_record AS d JOIN inserted AS i ON i.order_id = d.order_id
                                       WHERE d.dispatch_status = N''已撤回'')
                            THROW 51432, N''故障注入未到达撤回旧派单之后。'', 1;
                        THROW 51431, N''模拟后续插入失败。'', 1;
                    END;
                END;');
        IF @case_id = 6
        BEGIN
            EXEC dbo.usp_M2_CreateOrder @elder_id, @service_id, @start, N'清华园社区-测试',
                @order_id OUTPUT, @Latitude = 39.99;
        END
        ELSE IF @case_id = 7
        BEGIN
            IF EXISTS (SELECT 1 FROM dbo.elder_profile WHERE elder_id = @absent_elder)
                THROW 51407, N'测试哨兵 ID 已存在，无法验证外键拒绝。', 1;
            EXEC dbo.usp_M2_CreateOrder @absent_elder, @service_id, @start, N'清华园社区-测试', @order_id OUTPUT;
        END
        ELSE IF @case_id IN (9, 25, 29, 30)
        BEGIN
            IF @old_dispatch IS NULL THROW 51408, N'缺少改派失败用例的原始待接单样例。', 1;
            SET @dispatch_id = @old_dispatch;
            DECLARE @reassign_target INT, @reassign_reason NVARCHAR(255);
            SET @reassign_target = @alternate_id;
            SET @reassign_reason = N'测试改派';
            IF @case_id IN (29, 30)
                SELECT @reassign_target = caregiver_id FROM dbo.dispatch_record WHERE dispatch_id = @old_dispatch;
            IF @case_id = 29 SET @reassign_reason = N'M2:insert-failure';
            EXEC dbo.usp_M2_OrderAction @persistent_order, 'REASSIGN', @reassign_target, @dispatch_id OUTPUT, @Reason = @reassign_reason;
            IF @case_id = 30 AND (@@TRANCOUNT <> 1 OR XACT_STATE() <> 1 OR @dispatch_id IS NULL OR @dispatch_id = @old_dispatch)
                THROW 51433, N'成功改派提交了外层事务或未生成新派单。', 1;
        END
        ELSE IF @case_id = 16
            EXEC dbo.usp_M2_CreateOrder @elder_id, @service_id, @start, N'其他社区-测试', @order_id OUTPUT;
        ELSE
        BEGIN
            EXEC dbo.usp_M2_CreateOrder @elder_id, @service_id, @start, N'清华园社区-测试',
                @order_id OUTPUT, @Latitude = 39.99, @Longitude = 116.33, @RadiusM = 100;
            EXEC dbo.usp_M2_OrderAction @order_id, 'DISPATCH', @caregiver_id, @dispatch_id OUTPUT;

            IF @case_id IN (26, 27, 28)
            BEGIN
                IF @case_id IN (27, 28)
                BEGIN
                    DECLARE @other_start DATETIME2(0);
                    SET @other_start = IIF(@case_id = 27, @start, @adjacent);
                    EXEC dbo.usp_M2_CreateOrder @elder_id, @service_id, @other_start, N'清华园社区-其他订单', @second_order OUTPUT;
                    IF @case_id = 27
                        -- 特意构造另一条重叠有效派单，验证不能误排除其他订单。
                        INSERT dbo.dispatch_record(order_id, caregiver_id, schedule_id)
                        VALUES (@second_order, @caregiver_id, @schedule_id);
                    ELSE
                    BEGIN
                        EXEC dbo.usp_M2_OrderAction @second_order, 'DISPATCH', @caregiver_id, @second_dispatch OUTPUT;
                        UPDATE dbo.caregiver_schedule SET max_orders = 1 WHERE schedule_id = @schedule_id;
                    END;
                END;
                SET @second_dispatch = @dispatch_id;
                EXEC dbo.usp_M2_OrderAction @order_id, 'REASSIGN', @caregiver_id, @dispatch_id OUTPUT, @Reason = N'同护工同班次改派';
                IF @case_id = 26 AND
                    (@dispatch_id IS NULL OR @dispatch_id = @second_dispatch
                     OR NOT EXISTS (SELECT 1 FROM dbo.dispatch_record WHERE dispatch_id = @second_dispatch AND dispatch_status = N'已撤回')
                     OR NOT EXISTS (SELECT 1 FROM dbo.dispatch_record WHERE dispatch_id = @dispatch_id
                                    AND caregiver_id = @caregiver_id AND schedule_id = @schedule_id AND dispatch_status = N'待接单')
                     OR (SELECT COUNT(*) FROM dbo.dispatch_record WHERE schedule_id = @schedule_id AND dispatch_status IN (N'待接单', N'已接单')) <> 1)
                    THROW 51434, N'同护工同班次改派未正确替换原派单。', 1;
            END;

            IF @case_id = 20
                INSERT dbo.rectification (org_id, rectify_scope, rectify_status, restrict_flag)
                VALUES (1, N'机构', N'待整改', 'Y');

            IF @case_id = 8
                INSERT dbo.dispatch_record (order_id, caregiver_id, schedule_id) VALUES (@order_id, @caregiver_id, @schedule_id);

            IF @case_id = 15
                EXEC dbo.usp_M2_OrderAction @order_id, 'REASSIGN', @alternate_id, @dispatch_id OUTPUT;

            IF @case_id = 1
            BEGIN
                UPDATE dbo.service_item SET duration = @minutes + 1, price = price + 1 WHERE service_id = @service_id;
                IF NOT EXISTS (
                    SELECT 1 FROM dbo.service_order AS o JOIN dbo.service_item AS s ON s.service_id = o.service_id
                    WHERE o.order_id = @order_id AND o.duration_minutes = @minutes AND o.total_amount = s.price - 1
                ) THROW 51409, N'项目变更后订单快照不正确。', 1;
                UPDATE dbo.service_item SET duration = @minutes, price = price - 1 WHERE service_id = @service_id;
                SET @second_dispatch = @dispatch_id;
                EXEC dbo.usp_M2_OrderAction @order_id, 'REASSIGN', @alternate_id, @dispatch_id OUTPUT, @Reason = N'护工调班';
                IF @second_dispatch = @dispatch_id OR NOT EXISTS (
                    SELECT 1 FROM dbo.dispatch_record WHERE dispatch_id = @second_dispatch AND dispatch_status = N'已撤回'
                ) THROW 51410, N'改派没有保留已撤回的旧派单。', 1;
                SET @second_dispatch = NULL;
                SET @schedule_id = @alternate_schedule;
                SET @caregiver_id = @alternate_id;

                EXEC dbo.usp_M2_CheckFence @order_id, N'39.9900000,116.3300000', @fence OUTPUT, @distance OUTPUT;
                IF @fence <> N'通过' OR @distance IS NULL OR @distance <> 0
                    THROW 51411, N'围栏同点测试失败。', 1;
                EXEC dbo.usp_M2_CheckFence @order_id, N'40.9900000,116.3300000', @fence OUTPUT, @distance OUTPUT;
                IF @fence <> N'未通过' OR @distance IS NULL OR @distance <= 100
                    THROW 51412, N'围栏超半径测试失败。', 1;
                EXEC dbo.usp_M2_CheckFence @order_id, N'39.9900000，116.3300000', @fence OUTPUT, @distance OUTPUT;
                IF @fence <> N'待校验' OR @distance IS NOT NULL
                    THROW 51413, N'非法分隔符必须转人工校验。', 1;
                EXEC dbo.usp_M2_CheckFence @order_id, N'91,116.33', @fence OUTPUT, @distance OUTPUT;
                IF @fence <> N'待校验' OR @distance IS NOT NULL
                    THROW 51413, N'越界坐标必须转人工校验。', 1;
            END;

            IF @case_id IN (1, 5, 10, 12, 14, 17, 20)
            BEGIN
                EXEC dbo.usp_M2_OrderAction @order_id, 'ACCEPT', @DispatchID = @dispatch_id OUTPUT;
                IF @case_id <> 10
                    INSERT dbo.work_record
                        (schedule_id, dispatch_id, check_in_time, check_in_location, fence_result, review_status)
                    VALUES (@schedule_id, @dispatch_id, @start, N'39.99,116.33', N'通过', N'待审核');
                EXEC dbo.usp_M2_OrderAction @order_id, 'START', @DispatchID = @dispatch_id OUTPUT;
                IF @case_id = 12
                    EXEC dbo.usp_M2_OrderAction @order_id, 'CANCEL', @DispatchID = @dispatch_id OUTPUT;
                UPDATE dbo.work_record
                SET check_out_time = @adjacent, check_out_location = N'39.99,116.33',
                    effective_minutes = @minutes, review_status = N'通过'
                WHERE dispatch_id = @dispatch_id;
                IF @case_id = 14
                    EXEC dbo.usp_M2_OrderAction @order_id, 'COMPLETE', @DispatchID = @dispatch_id OUTPUT, @ServiceRecord = N'完成上门服务';
                ELSE IF @case_id = 17
                    EXEC dbo.usp_M2_OrderAction @order_id, 'COMPLETE', @DispatchID = @dispatch_id OUTPUT, @Confirmed = 1;
                ELSE
                    EXEC dbo.usp_M2_OrderAction @order_id, 'COMPLETE', @DispatchID = @dispatch_id OUTPUT, @Confirmed = 1, @ServiceRecord = N'完成上门服务';
                IF NOT EXISTS (SELECT 1 FROM dbo.service_order WHERE order_id = @order_id AND order_status = N'已完成' AND confirm_status = N'已确认')
                    THROW 51414, N'完成服务后的订单状态错误。', 1;
            END;

            IF @case_id = 20
                UPDATE dbo.rectification SET rectify_status = N'复查通过', restrict_flag = 'N'
                WHERE org_id = 1 AND rectify_scope = N'机构';
            IF @case_id IN (1, 4, 5, 20)
            BEGIN
                IF @case_id = 4 SET @adjacent = DATEADD(MINUTE, 1, @start);
                EXEC dbo.usp_M2_CreateOrder @elder_id, @service_id, @adjacent, N'清华园社区-相邻时段', @second_order OUTPUT;
                EXEC dbo.usp_M2_OrderAction @second_order, 'DISPATCH', @caregiver_id, @second_dispatch OUTPUT;
            END;
            IF @case_id = 1
            BEGIN
                EXEC dbo.usp_M2_OrderAction @second_order, 'REJECT', @DispatchID = @second_dispatch OUTPUT;
                IF NOT EXISTS (SELECT 1 FROM dbo.service_order WHERE order_id = @second_order AND order_status = N'待派单')
                    THROW 51415, N'拒单后订单未回到待派单。', 1;
                EXEC dbo.usp_M2_OrderAction @second_order, 'DISPATCH', @caregiver_id, @second_dispatch OUTPUT, @Reason = N'拒单后重新派单';
                EXEC dbo.usp_M2_OrderAction @second_order, 'CANCEL', @DispatchID = @second_dispatch OUTPUT;
                IF NOT EXISTS (
                    SELECT 1 FROM dbo.service_order AS o JOIN dbo.dispatch_record AS d ON d.order_id = o.order_id
                    WHERE o.order_id = @second_order AND o.order_status = N'已取消'
                        AND d.dispatch_id = @second_dispatch AND d.dispatch_status = N'已撤回'
                ) THROW 51416, N'取消订单未同步撤回派单。', 1;
            END;
        END;
        ROLLBACK;
    END TRY
    BEGIN CATCH
        SELECT @caught = ERROR_NUMBER(), @message = ERROR_MESSAGE();
        -- 在调用方回滚之前检查失败后的事务归属，不能只看回滚后的最终状态。
        IF @case_id = 29 AND (@@TRANCOUNT <> 1 OR XACT_STATE() <> -1)
            SELECT @caught = 51435, @message = N'插入失败后外层事务被结束或未标为不可提交。';
        -- THROW退出时SQL Server可能不将过程内的OUTPUT赋值复制回调用方；失败后不使用该编号。
        SET @dispatch_id = NULL;
        IF XACT_STATE() <> 0 ROLLBACK;
    END CATCH;

    IF NOT EXISTS (SELECT 1 FROM @tests WHERE case_id = @case_id AND expected_error = @caught)
    BEGIN
        SET @message = CONCAT(N'用例 ', @case_id, N' 失败。实际错误号 ', @caught, N'。', @message);
        THROW 51420, @message, 1;
    END;
    IF @case_id IN (9, 25, 29, 30) AND NOT EXISTS (
        SELECT 1 FROM dbo.dispatch_record AS d JOIN dbo.service_order AS o ON o.order_id = d.order_id
        WHERE d.dispatch_id = @old_dispatch AND d.dispatch_status = N'待接单' AND o.order_status = N'待接单'
    ) THROW 51421, N'失败的改派没有恢复原派单与订单状态。', 1;

    INSERT @results SELECT case_id, name, 'PASS' FROM @tests WHERE case_id = @case_id;
    SET @case_id += 1;
END;

-- 用例31必须没有外层事务：向已有样例改派，在撤回旧单后的INSERT处注入错误，
-- 验证本过程自己开启的事务确实回滚，而不是由测试脚本代为回滚。
IF @@TRANCOUNT <> 0 THROW 51436, N'自有事务测试开始前不应存在外层事务。', 1;
IF OBJECT_ID(N'dbo.TR_M2_Test_OwnInsertFailure', N'TR') IS NOT NULL
    THROW 51436, N'同名测试触发器已存在，请核对测试库；不覆盖既有对象。', 1;
DECLARE @before_dispatch_count INT = (SELECT COUNT(*) FROM dbo.dispatch_record WHERE order_id = @persistent_order);
EXEC(N'CREATE TRIGGER dbo.TR_M2_Test_OwnInsertFailure ON dbo.dispatch_record AFTER INSERT AS
    BEGIN
        SET NOCOUNT ON;
        IF EXISTS (SELECT 1 FROM inserted WHERE reassign_reason = N''M2:own-insert-failure'')
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM dbo.dispatch_record AS d JOIN inserted AS i ON i.order_id = d.order_id
                           WHERE d.dispatch_status = N''已撤回'')
                THROW 51432, N''故障注入未到达撤回旧派单之后。'', 1;
            THROW 51431, N''模拟自有事务后续插入失败。'', 1;
        END;
    END;');
SET @caught = 0;
SET @dispatch_id = @old_dispatch;
SELECT @reassign_target = caregiver_id FROM dbo.dispatch_record WHERE dispatch_id = @old_dispatch;
BEGIN TRY
    EXEC dbo.usp_M2_OrderAction @persistent_order, 'REASSIGN', @reassign_target, @dispatch_id OUTPUT,
        @Reason = N'M2:own-insert-failure';
END TRY
BEGIN CATCH
    SELECT @caught = ERROR_NUMBER(), @message = ERROR_MESSAGE();
END CATCH;
DECLARE @own_rollback_ok BIT = IIF(@caught = 51431 AND @@TRANCOUNT = 0 AND XACT_STATE() = 0, 1, 0);
SET @dispatch_id = NULL;
IF XACT_STATE() <> 0 ROLLBACK;
DROP TRIGGER dbo.TR_M2_Test_OwnInsertFailure;
IF @own_rollback_ok <> 1
    THROW 51437, N'自有事务插入失败后未自行回滚。', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.dispatch_record AS d JOIN dbo.service_order AS o ON o.order_id = d.order_id
               WHERE d.dispatch_id = @old_dispatch AND d.dispatch_status = N'待接单' AND o.order_status = N'待接单')
    OR (SELECT COUNT(*) FROM dbo.dispatch_record WHERE order_id = @persistent_order) <> @before_dispatch_count
    THROW 51437, N'自有事务回滚未完整恢复原派单或残留新派单。', 1;
INSERT @results VALUES (31, N'后续插入失败由过程回滚自有事务', 'PASS');

-- 用例32：在共同加锁入口处检查实际锁，不能只靠最终状态推断加锁顺序。
-- 临时增强模拟过程，在机构锁入口拒绝已经持有订单/派单U、X或范围更新锁的调用。
DECLARE @scope_definition NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(N'dbo.usp_M5_LockScope'));
DECLARE @scope_probe NVARCHAR(MAX) = N'
    IF EXISTS (
        SELECT 1 FROM sys.dm_tran_locks AS l
        WHERE l.request_session_id = @@SPID AND l.resource_database_id = DB_ID()
          AND l.request_mode IN (N''U'', N''X'', N''IX'', N''SIX'', N''RangeS-U'', N''RangeI-N'', N''RangeX-X'')
          AND (l.resource_associated_entity_id IN
               (SELECT hobt_id FROM sys.partitions WHERE object_id IN
                   (OBJECT_ID(N''dbo.service_order''), OBJECT_ID(N''dbo.dispatch_record'')))
            OR (l.resource_type = N''OBJECT'' AND l.resource_associated_entity_id IN
                   (OBJECT_ID(N''dbo.service_order''), OBJECT_ID(N''dbo.dispatch_record'')))))
        THROW 51438, N''共同机构锁之前已经持有订单或派单更新保护锁。'', 1;
    SET NOCOUNT ON;';
IF @scope_definition IS NULL OR CHARINDEX(N'SET NOCOUNT ON;', @scope_definition) = 0
    THROW 51438, N'无法安装共同加锁入口的测试探针。', 1;
SET @scope_definition = REPLACE(@scope_definition, N'CREATE PROCEDURE', N'ALTER PROCEDURE');
SET @scope_definition = REPLACE(@scope_definition, N'SET NOCOUNT ON;', @scope_probe);
BEGIN TRY
    BEGIN TRAN;
    EXEC sys.sp_executesql @scope_definition;
    SET @dispatch_id = @old_dispatch;
    EXEC dbo.usp_M2_OrderAction @persistent_order, 'REASSIGN', @reassign_target, @dispatch_id OUTPUT,
        @Reason = N'加锁顺序探针';
    IF @@TRANCOUNT <> 1 OR XACT_STATE() <> 1 THROW 51438, N'探针测试的外层事务被改变。', 1;
    ROLLBACK;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    THROW;
END CATCH;
INSERT @results VALUES (32, N'共同机构锁先于订单及派单保护锁', 'PASS');

SELECT case_id, test_name, result FROM @results ORDER BY case_id;
PRINT N'PASS 原25项及新增7项独立业务/接口契约用例（成员5为模拟实现，不能替代真实联调）。测试写入已回滚，IDENTITY编号可能出现空号。';
