-- 独立路径只在 Member2_Standalone_Test 将下一行改为 1。
-- 整合路径保留 0，先完成成员1、2、3的建表。
DECLARE @Standalone BIT = 0;
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF OBJECT_ID(N'dbo.service_order', N'U') IS NULL OR OBJECT_ID(N'dbo.dispatch_record', N'U') IS NULL
    THROW 51002, N'请先运行 01_member2_tables.sql。', 1;

BEGIN TRY
    BEGIN TRAN;
    IF @Standalone = 1
    BEGIN
        IF DB_NAME() <> N'Member2_Standalone_Test'
            THROW 51003, N'模拟父表只允许在 Member2_Standalone_Test 中创建。', 1;
        IF NOT EXISTS (SELECT 1 FROM sys.extended_properties WHERE class = 0 AND name = N'M2_fixture_v1')
        BEGIN
            IF EXISTS (SELECT 1 FROM sys.tables WHERE schema_id = SCHEMA_ID(N'dbo')
                       AND name NOT IN (N'service_item', N'service_order', N'dispatch_record'))
                THROW 51004, N'该库有其他业务表。请使用空的独立测试库。', 1;

            -- 仅供成员2独立测试。成员1、3的正式 DDL 由各自模块维护。
            CREATE TABLE dbo.elder_profile (
                elder_id INT IDENTITY(1,1) PRIMARY KEY,
                elder_name NVARCHAR(50) NOT NULL
            );
            CREATE TABLE dbo.caregiver (
                caregiver_id INT IDENTITY(1,1) PRIMARY KEY,
                caregiver_name NVARCHAR(50) NOT NULL,
                service_area NVARCHAR(200) NOT NULL,
                employment_status NVARCHAR(10) NOT NULL
            );
            CREATE TABLE dbo.caregiver_certificate (
                certificate_id INT IDENTITY(1,1) PRIMARY KEY,
                caregiver_id INT NOT NULL REFERENCES dbo.caregiver(caregiver_id),
                certificate_no NVARCHAR(50) NOT NULL,
                service_id INT NOT NULL,
                qualification_level NVARCHAR(30) NOT NULL,
                valid_from DATE NOT NULL,
                valid_to DATE NOT NULL,
                certificate_status NVARCHAR(10) NOT NULL,
                UNIQUE (caregiver_id, certificate_no, service_id)
            );
            CREATE TABLE dbo.caregiver_schedule (
                schedule_id INT IDENTITY(1,1) PRIMARY KEY,
                caregiver_id INT NOT NULL REFERENCES dbo.caregiver(caregiver_id),
                start_time DATETIME2(0) NOT NULL,
                end_time DATETIME2(0) NOT NULL,
                max_orders INT NOT NULL CHECK (max_orders > 0),
                schedule_status NVARCHAR(10) NOT NULL,
                CHECK (end_time > start_time)
            );
            CREATE TABLE dbo.work_record (
                work_id INT IDENTITY(1,1) PRIMARY KEY,
                schedule_id INT NOT NULL REFERENCES dbo.caregiver_schedule(schedule_id),
                dispatch_id INT NOT NULL UNIQUE,
                check_in_time DATETIME2(0) NOT NULL,
                check_out_time DATETIME2(0) NULL,
                check_in_location NVARCHAR(200) NOT NULL,
                check_out_location NVARCHAR(200) NULL,
                fence_result NVARCHAR(10) NOT NULL,
                effective_minutes INT NULL,
                review_status NVARCHAR(10) NOT NULL,
                review_note NVARCHAR(255) NULL
            );
            EXEC sys.sp_addextendedproperty @name = N'M2_fixture_v1', @value = 1;
        END
    END
    ELSE IF EXISTS (SELECT 1 FROM sys.extended_properties WHERE class = 0 AND name = N'M2_fixture_v1')
        THROW 51005, N'当前库是独立演示库。整合请使用另一数据库。', 1;

    DECLARE @links TABLE (
        fk_name SYSNAME, child_table SYSNAME, child_column SYSNAME,
        parent_table SYSNAME, parent_column SYSNAME
    );
    INSERT @links VALUES
        (N'FK_M2_order_elder', N'service_order', N'elder_id', N'elder_profile', N'elder_id'),
        (N'FK_M2_dispatch_caregiver', N'dispatch_record', N'caregiver_id', N'caregiver', N'caregiver_id'),
        (N'FK_M23_certificate_item', N'caregiver_certificate', N'service_id', N'service_item', N'service_id'),
        (N'FK_M23_work_dispatch', N'work_record', N'dispatch_id', N'dispatch_record', N'dispatch_id');

    DECLARE @fk SYSNAME, @child SYSNAME, @cc SYSNAME, @parent SYSNAME, @pc SYSNAME,
            @sql NVARCHAR(MAX), @message NVARCHAR(2048);
    DECLARE links CURSOR LOCAL FAST_FORWARD FOR SELECT * FROM @links;
    OPEN links;
    FETCH NEXT FROM links INTO @fk, @child, @cc, @parent, @pc;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF COL_LENGTH(N'dbo.' + @child, @cc) IS NULL OR COL_LENGTH(N'dbo.' + @parent, @pc) IS NULL
        BEGIN
            SET @message = CONCAT(N'缺少跨模块外键依赖：dbo.', @child, N'.', @cc,
                                  N' → dbo.', @parent, N'.', @pc);
            THROW 51006, @message, 1;
        END
        DECLARE @existing SYSNAME = NULL, @bad_action BIT = 0;
        SELECT TOP (1) @existing = f.name,
               @bad_action = CONVERT(BIT, CASE WHEN f.delete_referential_action <> 0
                   OR f.update_referential_action <> 0 OR f.is_not_for_replication = 1 THEN 1 ELSE 0 END)
        FROM sys.foreign_keys AS f
        JOIN sys.foreign_key_columns AS k ON k.constraint_object_id = f.object_id
        WHERE f.parent_object_id = OBJECT_ID(N'dbo.' + @child)
          AND f.referenced_object_id = OBJECT_ID(N'dbo.' + @parent)
          AND COL_NAME(f.parent_object_id, k.parent_column_id) = @cc
          AND COL_NAME(f.referenced_object_id, k.referenced_column_id) = @pc
          AND NOT EXISTS (SELECT 1 FROM sys.foreign_key_columns AS other
                          WHERE other.constraint_object_id = f.object_id AND other.constraint_column_id > 1)
        ORDER BY CASE WHEN f.delete_referential_action <> 0 OR f.update_referential_action <> 0
                        OR f.is_not_for_replication = 1 THEN 0 ELSE 1 END,
                 CASE WHEN f.is_disabled = 0 AND f.is_not_trusted = 0 THEN 0 ELSE 1 END, f.name;

        IF @bad_action = 1
            THROW 51007, N'既有跨模块外键使用级联动作或复制例外，请先由整合负责人修正。', 1;
        IF @existing IS NULL
            SET @sql = N'ALTER TABLE dbo.' + QUOTENAME(@child) + N' WITH CHECK ADD CONSTRAINT ' +
                QUOTENAME(@fk) + N' FOREIGN KEY (' + QUOTENAME(@cc) + N') REFERENCES dbo.' +
                QUOTENAME(@parent) + N' (' + QUOTENAME(@pc) + N') ON DELETE NO ACTION ON UPDATE NO ACTION;';
        ELSE IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE parent_object_id = OBJECT_ID(N'dbo.' + @child)
                        AND name = @existing AND (is_disabled = 1 OR is_not_trusted = 1))
            SET @sql = N'ALTER TABLE dbo.' + QUOTENAME(@child) + N' WITH CHECK CHECK CONSTRAINT ' +
                QUOTENAME(@existing) + N';';
        ELSE SET @sql = NULL;
        IF @sql IS NOT NULL EXEC sys.sp_executesql @sql;
        FETCH NEXT FROM links INTO @fk, @child, @cc, @parent, @pc;
    END;
    CLOSE links;
    DEALLOCATE links;
    COMMIT;
    PRINT N'4 条跨模块外键已检查。';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    THROW;
END CATCH;
