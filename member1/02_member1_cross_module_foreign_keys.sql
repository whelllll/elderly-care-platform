/*
成员1跨模块外键脚本
执行前提：
1. 已执行 01_member1_tables.sql。
2. 成员2的 dbo.service_item 已创建。
3. 成员3的 dbo.caregiver 已创建，且 caregiver_id 为 INT。
4. 本脚本只添加成员1表中指向成员2、成员3的外键。
*/

-- care_plan.responsible_caregiver_id -> caregiver.caregiver_id
IF OBJECT_ID(N'dbo.caregiver', N'U') IS NULL
    THROW 51001, N'缺少 dbo.caregiver，请先部署成员3护工档案表。', 1;

IF COL_LENGTH(N'dbo.care_plan', N'responsible_caregiver_id') IS NOT NULL
AND NOT EXISTS
(
    SELECT 1 FROM sys.foreign_keys
    WHERE name=N'FK_care_plan_caregiver'
      AND parent_object_id=OBJECT_ID(N'dbo.care_plan')
)
BEGIN
    ALTER TABLE dbo.care_plan WITH CHECK
    ADD CONSTRAINT FK_care_plan_caregiver
    FOREIGN KEY (responsible_caregiver_id)
    REFERENCES dbo.caregiver(caregiver_id)
    ON DELETE NO ACTION;
END;
GO

-- care_plan_item.service_id -> service_item.service_id
IF OBJECT_ID(N'dbo.service_item', N'U') IS NULL
    THROW 51002, N'缺少 dbo.service_item，请先部署成员2服务项目表。', 1;

IF NOT EXISTS
(
    SELECT 1 FROM sys.foreign_keys
    WHERE name=N'FK_care_plan_item_service_item'
      AND parent_object_id=OBJECT_ID(N'dbo.care_plan_item')
)
BEGIN
    ALTER TABLE dbo.care_plan_item WITH CHECK
    ADD CONSTRAINT FK_care_plan_item_service_item
    FOREIGN KEY (service_id)
    REFERENCES dbo.service_item(service_id)
    ON DELETE NO ACTION;
END;
GO

-- 检查成员1跨模块外键
SELECT
    fk.name AS foreign_key_name,
    OBJECT_NAME(fk.parent_object_id) AS child_table,
    COL_NAME(fkc.parent_object_id, fkc.parent_column_id) AS child_column,
    OBJECT_NAME(fk.referenced_object_id) AS parent_table,
    COL_NAME(fkc.referenced_object_id, fkc.referenced_column_id) AS parent_column
FROM sys.foreign_keys AS fk
JOIN sys.foreign_key_columns AS fkc
  ON fk.object_id=fkc.constraint_object_id
WHERE fk.parent_object_id IN (OBJECT_ID(N'dbo.care_plan'), OBJECT_ID(N'dbo.care_plan_item'));
GO
