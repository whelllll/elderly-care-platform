-- =============================================================
-- 成员5 补贴核算与质量监管  |  02 跨模块外键挂载
-- 前置：01_member5_tables.sql；成员1/2/3/4 的父表已建好
-- 说明：父表缺失时自动跳过并列出待办，不中断执行（便于分阶段联调）。
--       全部外键统一 ON DELETE NO ACTION / ON UPDATE NO ACTION，与全组约定一致。
-- =============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;

IF OBJECT_ID(N'dbo.subsidy_policy', N'U') IS NULL
    THROW 52010, N'请先执行 01_member5_tables.sql。', 1;

BEGIN TRY
    BEGIN TRAN;

    -- 成员3 工时表命名兼容：work_record(work_id) 为成员2 夹具采用的口径；
    -- work_hour(work_hour_id) 为任务书原始命名。两者任一存在即可挂载。
    DECLARE @work_table SYSNAME = NULL, @work_col SYSNAME = NULL;
    IF OBJECT_ID(N'dbo.work_record', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.work_record', N'work_id') IS NOT NULL
        SELECT @work_table = N'work_record', @work_col = N'work_id';
    ELSE IF OBJECT_ID(N'dbo.work_hour', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.work_hour', N'work_hour_id') IS NOT NULL
        SELECT @work_table = N'work_hour', @work_col = N'work_hour_id';
    ELSE IF OBJECT_ID(N'dbo.work_hour', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.work_hour', N'work_id') IS NOT NULL
        SELECT @work_table = N'work_hour', @work_col = N'work_id';
    ELSE IF OBJECT_ID(N'dbo.work_record', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.work_record', N'work_hour_id') IS NOT NULL
        SELECT @work_table = N'work_record', @work_col = N'work_hour_id';

    DECLARE @links TABLE (
        fk_name      SYSNAME,
        child_table  SYSNAME,
        child_column SYSNAME,
        parent_table SYSNAME,
        parent_column SYSNAME
    );

    INSERT @links (fk_name, child_table, child_column, parent_table, parent_column) VALUES
        (N'FK_M5_policy_item',        N'subsidy_policy',          N'service_item_id',  N'service_item',      N'service_id'),
        (N'FK_M5_app_elder',          N'subsidy_application',     N'elder_id',         N'elder_profile',     N'elder_id'),
        (N'FK_M5_item_order',         N'subsidy_application_item', N'order_id',        N'service_order',     N'order_id'),
        (N'FK_M5_app_auditor',        N'subsidy_application',     N'current_auditor_id', N'sys_user',        N'user_id'),
        (N'FK_M5_audit_user',         N'subsidy_audit_log',       N'auditor_id',       N'sys_user',          N'user_id'),
        (N'FK_M5_insp_order',         N'quality_inspection',      N'order_id',         N'service_order',     N'order_id'),
        (N'FK_M5_insp_caregiver',     N'quality_inspection',      N'caregiver_id',     N'caregiver',         N'caregiver_id'),
        (N'FK_M5_insp_user',          N'quality_inspection',      N'inspector_id',     N'sys_user',          N'user_id'),
        (N'FK_M5_rect_caregiver',     N'rectification',           N'caregiver_id',     N'caregiver',         N'caregiver_id'),
        (N'FK_M5_rect_org',           N'rectification',           N'org_id',           N'service_org',       N'org_id'),
        (N'FK_M5_rect_reviewer',      N'rectification',           N'reviewer_id',      N'sys_user',          N'user_id');

    IF @work_table IS NOT NULL
        INSERT @links (fk_name, child_table, child_column, parent_table, parent_column)
        VALUES (N'FK_M5_item_work', N'subsidy_application_item', N'work_id', @work_table, @work_col);

    DECLARE @fk SYSNAME, @child SYSNAME, @cc SYSNAME, @parent SYSNAME, @pc SYSNAME;
    DECLARE @sql NVARCHAR(MAX), @msg NVARCHAR(400), @missing NVARCHAR(MAX) = N'', @made INT = 0, @kept INT = 0;

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT * FROM @links;
    OPEN cur;
    FETCH NEXT FROM cur INTO @fk, @child, @cc, @parent, @pc;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF COL_LENGTH(N'dbo.' + @child, @cc) IS NULL
        BEGIN
            SET @msg = N'本模块缺列：dbo.' + @child + N'.' + @cc;
            THROW 52011, @msg, 1;
        END;

        IF OBJECT_ID(N'dbo.' + @parent, N'U') IS NULL OR COL_LENGTH(N'dbo.' + @parent, @pc) IS NULL
        BEGIN
            SET @missing = @missing + N'  ' + @fk + N'  →  dbo.' + @parent + N'(' + @pc + N')' + CHAR(13) + CHAR(10);
            FETCH NEXT FROM cur INTO @fk, @child, @cc, @parent, @pc;
            CONTINUE;
        END;

        IF NOT EXISTS (
            SELECT 1
            FROM sys.foreign_keys AS f
            JOIN sys.foreign_key_columns AS k ON k.constraint_object_id = f.object_id
            WHERE f.parent_object_id = OBJECT_ID(N'dbo.' + @child)
              AND f.referenced_object_id = OBJECT_ID(N'dbo.' + @parent)
              AND COL_NAME(f.parent_object_id, k.parent_column_id) = @cc
        )
        BEGIN
            SET @sql = N'ALTER TABLE dbo.' + QUOTENAME(@child) + N' WITH CHECK ADD CONSTRAINT ' +
                       QUOTENAME(@fk) + N' FOREIGN KEY (' + QUOTENAME(@cc) + N') REFERENCES dbo.' +
                       QUOTENAME(@parent) + N' (' + QUOTENAME(@pc) + N') ON DELETE NO ACTION ON UPDATE NO ACTION;';
            EXEC sys.sp_executesql @sql;
            SET @made += 1;
        END
        ELSE
        BEGIN
            SET @sql = N'ALTER TABLE dbo.' + QUOTENAME(@child) + N' WITH CHECK CHECK CONSTRAINT ' + QUOTENAME(@fk) + N';';
            BEGIN TRY EXEC sys.sp_executesql @sql; SET @kept += 1; END TRY
            BEGIN CATCH PRINT N'外键 ' + @fk + N' 已存在但数据校验未通过，请清理孤儿行后重跑。'; END CATCH
        END;

        FETCH NEXT FROM cur INTO @fk, @child, @cc, @parent, @pc;
    END;
    CLOSE cur;
    DEALLOCATE cur;

    COMMIT;

    PRINT N'成员5 跨模块外键：新建 ' + CAST(@made AS NVARCHAR(10)) + N' 条，已存在 ' +
          CAST(@kept AS NVARCHAR(10)) + N' 条。';
    IF LEN(@missing) > 0
    BEGIN
        PRINT N'以下父表尚未就绪，本次跳过（父表建好后重跑本文件即可）：';
        PRINT @missing;
    END;

    IF @work_table IS NULL
        PRINT N'工时表未找到：成员3 需确认表名为 work_record(work_id) 或 work_hour(work_hour_id)，确认后重跑本文件自动挂载。';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    THROW;
END CATCH;
