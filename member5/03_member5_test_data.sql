-- =============================================================
-- 成员5 补贴核算与质量监管  |  03 测试数据（每表 20 条）
-- 前置：01 建表、02 外键、06 触发器与过程；成员1/2 的 service_item、
--       elder_profile、service_org、service_order 已导入测试数据；
--       成员4 的 sys_user 已建且已导入 user_id 1..5 测试账号
-- 说明：全部插入带 M5:v1:* 标记，可重复执行不产生重复行。
--       若可补贴订单不足 20 条，本脚本会补充测试订单（同样带标记）。
-- =============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @rows INT = 20,
        @cycle CHAR(7) = CONVERT(CHAR(7), SYSDATETIME(), 120),
        @i INT = 1,
        @policy_id INT, @app_id INT, @item_id INT, @insp_id INT,
        @order_id INT, @elder_id INT, @org_id INT, @caregiver_id INT,
        @amount DECIMAL(10,2), @subsidy DECIMAL(10,2), @hours DECIMAL(6,2),
        @score DECIMAL(4,1), @result NVARCHAR(8), @status NVARCHAR(10),
        @mark NVARCHAR(60);

-- ---------------- 0. 前置检查 ----------------
IF OBJECT_ID(N'dbo.subsidy_policy', N'U') IS NULL
    THROW 52200, N'请先执行 01_member5_tables.sql。', 1;
IF OBJECT_ID(N'dbo.service_item', N'U') IS NULL OR OBJECT_ID(N'dbo.elder_profile', N'U') IS NULL
   OR OBJECT_ID(N'dbo.service_order', N'U') IS NULL OR OBJECT_ID(N'dbo.service_org', N'U') IS NULL
    THROW 52201, N'缺少成员1/2 的父表：service_item、elder_profile、service_order、service_org。', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.service_item WHERE is_subsidizable = 1 AND status = N'上架')
    THROW 52202, N'service_item 中没有“上架且可补贴”的项目，无法生成补贴测试数据。', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.elder_profile)
    THROW 52203, N'elder_profile 为空，请先导入成员1 的老人测试数据。', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.service_org)
    THROW 52204, N'service_org 为空，请先导入成员1 的机构测试数据。', 1;

-- 成员4 的公共账号：审核人/抽查人/复查人外键依赖 user_id 2、3、4
IF OBJECT_ID(N'dbo.sys_user', N'U') IS NULL
    THROW 52205, N'缺少成员4 的公共账号表 sys_user，请先执行 member4/09_sys_user.sql。', 1;
IF (SELECT COUNT(*) FROM dbo.sys_user WHERE user_id IN (2, 3, 4)) < 3
    THROW 52206, N'sys_user 缺少 user_id 2/3/4 的测试账号，请先执行 member4/10_sys_user_test_data.sql。', 1;

