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

-- 01和03后可先检查本模块；整合02后将下列开关改为1，缺外键即报错。
DECLARE @RequireCrossModuleFK bit=0;
DECLARE @Issues TABLE(detail nvarchar(500));
DECLARE @Expected TABLE(t sysname,c sysname,typ sysname,bytes smallint,scale tinyint,nullable bit,ident bit,ordinal int);
INSERT @Expected VALUES
(N'caregiver',N'caregiver_id',N'int',4,0,0,1,1),
(N'caregiver',N'caregiver_name',N'nvarchar',100,0,0,0,2),
(N'caregiver',N'org_id',N'int',4,0,0,0,3),
(N'caregiver',N'phone',N'varchar',20,0,0,0,4),
(N'caregiver',N'service_area',N'nvarchar',400,0,0,0,5),
(N'caregiver',N'employment_status',N'nvarchar',20,0,0,0,6),
(N'caregiver_certificate',N'certificate_id',N'int',4,0,0,1,1),
(N'caregiver_certificate',N'caregiver_id',N'int',4,0,0,0,2),
(N'caregiver_certificate',N'certificate_no',N'nvarchar',100,0,0,0,3),
(N'caregiver_certificate',N'certificate_type',N'nvarchar',100,0,0,0,4),
(N'caregiver_certificate',N'service_id',N'int',4,0,0,0,5),
(N'caregiver_certificate',N'qualification_level',N'nvarchar',60,0,0,0,6),
(N'caregiver_certificate',N'valid_from',N'date',3,0,0,0,7),
(N'caregiver_certificate',N'valid_to',N'date',3,0,0,0,8),
(N'caregiver_certificate',N'certificate_status',N'nvarchar',20,0,0,0,9),
(N'caregiver_schedule',N'schedule_id',N'int',4,0,0,1,1),
(N'caregiver_schedule',N'caregiver_id',N'int',4,0,0,0,2),
(N'caregiver_schedule',N'start_time',N'datetime2',6,0,0,0,3),
(N'caregiver_schedule',N'end_time',N'datetime2',6,0,0,0,4),
(N'caregiver_schedule',N'max_orders',N'int',4,0,0,0,5),
(N'caregiver_schedule',N'schedule_status',N'nvarchar',20,0,0,0,6),
(N'work_record',N'work_id',N'int',4,0,0,1,1),
(N'work_record',N'schedule_id',N'int',4,0,0,0,2),
(N'work_record',N'dispatch_id',N'int',4,0,0,0,3),
(N'work_record',N'check_in_time',N'datetime2',6,0,0,0,4),
(N'work_record',N'check_out_time',N'datetime2',6,0,1,0,5),
(N'work_record',N'check_in_location',N'nvarchar',400,0,1,0,6),
(N'work_record',N'check_out_location',N'nvarchar',400,0,1,0,7),
(N'work_record',N'fence_result',N'nvarchar',20,0,0,0,8),
(N'work_record',N'effective_minutes',N'int',4,0,1,0,9),
(N'work_record',N'review_status',N'nvarchar',20,0,0,0,10),
(N'work_record',N'review_note',N'nvarchar',510,0,1,0,11);

