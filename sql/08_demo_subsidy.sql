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
       visit.CheckOutAt, community.District,
       CONVERT(date, DATEADD(hour, 8, visit.CheckOutAt)) AS ServiceDate
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
    SELECT DISTINCT visit.District, visit.ServiceTypeId, service.Name
    FROM #DemoSubsidyVisits visit JOIN dbo.ServiceType service ON service.ServiceTypeId = visit.ServiceTypeId
)
INSERT dbo.SubsidyPolicy (PolicyName, District, ServiceTypeId, ValidFrom, ValidThrough, HourlyRate, MaxPerOrder)
SELECT LEFT(CONCAT(N'演示补贴政策 ', pairs.Name), 100), pairs.District, pairs.ServiceTypeId,
       '20200101', '20991231', 30.00, 80.00
FROM pairs
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.SubsidyPolicy existing WITH (UPDLOCK, HOLDLOCK)
    WHERE existing.District = pairs.District AND existing.ServiceTypeId = pairs.ServiceTypeId
      AND existing.ValidFrom <= '20991231' AND existing.ValidThrough >= '20200101'
);

COMMIT TRANSACTION;

DECLARE @ArchiveNo varchar(20), @CommunityId int, @ServiceTypeId int, @PeriodMonth date, @OrderIdsJson nvarchar(max);
DECLARE @ClaimId int, @Creator int, @Street int, @Civil int, @District nvarchar(80), @DemoNumber int = 0;

DECLARE demo_claims CURSOR LOCAL FAST_FORWARD FOR
    SELECT visit.ArchiveNo, visit.CommunityId, visit.ServiceTypeId, dates.PeriodMonth,
           CONCAT(N'[', STRING_AGG(CONVERT(nvarchar(max), visit.OrderId), N',') WITHIN GROUP (ORDER BY visit.OrderId), N']')
    FROM #DemoSubsidyVisits visit
    CROSS APPLY (VALUES (DATEFROMPARTS(YEAR(visit.ServiceDate), MONTH(visit.ServiceDate), 1))) dates(PeriodMonth)
    WHERE EXISTS (
        SELECT 1 FROM dbo.SubsidyPolicy policy
        WHERE policy.District = visit.District AND policy.ServiceTypeId = visit.ServiceTypeId
          AND visit.ServiceDate BETWEEN policy.ValidFrom AND policy.ValidThrough
    ) AND NOT EXISTS (
        SELECT 1 FROM dbo.SubsidyClaim existing
        WHERE existing.ArchiveNo = visit.ArchiveNo AND existing.ServiceTypeId = visit.ServiceTypeId
          AND existing.PeriodMonth = dates.PeriodMonth
    )
    GROUP BY visit.ArchiveNo, visit.CommunityId, visit.ServiceTypeId, dates.PeriodMonth
    ORDER BY visit.ArchiveNo, dates.PeriodMonth, visit.ServiceTypeId, visit.CommunityId;

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
            EXEC dbo.usp_ProgressSubsidyClaim @Street, @ClaimId, 'return', N'演示退回，请复核订单材料。';
        ELSE IF @DemoNumber % 5 IN (2, 3, 4)
        BEGIN
            EXEC dbo.usp_ProgressSubsidyClaim @Street, @ClaimId, 'approve', N'演示街道审核通过';
            IF @Civil IS NOT NULL AND @DemoNumber % 5 IN (3, 4)
                EXEC dbo.usp_ProgressSubsidyClaim @Civil, @ClaimId, 'approve', N'演示民政审核通过';
            IF @Civil IS NOT NULL AND @DemoNumber % 5 = 4
                EXEC dbo.usp_ProgressSubsidyClaim @Civil, @ClaimId, 'pay', N'演示已拨付';
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
           CONCAT(N'演示抽查整改 ', OrderId) AS Finding
    FROM first_visits WHERE WorkerVisitNumber = 1
    ORDER BY OrderId
)
SELECT * INTO #DemoInspections FROM inspections;

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
    Status, InspectedAt, Correction, CorrectedAt, ClosedAt, ChangedBy
)
SELECT sample.OrderId, sample.WorkerId, sample.District, inspector.UserId, 45 + (sample.Position % 12),
       sample.Finding, restriction.RestrictionId,
       CASE WHEN sample.Position < 18 THEN 'CLOSED' WHEN sample.Position = 18 THEN 'CORRECTED' ELSE 'OPEN' END,
       DATEADD(hour, 1, sample.CheckOutAt),
       CASE WHEN sample.Position <= 18 THEN N'已按抽查要求复核服务记录' END,
       CASE WHEN sample.Position <= 18 THEN DATEADD(hour, 2, sample.CheckOutAt) END,
       CASE WHEN sample.Position < 18 THEN DATEADD(hour, 3, sample.CheckOutAt) END,
       inspector.UserId
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
