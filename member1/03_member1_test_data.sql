/*
社区居家养老智慧服务平台
成员1测试数据脚本
执行前提：已在 Member1_Standalone_Test 数据库中执行 01_member1_tables.sql
预计插入：5条机构、20条老人档案、30条能力评估、20条照护计划。
care_plan_item 暂不插入：service_id 需要使用成员2 service_item 表中的真实编号，待整合测试时再补。
以下姓名、身份证号、电话和地址均为虚构测试数据。
脚本可重复执行，不会重复插入相同测试记录。
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    -- 一、公共服务机构：插入5条虚构测试数据
    INSERT INTO dbo.service_org
        (org_name, contact_person, contact_phone, org_address, service_area, org_status, remark)
    SELECT v.org_name, v.contact_person, v.contact_phone, v.org_address, v.service_area, v.org_status, v.remark
    FROM (VALUES
        (N'阳光社区养老服务中心',N'张老师','13800000001',N'阳光社区服务街道1号',N'阳光社区',N'正常',N'虚构测试数据'),
        (N'幸福居家养老服务站',N'李老师','13800000002',N'幸福路88号',N'幸福社区',N'正常',N'虚构测试数据'),
        (N'康宁护理服务中心',N'王老师','13800000003',N'康宁大道16号',N'康宁社区、安宁社区',N'停用',N'虚构测试数据'),
        (N'春晖养老服务中心',N'赵老师','13800000004',N'春晖路26号',N'春晖社区',N'正常',N'虚构测试数据'),
        (N'怡康社区服务站',N'刘老师','13800000005',N'怡康街道9号',N'怡康社区',N'正常',N'虚构测试数据')
    ) AS v(org_name,contact_person,contact_phone,org_address,service_area,org_status,remark)
    WHERE NOT EXISTS
    (
        SELECT 1 FROM dbo.service_org t
        WHERE t.org_name=v.org_name AND t.org_address=v.org_address
    );

    -- 二、老人档案：插入20条虚构测试数据
    ;WITH N AS
    (
        SELECT n FROM (VALUES
        (1),(2),(3),(4),(5),(6),(7),(8),(9),(10),
        (11),(12),(13),(14),(15),(16),(17),(18),(19),(20)
        ) x(n)
    ),
    E AS
    (
        SELECT
            n,
            CONCAT(N'测试老人',RIGHT(CONCAT('0',n),2)) AS elder_name,
            CONCAT('110101',1940+(n*3)%23,'06',RIGHT(CONCAT('0',(n%27)+1),2),RIGHT(CONCAT('00',n),3),'X') AS id_card_no,
            DATEFROMPARTS(1940+(n*3)%23,6,(n%27)+1) AS birth_date,
            CONCAT(CASE (n-1)%5 WHEN 0 THEN N'阳光社区' WHEN 1 THEN N'幸福社区' WHEN 2 THEN N'康宁社区' WHEN 3 THEN N'春晖社区' ELSE N'怡康社区' END,
                   n+1,N'号楼',n%6+1,N'单元') AS address,
            CASE (n-1)%5 WHEN 0 THEN N'阳光社区' WHEN 1 THEN N'幸福社区' WHEN 2 THEN N'康宁社区' WHEN 3 THEN N'春晖社区' ELSE N'怡康社区' END AS community_name,
            CASE WHEN n IN (4,9,15) THEN NULL ELSE CONCAT(N'监护人',RIGHT(CONCAT('0',n),2)) END AS guardian_name,
            CASE WHEN n IN (4,9,15) THEN NULL ELSE CONCAT('1390000',RIGHT(CONCAT('000',n),4)) END AS guardian_phone,
            CASE WHEN n IN (1,5,8,12,17) THEN 1 ELSE 0 END AS is_living_alone,
            CASE WHEN n IN (2,3,6,8,11,14,18) THEN 1 ELSE 0 END AS is_disabled,
            CASE WHEN n IN (3,7,13,19) THEN 1 ELSE 0 END AS is_low_income,
            CASE WHEN n=20 THEN N'迁出' WHEN n=19 THEN N'注销' ELSE N'正常' END AS archive_status
        FROM N
    )
    INSERT INTO dbo.elder_profile
        (elder_name,id_card_no,birth_date,address,community_name,guardian_name,guardian_phone,
         is_living_alone,is_disabled,is_low_income,archive_status)
    SELECT elder_name,id_card_no,birth_date,address,community_name,guardian_name,guardian_phone,
           is_living_alone,is_disabled,is_low_income,archive_status
    FROM E
    WHERE NOT EXISTS
    (
        SELECT 1 FROM dbo.elder_profile t WHERE t.id_card_no=E.id_card_no
    );

    -- 三、能力评估：20位老人共30条记录，前10位老人各有两次评估
    ;WITH N AS
    (
        SELECT n FROM (VALUES
        (1),(2),(3),(4),(5),(6),(7),(8),(9),(10),
        (11),(12),(13),(14),(15),(16),(17),(18),(19),(20)
        ) x(n)
    ),
    A AS
    (
        SELECT N.n, V.assess_no
        FROM N
        CROSS JOIN (VALUES (1),(2)) V(assess_no)
        WHERE N.n<=10 OR V.assess_no=1
    ),
    D AS
    (
        SELECT
            CONCAT(N'测试老人',RIGHT(CONCAT('0',A.n),2)) AS elder_name,
            CASE WHEN A.assess_no=1 THEN N'ADL'
                 WHEN A.n%2=0 THEN N'简易智能状态' ELSE N'ADL' END AS scale_type,
            CASE WHEN A.assess_no=1 THEN 90-(A.n%4)*10 ELSE 70+(A.n%4)*5 END AS score,
            CASE (A.n+A.assess_no)%4
                 WHEN 0 THEN N'能力完好' WHEN 1 THEN N'轻度失能'
                 WHEN 2 THEN N'中度失能' ELSE N'重度失能' END AS ability_level,
            CONCAT(N'评估员',A.n%4+1) AS assessor_name,
            CASE WHEN A.assess_no=1 THEN CONVERT(date,'2025-10-15')
                 WHEN A.n%3=0 THEN CONVERT(date,'2026-01-10')
                 ELSE CONVERT(date,'2026-09-10') END AS assessment_date,
            CASE WHEN A.assess_no=1 THEN CONVERT(date,'2026-04-15')
                 WHEN A.n%3=0 THEN CONVERT(date,'2026-07-10')
                 ELSE CONVERT(date,'2027-03-10') END AS valid_until
        FROM A
    )
    INSERT INTO dbo.ability_assessment
        (elder_id,scale_type,score,ability_level,assessor_name,assessment_date,valid_until)
    SELECT e.elder_id,D.scale_type,D.score,D.ability_level,D.assessor_name,D.assessment_date,D.valid_until
    FROM D
    INNER JOIN dbo.elder_profile e ON e.elder_name=D.elder_name
    WHERE NOT EXISTS
    (
        SELECT 1 FROM dbo.ability_assessment t
        WHERE t.elder_id=e.elder_id
          AND t.scale_type=D.scale_type
          AND t.assessment_date=D.assessment_date
    );

    -- 四、照护计划：20条记录；同一老人可有历史计划
    -- responsible_caregiver_id 暂设为 NULL，待成员3护工表整合后再分配
    ;WITH P AS
    (
        SELECT n FROM (VALUES
        (1),(2),(3),(4),(5),(6),(7),(8),(9),(10),
        (11),(12),(13),(14),(15),(16),(17),(18),(19),(20)
        ) x(n)
    ),
    D AS
    (
        SELECT
            CASE WHEN n<=10 THEN (n+1)/2 ELSE n-5 END AS elder_no,
            CONCAT(N'测试照护计划',RIGHT(CONCAT('0',n),2)) AS service_package_name,
            CASE WHEN n%2=0 THEN N'每周3次' ELSE N'每周2次' END AS service_frequency,
            CASE WHEN n IN (1,3,5,7,9,13,18) THEN CONVERT(date,'2025-01-01')
                 WHEN n=8 THEN CONVERT(date,'2026-12-01')
                 WHEN n=10 THEN CONVERT(date,'2026-01-01')
                 WHEN n BETWEEN 11 AND 20 AND n%5=0 THEN CONVERT(date,'2026-12-01')
                 WHEN n BETWEEN 11 AND 20 THEN CONVERT(date,'2026-01-01')
                 ELSE CONVERT(date,'2026-02-01') END AS start_date,
            CASE WHEN n IN (1,3,5,7,9,13,18) THEN CONVERT(date,'2025-12-31')
                 WHEN n=8 OR (n BETWEEN 11 AND 20 AND n%5=0) THEN CONVERT(date,'2027-05-31')
                 ELSE CONVERT(date,'2026-12-31') END AS end_date,
            CASE n
                 WHEN 1 THEN N'已结束' WHEN 2 THEN N'生效'
                 WHEN 3 THEN N'已结束' WHEN 4 THEN N'暂停'
                 WHEN 5 THEN N'已结束' WHEN 6 THEN N'生效'
                 WHEN 7 THEN N'已结束' WHEN 8 THEN N'待生效'
                 WHEN 9 THEN N'已取消' WHEN 10 THEN N'生效'
                 WHEN 11 THEN N'生效' WHEN 12 THEN N'暂停'
                 WHEN 13 THEN N'已结束' WHEN 14 THEN N'生效'
                 WHEN 15 THEN N'待生效' WHEN 16 THEN N'生效'
                 WHEN 17 THEN N'暂停' WHEN 18 THEN N'已结束'
                 WHEN 19 THEN N'生效' ELSE N'待生效' END AS plan_status
        FROM P
    )
    INSERT INTO dbo.care_plan
        (elder_id,service_package_name,service_frequency,start_date,end_date,responsible_caregiver_id,plan_status)
    SELECT e.elder_id,D.service_package_name,D.service_frequency,D.start_date,D.end_date,NULL,D.plan_status
    FROM D
    INNER JOIN dbo.elder_profile e
        ON e.elder_name=CONCAT(N'测试老人',RIGHT(CONCAT('0',D.elder_no),2))
    WHERE NOT EXISTS
    (
        SELECT 1 FROM dbo.care_plan t
        WHERE t.elder_id=e.elder_id
          AND t.service_package_name=D.service_package_name
          AND t.start_date=D.start_date
    );

    COMMIT TRANSACTION;
    PRINT N'成员1测试数据插入完成。';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
    PRINT N'测试数据插入失败，事务已回滚。';
    THROW;
END CATCH;
GO

-- 五、检查五张表中的数据数量
SELECT N'service_org' AS table_name,COUNT(*) AS row_count FROM dbo.service_org
UNION ALL SELECT N'elder_profile',COUNT(*) FROM dbo.elder_profile
UNION ALL SELECT N'ability_assessment',COUNT(*) FROM dbo.ability_assessment
UNION ALL SELECT N'care_plan',COUNT(*) FROM dbo.care_plan
UNION ALL SELECT N'care_plan_item',COUNT(*) FROM dbo.care_plan_item;
GO

-- 六、检查每位老人对应的评估次数和照护计划数
SELECT e.elder_id,e.elder_name,
       COUNT(DISTINCT a.assessment_id) AS assessment_count,
       COUNT(DISTINCT p.plan_id) AS care_plan_count
FROM dbo.elder_profile e
LEFT JOIN dbo.ability_assessment a ON a.elder_id=e.elder_id
LEFT JOIN dbo.care_plan p ON p.elder_id=e.elder_id
GROUP BY e.elder_id,e.elder_name
ORDER BY e.elder_id;
GO

-- 七、查看每位老人最新一次评估及其有效期
;WITH LatestAssessment AS
(
    SELECT a.*,
           ROW_NUMBER() OVER(PARTITION BY a.elder_id ORDER BY a.assessment_date DESC,a.assessment_id DESC) AS rn
    FROM dbo.ability_assessment a
)
SELECT e.elder_id,e.elder_name,la.ability_level,la.assessment_date,la.valid_until,
       CASE WHEN la.valid_until<CONVERT(date,GETDATE()) THEN N'已过期' ELSE N'有效' END AS assessment_validity
FROM dbo.elder_profile e
LEFT JOIN LatestAssessment la ON la.elder_id=e.elder_id AND la.rn=1
ORDER BY e.elder_id;
GO
