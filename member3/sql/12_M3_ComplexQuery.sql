-- 成员3复杂查询：指定月份的各护工有效工时；连接护工、排班、工时三张关系表。
-- 只查询，不修改数据。月份为可替换演示参数，不是已有业务数据的假定。
SET NOCOUNT ON;
DECLARE @Month DATE='20300101';
IF @Month IS NULL OR @Month>='99991201'
 THROW 51312,N'月份不能为空且须早于9999年12月，以便构造次月上界。',1;
DECLARE @MonthStart DATE=DATEFROMPARTS(YEAR(@Month),MONTH(@Month),1);
DECLARE @NextMonthStart DATE=DATEADD(MONTH,1,@MonthStart);

-- 半开月份范围：不在WHERE对签到列套YEAR/MONTH，保留索引范围检索机会。
-- 仅返回该月有审核通过且分钟明确记录的护工；没有记录不人为生成零工时行。
-- 不连接资质表，避免多证书造成工时重复累计；不筛围栏结果，保留合法人工认可。
SELECT c.caregiver_id,
       c.caregiver_name,
       c.org_id,
       c.service_area,
       @MonthStart AS work_month,
       COUNT_BIG(*) AS approved_record_count,
       SUM(CONVERT(BIGINT,w.effective_minutes)) AS effective_minutes_total,
       CONVERT(DECIMAL(20,2),SUM(CONVERT(BIGINT,w.effective_minutes))/60.0) AS effective_hours_total
FROM dbo.caregiver AS c
INNER JOIN dbo.caregiver_schedule AS s ON s.caregiver_id=c.caregiver_id
INNER JOIN dbo.work_record AS w ON w.schedule_id=s.schedule_id
WHERE w.review_status=N'通过'
  AND w.effective_minutes IS NOT NULL
  AND w.check_in_time>=@MonthStart
  AND w.check_in_time<@NextMonthStart
GROUP BY c.caregiver_id,c.caregiver_name,c.org_id,c.service_area
ORDER BY effective_minutes_total DESC,c.caregiver_id;
