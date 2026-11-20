USE [KanglaoCourse];
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
GO

SET XACT_ABORT ON;
SET NOCOUNT ON;

SELECT visit.OrderId, visit.ArchiveNo, visit.ServiceTypeId, visit.CommunityId, visit.WorkerId,
       visit.CheckOutAt, community.District, visit.SubsidyCategory, visit.SubsidyAbilityLevel
INTO #DemoSubsidyVisits
FROM dbo.v_SubsidyEligibleOrder visit
JOIN dbo.ServiceOrder orders ON orders.OrderId = visit.OrderId
JOIN dbo.Community community ON community.CommunityId = visit.CommunityId
JOIN dbo.ElderArchive elder ON elder.ArchiveNo = visit.ArchiveNo
WHERE orders.OrderNo LIKE 'DEMO-ORDER-%'
  AND visit.ArchiveNo BETWEEN 'E0001' AND 'E0020'
  AND elder.IdNumber LIKE '000000%';

IF NOT EXISTS (SELECT 1 FROM #DemoSubsidyVisits)
    THROW 51820, N'请先执行 06_demo_services.sql 生成可核算的模拟订单。', 1;

BEGIN TRANSACTION;

WITH pairs AS (
    SELECT DISTINCT visit.District, visit.ServiceTypeId, service.Name, basis.Category, basis.AbilityLevel, basis.Rate
    FROM #DemoSubsidyVisits visit JOIN dbo.ServiceType service ON service.ServiceTypeId = visit.ServiceTypeId
    CROSS APPLY (VALUES ('ANY',N'通用',30.00), ('LOW_INCOME',N'重度失能',45.00)) basis(Category, AbilityLevel, Rate)
    WHERE basis.Category = 'ANY'
       OR (basis.Category = visit.SubsidyCategory AND basis.AbilityLevel = visit.SubsidyAbilityLevel)
)
INSERT dbo.SubsidyPolicy (PolicyName, District, ServiceTypeId, ValidFrom, ValidThrough, HourlyRate, MaxPerOrder,
                          BeneficiaryCategory, AbilityLevel)
SELECT LEFT(CONCAT(IIF(pairs.Category = 'ANY', N'居家养老服务补贴｜', N'低保重度失能上门照护补贴｜'), pairs.Name), 100),
       pairs.District, pairs.ServiceTypeId, '20200101', '20991231', pairs.Rate, 80.00, pairs.Category, pairs.AbilityLevel
FROM pairs
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.SubsidyPolicy existing WITH (UPDLOCK, HOLDLOCK)
    WHERE existing.District = pairs.District AND existing.ServiceTypeId = pairs.ServiceTypeId
      AND existing.BeneficiaryCategory = pairs.Category AND existing.AbilityLevel = pairs.AbilityLevel
      AND existing.ValidFrom <= '20991231' AND existing.ValidThrough >= '20200101'
);

UPDATE policy SET PolicyName=LEFT(CONCAT(IIF(policy.BeneficiaryCategory='ANY',
    N'居家养老服务补贴｜',N'低保重度失能上门照护补贴｜'),service.Name),100)
