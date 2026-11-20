/* ============================================================
   成员4 sys_user.caregiver_id → 成员3 caregiver(caregiver_id)
   在成员3 提交 caregiver 表后执行；
   09_sys_user.sql 建表时如果 caregiver 已存在，会直接补这个外键。
   ============================================================ */

IF OBJECT_ID(N'dbo.caregiver', N'U') IS NULL
BEGIN
    PRINT N'caregiver 表尚未创建，暂不能添加 FK_sys_user_caregiver_id。';
END
ELSE IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys
                    WHERE name = N'FK_sys_user_caregiver_id')
BEGIN
    ALTER TABLE dbo.sys_user
        ADD CONSTRAINT FK_sys_user_caregiver_id FOREIGN KEY (caregiver_id)
        REFERENCES dbo.caregiver (caregiver_id) ON DELETE NO ACTION;
    PRINT N'FK_sys_user_caregiver_id 已添加。';
END
ELSE
BEGIN
    PRINT N'FK_sys_user_caregiver_id 已存在，无需重复添加。';
END;
GO