BEGIN TRY
    BEGIN TRAN;

    -- ---------------- 1. 订单准备：凑足 20 条可补贴订单 ----------------
    DECLARE @orders TABLE (rn INT PRIMARY KEY, order_id INT NOT NULL, amount DECIMAL(10,2), minutes INT);
    INSERT @orders (rn, order_id, amount, minutes)
    SELECT ROW_NUMBER() OVER (ORDER BY o.order_id), o.order_id, o.total_amount, o.duration_minutes
    FROM dbo.service_order AS o
    JOIN dbo.service_item  AS si ON si.service_id = o.service_id
    WHERE si.is_subsidizable = 1;

    DECLARE @have INT = (SELECT COUNT(*) FROM @orders);
    IF @have < @rows
    BEGIN
        DECLARE @pad INT = 1;
        WHILE @have + @pad - 1 <= @rows
        BEGIN
            DECLARE @seed_mark NVARCHAR(60) = CONCAT(N'M5:v1:seed-order:', RIGHT(N'00' + CAST(@pad AS NVARCHAR(10)), 2));
            IF NOT EXISTS (SELECT 1 FROM dbo.service_order WHERE remark = @seed_mark)
            BEGIN
                INSERT dbo.service_order
                    (elder_id, service_id, order_time, appointment_time, order_status,
                     total_amount, duration_minutes, service_address, order_channel, confirm_status, remark)
                SELECT TOP (1) ep.elder_id, si.service_id,
                       DATEADD(DAY, -30 - @pad, SYSDATETIME()),
                       DATEADD(DAY, -20 - @pad, SYSDATETIME()),
                       N'已完成', si.price, si.duration, N'北京市海淀区测试路 1 号',
                       N'社区代下单', N'已确认', @seed_mark
                FROM dbo.elder_profile AS ep
                CROSS JOIN dbo.service_item AS si
                WHERE si.is_subsidizable = 1 AND si.status = N'上架'
                ORDER BY ep.elder_id, si.service_id;

                SET @pad += 1;
            END
            ELSE SET @pad += 1;

            IF @pad > 40 BREAK;
        END;

        DELETE @orders;
        INSERT @orders (rn, order_id, amount, minutes)
        SELECT ROW_NUMBER() OVER (ORDER BY o.order_id), o.order_id, o.total_amount, o.duration_minutes
        FROM dbo.service_order AS o
        JOIN dbo.service_item  AS si ON si.service_id = o.service_id
        WHERE si.is_subsidizable = 1;
    END;

    DECLARE @elders TABLE (rn INT PRIMARY KEY, elder_id INT NOT NULL);
    INSERT @elders (rn, elder_id)
    SELECT ROW_NUMBER() OVER (ORDER BY elder_id), elder_id FROM dbo.elder_profile;

    DECLARE @orgs TABLE (rn INT PRIMARY KEY, org_id INT NOT NULL);
    INSERT @orgs (rn, org_id)
    SELECT ROW_NUMBER() OVER (ORDER BY org_id), org_id FROM dbo.service_org;

    DECLARE @caregivers TABLE (rn INT PRIMARY KEY, caregiver_id INT NOT NULL);
    IF OBJECT_ID(N'dbo.caregiver', N'U') IS NOT NULL
        INSERT @caregivers (rn, caregiver_id)
        SELECT ROW_NUMBER() OVER (ORDER BY caregiver_id), caregiver_id FROM dbo.caregiver;

    DECLARE @works TABLE (rn INT PRIMARY KEY, work_id INT NOT NULL);
    IF OBJECT_ID(N'dbo.work_record', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.work_record', N'work_id') IS NOT NULL
        INSERT @works (rn, work_id)
        SELECT ROW_NUMBER() OVER (ORDER BY work_id), work_id FROM dbo.work_record;

    DECLARE @elder_cnt INT = (SELECT COUNT(*) FROM @elders),
            @org_cnt   INT = (SELECT COUNT(*) FROM @orgs),
            @cg_cnt    INT = (SELECT COUNT(*) FROM @caregivers),
            @work_cnt  INT = (SELECT COUNT(*) FROM @works),
            @order_cnt INT = (SELECT COUNT(*) FROM @orders);

    -- ---------------- 2. 政策 / 申报 / 明细 / 审核 / 抽查 / 整改 ----------------
    WHILE @i <= @rows
    BEGIN
        SET @mark = CONCAT(N'M5:v1:policy:', RIGHT(N'00' + CAST(@i AS NVARCHAR(10)), 2));

        IF NOT EXISTS (SELECT 1 FROM dbo.subsidy_policy WHERE doc_no = CONCAT(N'M5-TEST-', RIGHT(N'00' + CAST(@i AS NVARCHAR(10)), 2)))
        BEGIN
            -- 2.1 补贴政策
            INSERT dbo.subsidy_policy
                (policy_name, district_code, target_category, service_item_id, care_level,
                 subsidy_mode, subsidy_standard, subsidy_ratio, per_capita_limit,
                 settle_cycle, effective_date, expire_date, doc_no, policy_status, remark)
            SELECT N'M5 测试补贴政策-' + RIGHT(N'00' + CAST(@i AS NVARCHAR(10)), 2),
                   CONCAT(N'1101', RIGHT(N'0' + CAST((@i % 8) + 1 AS NVARCHAR(2)), 2)),
                   CASE @i % 5 WHEN 1 THEN N'低保' WHEN 2 THEN N'失能' WHEN 3 THEN N'高龄'
                               WHEN 4 THEN N'重点优抚' ELSE N'普通' END,
                   si.service_id,
                   CASE WHEN @i % 3 = 0 THEN N'重度失能' WHEN @i % 3 = 1 THEN N'中度失能' ELSE NULL END,
                   CASE @i % 3 WHEN 1 THEN N'按比例' WHEN 2 THEN N'按次定额' ELSE N'按月定额' END,
                   CAST(20 + @i AS DECIMAL(10,2)),
                   CASE WHEN @i % 3 = 1 THEN CAST(0.8000 AS DECIMAL(5,4)) ELSE NULL END,
                   500.00, N'月', '2026-01-01', '2026-12-31',
                   CONCAT(N'M5-TEST-', RIGHT(N'00' + CAST(@i AS NVARCHAR(10)), 2)),
                   N'生效', @mark
            FROM (SELECT TOP (1) service_id FROM dbo.service_item
                   WHERE is_subsidizable = 1 AND status = N'上架'
                   ORDER BY service_id OFFSET (@i - 1) % 6 ROWS FETCH NEXT 1 ROWS ONLY) AS si;

            SET @policy_id = SCOPE_IDENTITY();
        END
        ELSE
            SELECT @policy_id = policy_id FROM dbo.subsidy_policy
            WHERE doc_no = CONCAT(N'M5-TEST-', RIGHT(N'00' + CAST(@i AS NVARCHAR(10)), 2));

        -- 2.2 补贴申报（金额先置 0，明细录完由 usp_M5_RefreshTotals 回写）
        SET @elder_id = (SELECT elder_id FROM @elders WHERE rn = ((@i - 1) % @elder_cnt) + 1);

        IF NOT EXISTS (SELECT 1 FROM dbo.subsidy_application
                       WHERE elder_id = @elder_id AND policy_id = @policy_id AND settle_cycle = @cycle)
        BEGIN
            INSERT dbo.subsidy_application
                (elder_id, policy_id, settle_cycle, application_amount, self_pay_amount,
                 order_count, total_hours, apply_type, audit_status, pay_status,
                 audit_finish_time, pay_time, pay_voucher_no, create_by, remark)
            VALUES
                (@elder_id, @policy_id, @cycle, 0, 0, 0, 0, N'系统汇总',
                 CASE WHEN @i <= 5 THEN N'审核通过'
                      WHEN @i <= 10 THEN N'街道复审中'
                      WHEN @i <= 15 THEN N'待社区初审'
                      ELSE N'审核驳回' END,
                 CASE WHEN @i <= 3 THEN N'已拨付' WHEN @i = 4 THEN N'拨付中' ELSE N'未拨付' END,
                 CASE WHEN @i <= 5 OR @i > 15 THEN DATEADD(DAY, -(@i % 7), SYSDATETIME()) ELSE NULL END,
                 CASE WHEN @i <= 3 THEN DATEADD(DAY, -(@i % 3), SYSDATETIME()) ELSE NULL END,
                 CASE WHEN @i <= 3 THEN CONCAT(N'M5-PAY-', RIGHT(N'0000' + CAST(@i AS NVARCHAR(10)), 4)) ELSE NULL END,
                 N'社区管理员', CONCAT(@mark, N':app'));

            SET @app_id = SCOPE_IDENTITY();
        END
        ELSE
            SELECT @app_id = application_id FROM dbo.subsidy_application
            WHERE elder_id = @elder_id AND policy_id = @policy_id AND settle_cycle = @cycle;

        -- 2.3 申报明细（一单一报，20 条不同订单）
        SET @order_id = (SELECT order_id FROM @orders WHERE rn = ((@i - 1) % @order_cnt) + 1);
        SELECT @amount = amount, @hours = CAST(minutes AS DECIMAL(6,2)) / 60.0
        FROM @orders WHERE order_id = @order_id;

        IF NOT EXISTS (SELECT 1 FROM dbo.subsidy_application_item WHERE order_id = @order_id)
        BEGIN
            SET @subsidy = CAST(ROUND(@amount * 0.8, 2) AS DECIMAL(10,2));
            INSERT dbo.subsidy_application_item
                (application_id, order_id, work_id, service_amount, subsidy_amount,
                 self_pay_amount, valid_hours, verify_result, remark)
            VALUES
                (@app_id, @order_id,
                 CASE WHEN @i % 5 = 0 THEN NULL
                      ELSE (SELECT work_id FROM @works WHERE rn = ((@i - 1) % NULLIF(@work_cnt, 0)) + 1) END,
                 @amount, @subsidy, @amount - @subsidy,
                 CASE WHEN @i % 5 = 0 THEN NULL ELSE @hours END,
                 N'通过', CONCAT(@mark, N':item'));
        END;

        EXEC dbo.usp_M5_RefreshTotals @application_id = @app_id;

        -- 2.4 审核记录（每个申报 1 条，至少 20 条）
        -- 用户外键按成员4 已交付的 sys_user 测试账号取值：
        --   user_id 1 = SYS_ADMIN      2 = COMMUNITY_ADMIN（社区初审）
        --   user_id 3 = STREET_SUPERVISOR（街道复审/整改复查）
        --   user_id 4 = CIVIL_SUPERVISOR（民政抽查）  5 = ORG_MANAGER
        IF NOT EXISTS (SELECT 1 FROM dbo.subsidy_audit_log
                       WHERE application_id = @app_id AND audit_node = N'社区初审')
        BEGIN
            INSERT dbo.subsidy_audit_log
                (application_id, audit_node, auditor_id, auditor_org, audit_action,
                 audit_opinion, before_status, after_status, audit_time, client_ip)
            VALUES
                (@app_id, N'社区初审', 2, N'海淀区学院路社区',
                 CASE WHEN @i > 15 THEN N'驳回' ELSE N'通过' END,
                 CASE WHEN @i > 15 THEN N'证明材料不完整，请补充服务确认单。' ELSE N'材料齐全，同意上报。' END,
                 N'待社区初审',
                 CASE WHEN @i > 15 THEN N'审核驳回' WHEN @i <= 10 THEN N'街道复审中' ELSE N'待社区初审' END,
                 DATEADD(HOUR, -(@i * 3), SYSDATETIME()), N'10.10.1.' + CAST(@i AS NVARCHAR(3)));

            IF @i % 3 = 0
                INSERT dbo.subsidy_audit_log
                    (application_id, audit_node, auditor_id, auditor_org, audit_action,
                     audit_opinion, before_status, after_status, audit_time)
                VALUES
                    (@app_id, N'街道复审', 3, N'海淀区街道办', N'通过', N'复核无误。',
                     N'街道复审中', N'民政终审中', DATEADD(HOUR, -(@i * 2), SYSDATETIME()));
        END;

        -- 2.5 质量抽查（前 10 条查订单，后 10 条查护工）
        SET @mark = CONCAT(N'M5:v1:insp:', RIGHT(N'00' + CAST(@i AS NVARCHAR(10)), 2));
        IF NOT EXISTS (SELECT 1 FROM dbo.quality_inspection WHERE remark = @mark)
        BEGIN
            SET @score = CAST(95 - (@i * 2) AS DECIMAL(4,1));
            SET @result = CASE WHEN @score >= 85 THEN N'合格' WHEN @score >= 70 THEN N'基本合格' ELSE N'不合格' END;
            SET @caregiver_id = CASE WHEN @cg_cnt > 0
                                     THEN (SELECT caregiver_id FROM @caregivers WHERE rn = ((@i - 1) % @cg_cnt) + 1)
                                     ELSE NULL END;

            INSERT dbo.quality_inspection
                (object_type, order_id, caregiver_id, inspect_method, inspect_source,
                 inspect_time, inspector_id, inspector_org, score, authenticity,
                 problem_tags, inspect_result, rectify_flag, rectify_deadline, inspect_status, remark)
            VALUES
                (CASE WHEN @i <= 10 THEN N'订单' ELSE N'护工' END,
                 CASE WHEN @i <= 10 THEN @order_id ELSE NULL END,
                 CASE WHEN @i <= 10 THEN NULL ELSE @caregiver_id END,
                 CASE @i % 3 WHEN 1 THEN N'电话回访' WHEN 2 THEN N'上门核查' ELSE N'系统稽核' END,
                 CASE @i % 3 WHEN 1 THEN N'系统随机' WHEN 2 THEN N'投诉转办' ELSE N'专项整治' END,
                 DATEADD(DAY, -@i, SYSDATETIME()), 4, N'海淀区民政局监管科', @score,
                 CASE WHEN @score >= 85 THEN N'真实' WHEN @score >= 70 THEN N'部分真实' ELSE N'不真实' END,
                 CASE WHEN @score >= 85 THEN NULL WHEN @score >= 70 THEN N'服务记录不完整' ELSE N'服务时长不足,未按约上门' END,
                 @result,
                 CASE WHEN @result = N'不合格' THEN 'Y' ELSE 'N' END,
                 CASE WHEN @result = N'不合格' THEN DATEADD(DAY, 5, CAST(SYSDATETIME() AS DATE)) ELSE NULL END,
                 N'已完成', @mark);

            SET @insp_id = SCOPE_IDENTITY();
        END
        ELSE
            SELECT @insp_id = inspection_id FROM dbo.quality_inspection WHERE remark = @mark;

        -- 2.6 整改记录（每条抽查 1 条整改）
        SET @mark = CONCAT(N'M5:v1:rect:', RIGHT(N'00' + CAST(@i AS NVARCHAR(10)), 2));
        IF NOT EXISTS (SELECT 1 FROM dbo.rectification WHERE remark = @mark)
        BEGIN
            SET @status = CASE WHEN @i % 4 = 1 THEN N'待整改'
                               WHEN @i % 4 = 2 THEN N'整改中'
                               WHEN @i % 4 = 3 THEN N'复查通过'
                               ELSE N'复查不通过' END;
            SET @org_id = (SELECT org_id FROM @orgs WHERE rn = ((@i - 1) % @org_cnt) + 1);
            SET @caregiver_id = (SELECT caregiver_id FROM dbo.quality_inspection WHERE inspection_id = @insp_id);

            INSERT dbo.rectification
                (inspection_id, caregiver_id, org_id, problem_desc, rectify_requirement,
                 rectify_deadline, rectify_status, submit_time, review_time, reviewer_id,
                 review_result, restrict_flag, release_time, remark)
            VALUES
                (@insp_id, @caregiver_id, @org_id,
                 N'抽查发现服务记录与订单信息不一致。',
                 N'补全服务记录与家属确认单，必要时重新上门。',
                 DATEADD(DAY, -(@i % 6) + 5, CAST(SYSDATETIME() AS DATE)),
                 @status,
                 CASE WHEN @status <> N'待整改' THEN DATEADD(DAY, -(@i % 5), SYSDATETIME()) ELSE NULL END,
                 CASE WHEN @status IN (N'复查通过', N'复查不通过') THEN DATEADD(DAY, -(@i % 4), SYSDATETIME()) ELSE NULL END,
                 CASE WHEN @status IN (N'复查通过', N'复查不通过') THEN 3 ELSE NULL END,
                 CASE WHEN @status = N'复查通过' THEN N'通过'
                      WHEN @status = N'复查不通过' THEN N'不通过' ELSE NULL END,
                 CASE WHEN @status = N'复查通过' THEN 'N' ELSE 'Y' END,
                 CASE WHEN @status = N'复查通过' THEN DATEADD(DAY, -(@i % 4), SYSDATETIME()) ELSE NULL END,
                 @mark);
        END;

        SET @i += 1;
    END;

    COMMIT;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    THROW;
END CATCH;

-- ---------------- 3. 结果核对 ----------------
SELECT N'subsidy_policy' AS table_name, COUNT(*) AS row_count FROM dbo.subsidy_policy WHERE remark LIKE N'M5:v1:%'
UNION ALL SELECT N'subsidy_application', COUNT(*) FROM dbo.subsidy_application WHERE remark LIKE N'M5:v1:%'
UNION ALL SELECT N'subsidy_application_item', COUNT(*) FROM dbo.subsidy_application_item WHERE remark LIKE N'M5:v1:%'
UNION ALL SELECT N'subsidy_audit_log', COUNT(*) FROM dbo.subsidy_audit_log WHERE client_ip LIKE N'10.10.1.%'
UNION ALL SELECT N'quality_inspection', COUNT(*) FROM dbo.quality_inspection WHERE remark LIKE N'M5:v1:%'
UNION ALL SELECT N'rectification', COUNT(*) FROM dbo.rectification WHERE remark LIKE N'M5:v1:%';

PRINT N'成员5 测试数据导入完成（目标每表 20 条）。';
