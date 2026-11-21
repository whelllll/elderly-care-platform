-- 第一批数据导入入口：先执行01建表，再单独执行本文件。
-- 只初始化service_item，不依赖老人、护工、排班、账号或成员5接口，不创建订单/派单。
-- 与03_member2_test_data.sql使用相同的20个项目标识和业务键，重复执行不更新已有项目。
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
IF DB_ID() <= 4 THROW 51210, N'请先选择专用用户测试数据库。', 1;
IF OBJECT_ID(N'dbo.service_item', N'U') IS NULL
    THROW 51210, N'缺少service_item，请先执行01_member2_tables.sql。', 1;

DECLARE @own_transaction BIT = IIF(@@TRANCOUNT = 0, 1, 0), @inserted INT;
BEGIN TRY
    IF @own_transaction = 1 BEGIN TRAN;
    -- 与完整03种子脚本共用事务锁，避免两种入口并发重复初始化。
    DECLARE @lock_result INT;
    EXEC @lock_result = sys.sp_getapplock @Resource = N'M2.OrderAction.v1',
         @LockMode = N'Exclusive', @LockOwner = N'Transaction', @LockTimeout = 10000;
    IF @lock_result < 0 THROW 51102, N'服务项目初始化锁获取失败，请重试。', 1;

    DECLARE @items TABLE (seq INT PRIMARY KEY, service_name NVARCHAR(50), service_type NVARCHAR(30),
                          price DECIMAL(10,2), duration INT);
    INSERT @items VALUES
        (1,N'上门保洁',N'家政',80,30), (2,N'陪同就医',N'陪诊',150,180),
        (3,N'上门做饭',N'助餐',60,60), (4,N'助浴服务',N'助浴',100,90),
        (5,N'上门擦浴',N'助浴',40,60), (6,N'生活采购',N'家政',45,60),
        (7,N'助行陪伴',N'康复护理',55,60), (8,N'家电清洁',N'家政',90,120),
        (9,N'居家整理',N'家政',70,90), (10,N'陪同取药',N'陪诊',35,45),
        (11,N'康复陪练',N'康复护理',120,90), (12,N'关节活动训练',N'康复护理',35,60),
        (13,N'预约挂号协助',N'陪诊',30,30), (14,N'衣物洗护',N'家政',65,90),
        (15,N'步态训练',N'康复护理',45,60), (16,N'辅助洗头',N'助浴',50,45),
        (17,N'厨房整理',N'家政',60,60), (18,N'营养餐准备',N'助餐',40,45),
        (19,N'送餐上门',N'助餐',25,30), (20,N'旧物收纳',N'家政',75,90);

    INSERT dbo.service_item (service_name, service_type, price, duration, description, status, charge_unit, is_subsidizable)
    SELECT N'M2测试-' + i.service_name, i.service_type, i.price, i.duration,
           CONCAT(N'M2:v1:item:', RIGHT('00' + CONVERT(VARCHAR(2), i.seq), 2)),
           IIF(i.seq = 20, N'下架', N'上架'), IIF(i.seq IN (2,8,11), N'小时', N'次'), IIF(i.seq % 4 = 0, 0, 1)
    FROM @items AS i
    WHERE NOT EXISTS (SELECT 1 FROM dbo.service_item AS s WITH (UPDLOCK, HOLDLOCK)
        WHERE s.description = CONCAT(N'M2:v1:item:', RIGHT('00' + CONVERT(VARCHAR(2), i.seq), 2)));

    SET @inserted = @@ROWCOUNT;

    IF EXISTS (
        SELECT 1 FROM @items AS i
        WHERE (SELECT COUNT(*) FROM dbo.service_item AS s
            WHERE s.description = CONCAT(N'M2:v1:item:', RIGHT('00' + CONVERT(VARCHAR(2), i.seq), 2))) <> 1
    ) THROW 51202, N'已有重复的服务项目测试标识，请检查测试库。', 1;


    IF @own_transaction = 1 COMMIT;
    SELECT @inserted AS inserted_services, COUNT(*) AS initialized_services
    FROM @items AS i JOIN dbo.service_item AS s
      ON s.description = CONCAT(N'M2:v1:item:', RIGHT('00' + CONVERT(VARCHAR(2), i.seq), 2));
    -- 将实际ID与业务键交给成员3；不要假定service_id为1..20。
    SELECT s.service_id, s.service_name, s.service_type, s.price, s.duration, s.charge_unit,
           s.is_subsidizable, s.status, s.description
    FROM @items AS i JOIN dbo.service_item AS s
      ON s.description = CONCAT(N'M2:v1:item:', RIGHT('00' + CONVERT(VARCHAR(2), i.seq), 2))
    ORDER BY i.seq;
END TRY
BEGIN CATCH
    IF @own_transaction = 1 AND XACT_STATE() <> 0 ROLLBACK;
    THROW;
END CATCH;