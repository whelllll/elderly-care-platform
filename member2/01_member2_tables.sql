-- 先在 SSMS 选择独立测试库或组内整合测试库。
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;

IF DB_ID() <= 4 THROW 51000, N'请先选择用户数据库。', 1;

BEGIN TRY
    BEGIN TRAN;
    IF OBJECT_ID(N'dbo.service_item', N'U') IS NULL
        CREATE TABLE dbo.service_item (
            service_id INT IDENTITY(1,1) CONSTRAINT PK_M2_service_item PRIMARY KEY,
            service_name NVARCHAR(50) NOT NULL,
            service_type NVARCHAR(30) NOT NULL,
            price DECIMAL(10,2) NOT NULL CONSTRAINT CK_M2_item_price CHECK (price >= 0),
            duration INT NOT NULL CONSTRAINT CK_M2_item_duration CHECK (duration > 0),
            description NVARCHAR(255) NULL,
            status NVARCHAR(10) NOT NULL CONSTRAINT DF_M2_item_status DEFAULT N'上架',
            charge_unit NVARCHAR(10) NOT NULL,
            is_subsidizable BIT NOT NULL CONSTRAINT DF_M2_item_subsidizable DEFAULT 1,
            CONSTRAINT CK_M2_item_status CHECK (status IN (N'上架', N'下架')),
            CONSTRAINT CK_M2_item_type CHECK (service_type IN (N'助餐', N'助浴', N'陪诊', N'家政', N'康复护理')),
            CONSTRAINT CK_M2_item_charge_unit CHECK (charge_unit IN (N'次', N'小时')),
            CONSTRAINT UQ_M2_item_name_type UNIQUE (service_name, service_type)
        );

    IF OBJECT_ID(N'dbo.service_order', N'U') IS NULL
        CREATE TABLE dbo.service_order (
            order_id INT IDENTITY(1,1) CONSTRAINT PK_M2_service_order PRIMARY KEY,
            elder_id INT NOT NULL,
            service_id INT NOT NULL,
            order_time DATETIME2(0) NOT NULL CONSTRAINT DF_M2_order_time DEFAULT SYSDATETIME(),
            appointment_time DATETIME2(0) NOT NULL,
            order_status NVARCHAR(20) NOT NULL CONSTRAINT DF_M2_order_status DEFAULT N'待派单',
            total_amount DECIMAL(10,2) NOT NULL CONSTRAINT CK_M2_order_amount CHECK (total_amount >= 0),
            remark NVARCHAR(255) NULL,
            duration_minutes INT NOT NULL CONSTRAINT CK_M2_order_duration CHECK (duration_minutes > 0),
            service_address NVARCHAR(200) NOT NULL,
            service_latitude DECIMAL(10,7) NULL,
            service_longitude DECIMAL(10,7) NULL,
            allowed_radius_m INT NULL,
            order_channel NVARCHAR(20) NOT NULL,
            confirm_status NVARCHAR(10) NOT NULL CONSTRAINT DF_M2_order_confirm DEFAULT N'未确认',
            CONSTRAINT CK_M2_order_channel CHECK (order_channel IN (N'电话', N'家属端', N'社区代下单')),
            CONSTRAINT CK_M2_order_confirm CHECK (confirm_status IN (N'未确认', N'已确认')),
            CONSTRAINT CK_M2_order_complete_confirm CHECK (order_status <> N'已完成' OR confirm_status = N'已确认'),
            CONSTRAINT FK_M2_order_item FOREIGN KEY (service_id) REFERENCES dbo.service_item(service_id),
            CONSTRAINT CK_M2_order_status CHECK
                (order_status IN (N'待派单', N'待接单', N'待服务', N'服务中', N'已完成', N'已取消')),
            CONSTRAINT CK_M2_order_time CHECK (appointment_time >= order_time
                AND duration_minutes <= DATEDIFF_BIG(MINUTE, appointment_time,
                    CONVERT(DATETIME2(0), '9999-12-31T23:59:59'))),
            CONSTRAINT CK_M2_order_address CHECK (
                CHARINDEX(N'-', service_address COLLATE Latin1_General_100_BIN2) > 1
                AND LEN(TRIM(LEFT(service_address, CHARINDEX(N'-', (service_address + N'-') COLLATE Latin1_General_100_BIN2) - 1))) > 0
                AND LEN(TRIM(SUBSTRING(service_address, CHARINDEX(N'-', service_address COLLATE Latin1_General_100_BIN2) + 1, 200))) > 0
                AND DATALENGTH(LEFT(service_address, CHARINDEX(N'-', (service_address + N'-') COLLATE Latin1_General_100_BIN2) - 1)) =
                    DATALENGTH(TRIM(LEFT(service_address, CHARINDEX(N'-', (service_address + N'-') COLLATE Latin1_General_100_BIN2) - 1)))
            ),
            CONSTRAINT CK_M2_order_fence CHECK (
                (service_latitude IS NULL AND service_longitude IS NULL AND allowed_radius_m IS NULL)
                OR (service_latitude IS NOT NULL AND service_longitude IS NOT NULL
                    AND allowed_radius_m IS NOT NULL AND service_latitude BETWEEN -90 AND 90
                    AND service_longitude BETWEEN -180 AND 180 AND allowed_radius_m > 0)
            )
        );

    IF OBJECT_ID(N'dbo.dispatch_record', N'U') IS NULL
        CREATE TABLE dbo.dispatch_record (
            dispatch_id INT IDENTITY(1,1) CONSTRAINT PK_M2_dispatch_record PRIMARY KEY,
            order_id INT NOT NULL,
            caregiver_id INT NOT NULL,
            dispatch_time DATETIME2(0) NOT NULL CONSTRAINT DF_M2_dispatch_time DEFAULT SYSDATETIME(),
            accept_time DATETIME2(0) NULL,
            dispatch_status NVARCHAR(20) NOT NULL CONSTRAINT DF_M2_dispatch_status DEFAULT N'待接单',
            remark NVARCHAR(255) NULL,
            schedule_id INT NOT NULL,
            reassign_reason NVARCHAR(200) NULL,
            service_record NVARCHAR(500) NULL,
            CONSTRAINT FK_M2_dispatch_order FOREIGN KEY (order_id) REFERENCES dbo.service_order(order_id),
            CONSTRAINT CK_M2_dispatch_status CHECK
                (dispatch_status IN (N'待接单', N'已接单', N'已拒绝', N'已撤回')),
            CONSTRAINT CK_M2_dispatch_accept CHECK (
                (accept_time IS NOT NULL OR dispatch_status <> N'已接单')
                AND (accept_time IS NULL OR (accept_time >= dispatch_time
                    AND dispatch_status IN (N'已接单', N'已撤回')))
            )
        );

    IF (SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.service_item')) <> 9
        OR (SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.service_order')) <> 15
        OR (SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.dispatch_record')) <> 10
        OR OBJECT_ID(N'dbo.CK_M2_order_fence', N'C') IS NULL
        OR OBJECT_ID(N'dbo.FK_M2_dispatch_order', N'F') IS NULL
        OR OBJECT_ID(N'dbo.CK_M2_order_complete_confirm', N'C') IS NULL
        THROW 51001, N'发现其他版本的建表定义。请在新测试库部署，或由整合负责人先迁移旧表。', 1;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.dispatch_record')
                   AND name = N'UX_M2_dispatch_active_order')
        CREATE UNIQUE INDEX UX_M2_dispatch_active_order ON dbo.dispatch_record(order_id)
            WHERE dispatch_status <> N'已拒绝' AND dispatch_status <> N'已撤回';

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.dispatch_record')
                   AND name = N'IX_M2_dispatch_caregiver')
        CREATE INDEX IX_M2_dispatch_caregiver ON dbo.dispatch_record(caregiver_id, dispatch_time) INCLUDE (dispatch_status, order_id, schedule_id);
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.service_item') AND name = N'IX_M2_item_type_status')
        CREATE INDEX IX_M2_item_type_status ON dbo.service_item(service_type, status) INCLUDE (service_name, price, duration, charge_unit, is_subsidizable);
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.service_order') AND name = N'IX_M2_order_elder_time')
        CREATE INDEX IX_M2_order_elder_time ON dbo.service_order(elder_id, order_time) INCLUDE (order_status, total_amount);
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.service_order') AND name = N'IX_M2_order_status_appointment')
        CREATE INDEX IX_M2_order_status_appointment ON dbo.service_order(order_status, appointment_time);
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.dispatch_record') AND name = N'IX_M2_dispatch_order_history')
        CREATE INDEX IX_M2_dispatch_order_history ON dbo.dispatch_record(order_id, dispatch_time);
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.dispatch_record') AND name = N'IX_M2_dispatch_schedule_status')
        CREATE INDEX IX_M2_dispatch_schedule_status ON dbo.dispatch_record(schedule_id, dispatch_status) INCLUDE (order_id, caregiver_id);
    COMMIT;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    THROW;
END CATCH;