INSERT @Issues SELECT N'字段缺失或类型/长度/空值/自增/顺序不符：'+e.t+N'.'+e.c
FROM @Expected e LEFT JOIN sys.columns c ON c.object_id=OBJECT_ID(N'dbo.'+e.t) AND c.name=e.c
LEFT JOIN sys.types y ON c.user_type_id=y.user_type_id
WHERE c.column_id IS NULL OR y.name<>e.typ OR c.max_length<>e.bytes OR c.scale<>e.scale OR c.is_nullable<>e.nullable OR c.is_identity<>e.ident OR c.column_id<>e.ordinal;
INSERT @Issues SELECT N'存在额外字段：'+t.name+N'.'+c.name FROM sys.tables t JOIN sys.columns c ON c.object_id=t.object_id
WHERE SCHEMA_NAME(t.schema_id)=N'dbo' AND t.name IN (SELECT DISTINCT t FROM @Expected) AND NOT EXISTS(SELECT 1 FROM @Expected e WHERE e.t=t.name AND e.c=c.name);
SELECT e.t AS table_name,e.c AS expected_column,y.name AS actual_type,c.max_length,c.scale,c.is_nullable,c.is_identity,c.column_id FROM @Expected e
LEFT JOIN sys.columns c ON c.object_id=OBJECT_ID(N'dbo.'+e.t) AND c.name=e.c LEFT JOIN sys.types y ON c.user_type_id=y.user_type_id ORDER BY e.t,e.ordinal;
SELECT OBJECT_NAME(object_id) AS table_name,name,seed_value,increment_value FROM sys.identity_columns WHERE object_id IN(SELECT OBJECT_ID(N'dbo.'+t) FROM @Expected);
INSERT @Issues SELECT N'IDENTITY种子或增量不为1：'+OBJECT_NAME(object_id) FROM sys.identity_columns WHERE object_id IN(SELECT OBJECT_ID(N'dbo.'+t) FROM @Expected) AND (CONVERT(bigint,seed_value)<>1 OR CONVERT(bigint,increment_value)<>1);
DECLARE @Keys TABLE(t sysname,n sysname,kind char(2),cols nvarchar(200));
INSERT @Keys VALUES
(N'caregiver',N'PK_M3_caregiver','PK',N'caregiver_id'),
(N'caregiver_certificate',N'PK_M3_caregiver_certificate','PK',N'certificate_id'),
(N'caregiver_schedule',N'PK_M3_caregiver_schedule','PK',N'schedule_id'),
(N'work_record',N'PK_M3_work_record','PK',N'work_id'),
(N'caregiver_certificate',N'UQ_M3_certificate_caregiver_no','UQ',N'caregiver_id,certificate_no'),
(N'work_record',N'UQ_M3_work_dispatch','UQ',N'dispatch_id');

INSERT @Issues SELECT N'主键或唯一键不符：'+e.n FROM @Keys e LEFT JOIN sys.key_constraints k ON k.parent_object_id=OBJECT_ID(N'dbo.'+e.t) AND k.name=e.n
OUTER APPLY (SELECT STUFF((SELECT N','+c.name FROM sys.index_columns ic JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id WHERE ic.object_id=k.parent_object_id AND ic.index_id=k.unique_index_id AND ic.key_ordinal>0 ORDER BY ic.key_ordinal FOR XML PATH(''),TYPE).value('.','nvarchar(max)'),1,1,N'') AS cols) z
WHERE k.object_id IS NULL OR k.type COLLATE DATABASE_DEFAULT<>e.kind OR z.cols COLLATE DATABASE_DEFAULT<>e.cols;
SELECT e.t,e.n,e.kind,e.cols AS expected_columns,k.type_desc FROM @Keys e LEFT JOIN sys.key_constraints k ON k.parent_object_id=OBJECT_ID(N'dbo.'+e.t) AND k.name=e.n;
DECLARE @Checks TABLE(t sysname,n sysname,expected_expression nvarchar(max));
INSERT @Checks VALUES
(N'caregiver',N'CK_M3_caregiver_employment_status_enum',N'employment_status IN (N''在岗'', N''停用'', N''离职'')'),
(N'caregiver_certificate',N'CK_M3_caregiver_certificate_certificate_status_enum',N'certificate_status IN (N''有效'', N''暂停'', N''吊销'')'),
(N'caregiver_certificate',N'CK_M3_caregiver_certificate_valid_dates',N'valid_to >= valid_from'),
(N'caregiver_schedule',N'CK_M3_caregiver_schedule_schedule_status_enum',N'schedule_status IN (N''开放'', N''关闭'', N''取消'')'),
(N'caregiver_schedule',N'CK_M3_caregiver_schedule_time_range',N'end_time > start_time'),
(N'caregiver_schedule',N'CK_M3_caregiver_schedule_positive_capacity',N'max_orders > 0'),
(N'work_record',N'CK_M3_work_record_fence_result_enum',N'fence_result IN (N''待校验'', N''通过'', N''未通过'')'),
(N'work_record',N'CK_M3_work_record_review_status_enum',N'review_status IN (N''待审核'', N''通过'', N''驳回'')'),
(N'work_record',N'CK_M3_work_record_checkout',N'check_out_time IS NULL OR check_out_time > check_in_time'),
(N'work_record',N'CK_M3_work_record_checkout_location',N'check_out_time IS NOT NULL OR check_out_location IS NULL'),
(N'work_record',N'CK_M3_work_record_minutes',N'effective_minutes IS NULL OR (check_out_time IS NOT NULL AND effective_minutes >= 0 AND CONVERT(BIGINT,effective_minutes)*60 <= DATEDIFF_BIG(SECOND,check_in_time,check_out_time))'),
(N'work_record',N'CK_M3_work_record_review_ready',N'(review_status = N''通过'' AND check_out_time IS NOT NULL AND effective_minutes IS NOT NULL) OR (review_status IN (N''待审核'',N''驳回'') AND effective_minutes IS NULL)'),
(N'work_record',N'CK_M3_work_record_abnormal_note',N'review_status <> N''通过'' OR (fence_result = N''通过'' AND check_in_location IS NOT NULL AND check_out_location IS NOT NULL) OR (review_note IS NOT NULL AND LEN(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(REPLACE(review_note,NCHAR(9),N''''),NCHAR(10),N''''),NCHAR(13),N''''),NCHAR(12288),N'''')))) > 0)');

