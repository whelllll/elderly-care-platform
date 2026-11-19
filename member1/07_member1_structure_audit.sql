/*
社区居家养老智慧服务平台
成员1：数据库结构验收脚本

用途：
只读取 SQL Server 系统目录，不修改、不删除任何业务数据或表结构。
检查成员1负责的五张表：
service_org、elder_profile、ability_assessment、care_plan、care_plan_item。

执行前提：
当前数据库为 Member1_Standalone_Test。
*/

USE [Member1_Standalone_Test];
GO

-- 一、检查五张表是否全部存在，以及字段数量是否符合设计
SELECT
    v.table_name AS expected_table,
    CASE WHEN t.object_id IS NULL THEN N'缺失' ELSE N'存在' END AS table_status,
    COUNT(c.column_id) AS actual_column_count
FROM
(
    VALUES
        (N'service_org'),
        (N'elder_profile'),
        (N'ability_assessment'),
        (N'care_plan'),
        (N'care_plan_item')
) AS v(table_name)
LEFT JOIN sys.tables AS t
    ON t.name = v.table_name
   AND t.schema_id = SCHEMA_ID(N'dbo')
LEFT JOIN sys.columns AS c
    ON c.object_id = t.object_id
GROUP BY v.table_name, t.object_id
ORDER BY v.table_name;
GO

-- 二、查看五张表的全部字段、数据类型、是否允许 NULL、默认值和自增属性
SELECT
    t.name AS table_name,
    c.column_id,
    c.name AS column_name,
    CASE
        WHEN ty.name IN (N'nvarchar', N'nchar')
            THEN ty.name + N'(' +
                 CASE WHEN c.max_length = -1 THEN N'max'
                      ELSE CONVERT(nvarchar(10), c.max_length / 2) END + N')'
        WHEN ty.name IN (N'varchar', N'char', N'varbinary', N'binary')
            THEN ty.name + N'(' +
                 CASE WHEN c.max_length = -1 THEN N'max'
                      ELSE CONVERT(nvarchar(10), c.max_length) END + N')'
        WHEN ty.name IN (N'decimal', N'numeric')
            THEN ty.name + N'(' + CONVERT(nvarchar(10), c.precision) +
                 N',' + CONVERT(nvarchar(10), c.scale) + N')'
        ELSE ty.name
    END AS data_type,
    CASE WHEN c.is_nullable = 1 THEN N'允许 NULL' ELSE N'不允许 NULL' END AS null_rule,
    dc.definition AS default_value,
    CASE WHEN ic.column_id IS NOT NULL THEN N'是' ELSE N'否' END AS is_identity
FROM sys.tables AS t
INNER JOIN sys.columns AS c
    ON c.object_id = t.object_id
INNER JOIN sys.types AS ty
    ON ty.user_type_id = c.user_type_id
LEFT JOIN sys.default_constraints AS dc
    ON dc.parent_object_id = c.object_id
   AND dc.parent_column_id = c.column_id
LEFT JOIN sys.identity_columns AS ic
    ON ic.object_id = c.object_id
   AND ic.column_id = c.column_id
WHERE t.schema_id = SCHEMA_ID(N'dbo')
  AND t.name IN
  (
      N'service_org', N'elder_profile', N'ability_assessment',
      N'care_plan', N'care_plan_item'
  )
ORDER BY t.name, c.column_id;
GO

-- 三、查看主键和唯一约束
SELECT
    t.name AS table_name,
    kc.name AS constraint_name,
    CASE kc.type
        WHEN N'PK' THEN N'主键'
        WHEN N'UQ' THEN N'唯一约束'
        ELSE kc.type_desc
    END AS constraint_type,
    STRING_AGG(CONVERT(nvarchar(max), c.name), N', ')
        WITHIN GROUP (ORDER BY ic.key_ordinal) AS constraint_columns
FROM sys.key_constraints AS kc
INNER JOIN sys.tables AS t
    ON t.object_id = kc.parent_object_id
INNER JOIN sys.index_columns AS ic
    ON ic.object_id = kc.parent_object_id
   AND ic.index_id = kc.unique_index_id
   AND ic.key_ordinal > 0
INNER JOIN sys.columns AS c
    ON c.object_id = ic.object_id
   AND c.column_id = ic.column_id
WHERE t.schema_id = SCHEMA_ID(N'dbo')
  AND t.name IN
  (
      N'service_org', N'elder_profile', N'ability_assessment',
      N'care_plan', N'care_plan_item'
  )
GROUP BY t.name, kc.name, kc.type
ORDER BY t.name, kc.type, kc.name;
GO

-- 四、查看外键关系及其引用字段
SELECT
    fk.name AS foreign_key_name,
    OBJECT_NAME(fk.parent_object_id) AS child_table,
    COL_NAME(fkc.parent_object_id, fkc.parent_column_id) AS child_column,
    OBJECT_NAME(fk.referenced_object_id) AS parent_table,
    COL_NAME(fkc.referenced_object_id, fkc.referenced_column_id) AS parent_column,
    fk.delete_referential_action_desc AS delete_rule,
    CASE WHEN fk.is_disabled = 1 THEN N'已禁用' ELSE N'已启用' END AS enabled_status,
    CASE WHEN fk.is_not_trusted = 1 THEN N'未验证' ELSE N'已验证' END AS trusted_status
FROM sys.foreign_keys AS fk
INNER JOIN sys.foreign_key_columns AS fkc
    ON fkc.constraint_object_id = fk.object_id