FROM dbo.SubsidyPolicy policy JOIN dbo.ServiceType service ON service.ServiceTypeId=policy.ServiceTypeId
WHERE policy.ValidFrom='20200101' AND policy.MaxPerOrder=80
  AND (policy.PolicyName LIKE N'演示通用补贴 %' OR policy.PolicyName LIKE N'演示低保重度补贴 %'
       OR policy.PolicyName LIKE N'演示补贴政策 %')
  AND EXISTS (SELECT 1 FROM #DemoSubsidyVisits visit WHERE visit.District=policy.District AND visit.ServiceTypeId=policy.ServiceTypeId);

COMMIT TRANSACTION;

DECLARE @ArchiveNo varchar(20), @CommunityId int, @ServiceTypeId int, @PeriodMonth date, @OrderIdsJson nvarchar(max);
DECLARE @ClaimId int, @Creator int, @Street int, @Civil int, @District nvarchar(80), @DemoNumber int = 0;

DECLARE demo_claims CURSOR LOCAL FAST_FORWARD FOR
    SELECT visit.ArchiveNo, visit.CommunityId, visit.ServiceTypeId, visit.PeriodMonth,
           CONCAT(N'[', STRING_AGG(CONVERT(nvarchar(max), visit.OrderId), N',') WITHIN GROUP (ORDER BY visit.OrderId), N']')
    FROM dbo.v_SubsidyApplicableOrder visit JOIN #DemoSubsidyVisits demo ON demo.OrderId = visit.OrderId
    WHERE NOT EXISTS (
        SELECT 1 FROM dbo.SubsidyClaim existing
        WHERE existing.ArchiveNo = visit.ArchiveNo AND existing.ServiceTypeId = visit.ServiceTypeId
           AND existing.PeriodMonth = visit.PeriodMonth
    )
    GROUP BY visit.ArchiveNo, visit.CommunityId, visit.ServiceTypeId, visit.PeriodMonth
    ORDER BY visit.ArchiveNo, visit.PeriodMonth, visit.ServiceTypeId, visit.CommunityId;

OPEN demo_claims;
FETCH NEXT FROM demo_claims INTO @ArchiveNo, @CommunityId, @ServiceTypeId, @PeriodMonth, @OrderIdsJson;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @DemoNumber += 1;
    SET @Creator = (SELECT TOP (1) UserId FROM dbo.AppUser WHERE Active = 1 AND Role = 'community' AND CommunityId = @CommunityId ORDER BY UserId);
    IF @Creator IS NULL
        THROW 51821, N'请先初始化各社区的演示账号。', 1;
    EXEC dbo.usp_SubmitSubsidyClaim @Creator, @ArchiveNo, @CommunityId, @ServiceTypeId, @PeriodMonth, @OrderIdsJson;
    SELECT @ClaimId = ClaimId
    FROM dbo.SubsidyClaim WHERE ArchiveNo = @ArchiveNo AND ServiceTypeId = @ServiceTypeId AND PeriodMonth = @PeriodMonth;
    SET @District = (SELECT District FROM dbo.Community WHERE CommunityId = @CommunityId);
    SET @Street = (SELECT TOP (1) UserId FROM dbo.AppUser WHERE Active = 1 AND Role = 'street' AND District = @District ORDER BY UserId);
    SET @Civil = (SELECT TOP (1) UserId FROM dbo.AppUser WHERE Active = 1 AND Role = 'civil' AND District = @District ORDER BY UserId);

    IF @Street IS NOT NULL
    BEGIN
        IF @DemoNumber % 5 = 0
            EXEC dbo.usp_ProgressSubsidyClaim @Street, @ClaimId, 'return', N'请补充服务记录中的上门内容后重新提交。';
        ELSE IF @DemoNumber % 5 IN (2, 3, 4)
        BEGIN
            EXEC dbo.usp_ProgressSubsidyClaim @Street, @ClaimId, 'approve', N'核对订单、工时和签字记录，街道审核通过。';
            IF @Civil IS NOT NULL AND @DemoNumber % 5 IN (3, 4)
                EXEC dbo.usp_ProgressSubsidyClaim @Civil, @ClaimId, 'approve', N'核算金额符合该月适用政策。';
            IF @Civil IS NOT NULL AND @DemoNumber % 5 = 4
                EXEC dbo.usp_ProgressSubsidyClaim @Civil, @ClaimId, 'pay', N'已登记本期模拟拨付。';
        END;
    END;
    FETCH NEXT FROM demo_claims INTO @ArchiveNo, @CommunityId, @ServiceTypeId, @PeriodMonth, @OrderIdsJson;
END;
CLOSE demo_claims;
DEALLOCATE demo_claims;

BEGIN TRANSACTION;

WITH first_visits AS (
    SELECT visit.OrderId, visit.WorkerId, visit.District, visit.CheckOutAt,
           ROW_NUMBER() OVER (PARTITION BY visit.WorkerId ORDER BY visit.OrderId) AS WorkerVisitNumber
    FROM #DemoSubsidyVisits visit
), inspections AS (
    SELECT TOP (20) OrderId, WorkerId, District, CheckOutAt,
           ROW_NUMBER() OVER (ORDER BY OrderId) AS Position,
           CONCAT(N'演示抽查整改 ',OrderId) AS LegacyFinding,
           CONCAT(N'订单 #',OrderId,N'：',CHOOSE(OrderId%3+1,N'服务记录缺少结束时的交接说明。',
                N'请补记家属回访情况，以便复查。',N'服务记录中已完成的项目填写不完整。')) AS Finding
    FROM first_visits WHERE WorkerVisitNumber = 1
    ORDER BY OrderId
)
SELECT * INTO #DemoInspections FROM inspections;

UPDATE restriction SET Reason=sample.Finding
FROM dbo.WorkerRestriction restriction JOIN #DemoInspections sample
    ON sample.WorkerId=restriction.WorkerId AND sample.LegacyFinding=restriction.Reason;
UPDATE inspection SET Finding=sample.Finding
FROM dbo.ServiceInspection inspection JOIN #DemoInspections sample
    ON sample.OrderId=inspection.OrderId AND sample.WorkerId=inspection.WorkerId AND sample.LegacyFinding=inspection.Finding;

INSERT dbo.WorkerRestriction (WorkerId, Reason, CreatedAt, ResolvedAt)
SELECT sample.WorkerId, sample.Finding, DATEADD(hour, 1, sample.CheckOutAt),
       CASE WHEN sample.Position < 18 THEN DATEADD(hour, 3, sample.CheckOutAt) END
FROM #DemoInspections sample
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.WorkerRestriction restriction
    WHERE restriction.WorkerId = sample.WorkerId AND restriction.Reason = sample.Finding
);