INSERT @Issues SELECT N'CHECK缺失/禁用/不可信：'+e.n FROM @Checks e LEFT JOIN sys.check_constraints c ON c.parent_object_id=OBJECT_ID(N'dbo.'+e.t) AND c.name=e.n WHERE c.object_id IS NULL OR c.is_disabled=1 OR c.is_not_trusted=1;
-- 名称与启用状态自动检查；表达式并列输出供语义复核，不把名称相同当作表达式等价证明。
SELECT e.t,e.n,e.expected_expression,c.definition,c.is_disabled,c.is_not_trusted FROM @Checks e LEFT JOIN sys.check_constraints c ON c.parent_object_id=OBJECT_ID(N'dbo.'+e.t) AND c.name=e.n;
DECLARE @Defaults TABLE(t sysname,c sysname,v nvarchar(50));
INSERT @Defaults VALUES
(N'caregiver',N'employment_status',N'N''在岗'''),
(N'caregiver_certificate',N'certificate_status',N'N''有效'''),
(N'caregiver_schedule',N'schedule_status',N'N''开放'''),
(N'work_record',N'fence_result',N'N''待校验'''),
(N'work_record',N'review_status',N'N''待审核''');

INSERT @Issues SELECT N'默认值不符：'+e.t+N'.'+e.c FROM @Defaults e LEFT JOIN sys.columns c ON c.object_id=OBJECT_ID(N'dbo.'+e.t) AND c.name=e.c LEFT JOIN sys.default_constraints d ON d.object_id=c.default_object_id WHERE d.object_id IS NULL OR REPLACE(REPLACE(d.definition,N'(',N''),N')',N'') COLLATE DATABASE_DEFAULT<>e.v;
SELECT e.*,d.definition FROM @Defaults e LEFT JOIN sys.columns c ON c.object_id=OBJECT_ID(N'dbo.'+e.t) AND c.name=e.c LEFT JOIN sys.default_constraints d ON d.object_id=c.default_object_id;
DECLARE @FK TABLE(t sysname,c sysname,rt sysname,rc sysname,is_cross_module bit);
INSERT @FK VALUES
(N'caregiver_certificate',N'caregiver_id',N'caregiver',N'caregiver_id',0),
(N'caregiver_schedule',N'caregiver_id',N'caregiver',N'caregiver_id',0),
(N'work_record',N'schedule_id',N'caregiver_schedule',N'schedule_id',0),
(N'caregiver',N'org_id',N'service_org',N'org_id',1),
(N'caregiver_certificate',N'service_id',N'service_item',N'service_id',1),
(N'work_record',N'dispatch_id',N'dispatch_record',N'dispatch_id',1),
(N'dispatch_record',N'caregiver_id',N'caregiver',N'caregiver_id',1),
(N'dispatch_record',N'schedule_id',N'caregiver_schedule',N'schedule_id',1);

SELECT e.*,z.name,z.is_disabled,z.is_not_trusted,z.delete_referential_action_desc,z.update_referential_action_desc,
 CASE WHEN z.name IS NOT NULL THEN N'存在' WHEN e.is_cross_module=1 AND @RequireCrossModuleFK=0 THEN N'待整合（非通过）' ELSE N'缺失' END AS deployment_status