WHERE fk.parent_object_id IN
(
    OBJECT_ID(N'dbo.service_org'),
    OBJECT_ID(N'dbo.elder_profile'),
    OBJECT_ID(N'dbo.ability_assessment'),
    OBJECT_ID(N'dbo.care_plan'),
    OBJECT_ID(N'dbo.care_plan_item')
)
ORDER BY child_table, foreign_key_name;
GO

-- 五、查看 CHECK 约束及约束表达式
SELECT
    OBJECT_NAME(parent_object_id) AS table_name,
    name AS check_constraint_name,
    definition AS check_rule,
    CASE WHEN is_disabled = 1 THEN N'已禁用' ELSE N'已启用' END AS enabled_status,
    CASE WHEN is_not_trusted = 1 THEN N'未验证' ELSE N'已验证' END AS trusted_status
FROM sys.check_constraints
WHERE parent_object_id IN
(
    OBJECT_ID(N'dbo.service_org'),
    OBJECT_ID(N'dbo.elder_profile'),
    OBJECT_ID(N'dbo.ability_assessment'),
    OBJECT_ID(N'dbo.care_plan'),
    OBJECT_ID(N'dbo.care_plan_item')
)
ORDER BY table_name, check_constraint_name;
GO

-- 六、查看默认约束
SELECT
    OBJECT_NAME(parent_object_id) AS table_name,
    name AS default_constraint_name,
    COL_NAME(parent_object_id, parent_column_id) AS column_name,
    definition AS default_value
FROM sys.default_constraints
WHERE parent_object_id IN
(
    OBJECT_ID(N'dbo.service_org'),
    OBJECT_ID(N'dbo.elder_profile'),
    OBJECT_ID(N'dbo.ability_assessment'),
    OBJECT_ID(N'dbo.care_plan'),
    OBJECT_ID(N'dbo.care_plan_item')
)
ORDER BY table_name, default_constraint_name;
GO

-- 七、查看索引及索引字段
SELECT
    t.name AS table_name,
    i.name AS index_name,
    i.type_desc AS index_type,
    CASE WHEN i.is_unique = 1 THEN N'唯一' ELSE N'非唯一' END AS uniqueness,
    CASE WHEN i.is_primary_key = 1 THEN N'主键索引' ELSE N'普通/唯一索引' END AS index_role,
    STUFF
    (
        (
            SELECT N', ' + QUOTENAME(c.name) +
                   CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N' ASC' END
            FROM sys.index_columns AS ic
            INNER JOIN sys.columns AS c
                ON c.object_id = ic.object_id
               AND c.column_id = ic.column_id
            WHERE ic.object_id = i.object_id
              AND ic.index_id = i.index_id
              AND ic.key_ordinal > 0
            ORDER BY ic.key_ordinal
            FOR XML PATH(N''), TYPE
        ).value(N'.', N'nvarchar(max)'),
        1, 2, N''
    ) AS key_columns,
    STUFF
    (
        (
            SELECT N', ' + QUOTENAME(c.name)
            FROM sys.index_columns AS ic
            INNER JOIN sys.columns AS c
                ON c.object_id = ic.object_id
               AND c.column_id = ic.column_id
            WHERE ic.object_id = i.object_id
              AND ic.index_id = i.index_id
              AND ic.is_included_column = 1
            ORDER BY ic.index_column_id
            FOR XML PATH(N''), TYPE
        ).value(N'.', N'nvarchar(max)'),
        1, 2, N''
    ) AS included_columns
FROM sys.indexes AS i
INNER JOIN sys.tables AS t
    ON t.object_id = i.object_id
WHERE t.schema_id = SCHEMA_ID(N'dbo')
  AND t.name IN
  (
      N'service_org', N'elder_profile', N'ability_assessment',
      N'care_plan', N'care_plan_item'
  )
  AND i.index_id > 0
  AND i.is_hypothetical = 0
ORDER BY t.name, i.index_id;
GO

-- 八、核对成员1设计中应存在的三个普通索引
SELECT
    v.table_name,
    v.index_name AS expected_index,
    CASE WHEN i.index_id IS NULL THEN N'缺失' ELSE N'存在' END AS index_status
FROM
(
    VALUES
        (N'ability_assessment', N'IX_ability_assessment_elder_date'),
        (N'care_plan', N'IX_care_plan_elder_status_date'),
        (N'service_org', N'IX_service_org_status')
) AS v(table_name, index_name)
LEFT JOIN sys.indexes AS i
    ON i.name = v.index_name
   AND i.object_id = OBJECT_ID(N'dbo.' + v.table_name)
ORDER BY v.table_name;
GO

/*
验收提示：
1. 五张表应全部显示“存在”，字段数依次为：
   service_org 8、elder_profile 12、ability_assessment 8、
   care_plan 8、care_plan_item 3。
2. 本地外键应至少包括：
   ability_assessment.elder_id -> elder_profile.elder_id；
   care_plan.elder_id -> elder_profile.elder_id；
   care_plan_item.plan_id -> care_plan.plan_id。
3. care_plan.responsible_caregiver_id 和 care_plan_item.service_id
   的跨模块外键，须等成员3 caregiver 表、成员2 service_item 表部署后，
   再执行 02_member1_cross_module_foreign_keys.sql。
4. caregiver.org_id -> service_org.org_id 是成员3护工表一侧的外键，
   需在全局整合时与成员3确认。
5. 本脚本只做结构查询，不会修改数据库。
*/