INSERT dbo.ServiceInspection (
    OrderId, WorkerId, ReviewDistrict, InspectorId, Score, Finding, RestrictionId,
    Status, InspectedAt, Correction, CorrectedAt, ClosedAt, ChangedBy, InspectionMethod, IssueTag, CorrectionRequirement
)
SELECT sample.OrderId, sample.WorkerId, sample.District, inspector.UserId, 45 + (sample.Position % 12),
       sample.Finding, restriction.RestrictionId,
       CASE WHEN sample.Position < 18 THEN 'CLOSED' WHEN sample.Position = 18 THEN 'CORRECTED' ELSE 'OPEN' END,
       DATEADD(hour, 1, sample.CheckOutAt),
       CASE WHEN sample.Position <= 18 THEN N'已按抽查要求复核服务记录' END,
       CASE WHEN sample.Position <= 18 THEN DATEADD(hour, 2, sample.CheckOutAt) END,
       CASE WHEN sample.Position < 18 THEN DATEADD(hour, 3, sample.CheckOutAt) END,
       inspector.UserId, IIF(sample.Position % 2 = 0,'PHONE','VISIT'), N'服务记录', N'核对服务记录并提交整改说明'
FROM #DemoInspections sample
JOIN dbo.WorkerRestriction restriction ON restriction.WorkerId = sample.WorkerId AND restriction.Reason = sample.Finding
OUTER APPLY (
    SELECT TOP (1) UserId FROM dbo.AppUser WHERE Active = 1 AND Role = 'civil' AND District = sample.District ORDER BY UserId
) inspector
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.ServiceInspection existing WHERE existing.OrderId = sample.OrderId AND existing.Finding = sample.Finding
);

COMMIT TRANSACTION;

DROP TABLE #DemoInspections;
DROP TABLE #DemoSubsidyVisits;