INTO #M3FKStatus FROM @FK e OUTER APPLY (
 SELECT TOP(1) f.name,f.is_disabled,f.is_not_trusted,f.delete_referential_action_desc,f.update_referential_action_desc
 FROM sys.foreign_keys f JOIN sys.foreign_key_columns fc ON fc.constraint_object_id=f.object_id
 WHERE f.parent_object_id=OBJECT_ID(N'dbo.'+e.t) AND f.referenced_object_id=OBJECT_ID(N'dbo.'+e.rt)
 AND COL_NAME(fc.parent_object_id,fc.parent_column_id)=e.c AND COL_NAME(fc.referenced_object_id,fc.referenced_column_id)=e.rc
 AND (SELECT COUNT(*) FROM sys.foreign_key_columns x WHERE x.constraint_object_id=f.object_id)=1
) z;
INSERT @Issues SELECT N'外键缺失或状态/动作不符：'+t+N'.'+c FROM #M3FKStatus WHERE (is_cross_module=0 OR @RequireCrossModuleFK=1) AND (name IS NULL OR is_disabled=1 OR is_not_trusted=1 OR delete_referential_action_desc<>N'NO_ACTION' OR update_referential_action_desc<>N'NO_ACTION');
SELECT * FROM #M3FKStatus; DROP TABLE #M3FKStatus;
DECLARE @IX TABLE(t sysname,n sysname,k nvarchar(250),inc nvarchar(250),filtered bit);
INSERT @IX VALUES
(N'caregiver_certificate',N'IX_M3_certificate_eligibility',N'caregiver_id,service_id,certificate_status,valid_to',N'certificate_type,qualification_level,valid_from',0),
(N'caregiver_schedule',N'IX_M3_schedule_caregiver_start',N'caregiver_id,start_time',N'end_time,max_orders,schedule_status',0),
(N'work_record',N'IX_M3_work_schedule_time',N'schedule_id,check_in_time',N'effective_minutes,review_status',0),
(N'work_record',N'IX_M3_work_approved_month',N'check_in_time,schedule_id',N'effective_minutes',1);

SELECT e.*,i.type,i.is_unique,i.is_disabled,i.filter_definition,i.has_filter,z.keys_actual,z.include_actual INTO #M3IndexStatus
FROM @IX e LEFT JOIN sys.indexes i ON i.object_id=OBJECT_ID(N'dbo.'+e.t) AND i.name=e.n
OUTER APPLY (SELECT
 STUFF((SELECT N','+c.name FROM sys.index_columns ic JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id WHERE ic.object_id=i.object_id AND ic.index_id=i.index_id AND ic.key_ordinal>0 ORDER BY ic.key_ordinal FOR XML PATH(''),TYPE).value('.','nvarchar(max)'),1,1,N'') AS keys_actual,
 STUFF((SELECT N','+c.name FROM sys.index_columns ic JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id WHERE ic.object_id=i.object_id AND ic.index_id=i.index_id AND ic.is_included_column=1 ORDER BY c.name FOR XML PATH(''),TYPE).value('.','nvarchar(max)'),1,1,N'') AS include_actual) z;
INSERT @Issues SELECT N'索引结构不符：'+n FROM #M3IndexStatus WHERE type IS NULL OR type<>2 OR is_unique<>0 OR is_disabled=1 OR has_filter<>filtered OR keys_actual COLLATE DATABASE_DEFAULT<>k OR include_actual COLLATE DATABASE_DEFAULT<>inc;
-- 筛选表达式单列输出，应为review_status=N'通过'，需人工核对语义。
SELECT * FROM #M3IndexStatus; DROP TABLE #M3IndexStatus;
SELECT COUNT(DISTINCT t) AS expected_tables,COUNT(*) AS expected_columns FROM @Expected;
SELECT detail FROM @Issues;
IF EXISTS(SELECT 1 FROM @Issues) THROW 51004,N'结构核对发现差异，参见前述结果集。',1;
PRINT N'自动元数据检查未发现差异；仍须核对CHECK/筛选表达式。跨模块是否已整合取决于开关与外键状态结果。';
