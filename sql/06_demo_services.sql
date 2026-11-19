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
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N'KanglaoCourse' OR OBJECT_ID('dbo.ServiceVisit', 'U') IS NULL
    THROW 51224, N'请先安装服务业务结构。', 1;

DECLARE @Now datetime2(0) = SYSUTCDATETIME();
DECLARE @Today date = CONVERT(date, DATEADD(hour, 8, @Now));
DECLARE @MonthStart date = DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1);
DECLARE @Demo TABLE (
    Seq int PRIMARY KEY, Suffix char(3) NOT NULL, ArchiveNo varchar(20) NOT NULL, CommunityId int NOT NULL,
    District nvarchar(40) NOT NULL, AbilityLevel nvarchar(20) NOT NULL, Address nvarchar(200) NOT NULL,
    Latitude decimal(9,6) NOT NULL, Longitude decimal(9,6) NOT NULL
);

;WITH NumberedArchive AS (
    SELECT ROW_NUMBER() OVER (ORDER BY e.ArchiveNo) AS Seq, e.ArchiveNo, e.CommunityId, c.District,
           COALESCE(a.AbilityLevel, N'轻度失能') AS AbilityLevel, e.Address,
           COALESCE(e.Latitude, c.Latitude) AS Latitude, COALESCE(e.Longitude, c.Longitude) AS Longitude
    FROM dbo.ElderArchive e JOIN dbo.Community c ON c.CommunityId = e.CommunityId
    LEFT JOIN dbo.v_CurrentAbilityAssessment a ON a.ArchiveNo = e.ArchiveNo
    WHERE e.ArchiveNo LIKE 'E[0-9][0-9][0-9][0-9]' AND e.ArchiveNo BETWEEN 'E0001' AND 'E0020'
)
INSERT @Demo SELECT Seq, RIGHT('000' + CONVERT(varchar(3), Seq), 3), ArchiveNo, CommunityId, District,
                    AbilityLevel, Address, Latitude, Longitude
FROM NumberedArchive;

IF (SELECT COUNT(*) FROM @Demo) <> 20
    THROW 51224, N'请先准备 E0001 至 E0020 的模拟档案。', 1;

BEGIN TRANSACTION;
EXEC dbo.usp_ServiceLock 'seed', N'services';

INSERT dbo.Agency(AgencyNo, Name, District)
SELECT CONCAT('DEMO-AGENCY-', d.Suffix), CONCAT(N'演示服务机构', d.Suffix), d.District
FROM @Demo d WHERE NOT EXISTS (SELECT 1 FROM dbo.Agency a WHERE a.AgencyNo = CONCAT('DEMO-AGENCY-', d.Suffix));

INSERT dbo.Worker(WorkerNo, AgencyId, Name, Grade, TrainingCompletedOn)
SELECT CONCAT('DEMO-WORKER-', d.Suffix), a.AgencyId, CONCAT(N'演示护工', d.Suffix), N'示例护理员',
       DATEADD(day, -d.Seq - 30, @Today)
FROM @Demo d JOIN dbo.Agency a ON a.AgencyNo = CONCAT('DEMO-AGENCY-', d.Suffix)
WHERE NOT EXISTS (SELECT 1 FROM dbo.Worker w WHERE w.WorkerNo = CONCAT('DEMO-WORKER-', d.Suffix));

UPDATE w SET TrainingCompletedOn = DATEADD(day, -d.Seq - 30, @Today)
FROM dbo.Worker w JOIN @Demo d ON w.WorkerNo = CONCAT('DEMO-WORKER-', d.Suffix)
WHERE w.TrainingCompletedOn IS NULL;

INSERT dbo.WorkerCommunity(WorkerId, CommunityId)
SELECT w.WorkerId, d.CommunityId FROM @Demo d JOIN dbo.Worker w ON w.WorkerNo = CONCAT('DEMO-WORKER-', d.Suffix)
WHERE NOT EXISTS (SELECT 1 FROM dbo.WorkerCommunity n WHERE n.WorkerId = w.WorkerId AND n.CommunityId = d.CommunityId);

INSERT dbo.ServiceType(Code, Name, Unit, Rate, StandardMinutes, Subsidizable, CategoryCode)
SELECT CONCAT('DEMO-SERVICE-', d.Suffix), CONCAT(categories.Label, N'（演示', d.Suffix, N'）'),
       IIF(d.Seq % 2 = 0, N'次', N'小时'), 40 + d.Seq, 60, 1, categories.CategoryCode
FROM @Demo d JOIN (VALUES (0,N'助餐','MEAL'),(1,N'助浴','BATH'),(2,N'陪诊','ESCORT'),
    (3,N'家政','HOUSEWORK'),(4,N'康复护理','REHAB')) categories(Kind, Label, CategoryCode)
ON categories.Kind = (d.Seq - 1) % 5
WHERE NOT EXISTS (SELECT 1 FROM dbo.ServiceType t WHERE t.Code = CONCAT('DEMO-SERVICE-', d.Suffix));

INSERT dbo.WorkerService(WorkerId, ServiceTypeId, CredentialNo, ValidFrom, ValidThrough, CredentialType, CredentialLevel)
SELECT w.WorkerId, t.ServiceTypeId, CONCAT(N'模拟证书-', d.Suffix), DATEADD(year, -1, @Today), DATEADD(year, 1, @Today),
       N'养老护理', N'演示初级'
FROM @Demo d JOIN dbo.Worker w ON w.WorkerNo = CONCAT('DEMO-WORKER-', d.Suffix)
JOIN dbo.ServiceType t ON t.Code = CONCAT('DEMO-SERVICE-', d.Suffix)
WHERE NOT EXISTS (SELECT 1 FROM dbo.WorkerService s WHERE s.WorkerId = w.WorkerId AND s.ServiceTypeId = t.ServiceTypeId);

INSERT dbo.CarePackage(Name, AbilityLevel)
SELECT CONCAT(N'演示照护包', d.Suffix), d.AbilityLevel FROM @Demo d
WHERE NOT EXISTS (SELECT 1 FROM dbo.CarePackage p WHERE p.Name = CONCAT(N'演示照护包', d.Suffix));

INSERT dbo.CarePackageService(PackageId, ServiceTypeId, VisitsPerWeek)
SELECT p.PackageId, t.ServiceTypeId, 2 FROM @Demo d
JOIN dbo.CarePackage p ON p.Name = CONCAT(N'演示照护包', d.Suffix)
JOIN dbo.ServiceType t ON t.Code = CONCAT('DEMO-SERVICE-', d.Suffix)
WHERE NOT EXISTS (SELECT 1 FROM dbo.CarePackageService ps WHERE ps.PackageId = p.PackageId AND ps.ServiceTypeId = t.ServiceTypeId);

INSERT dbo.CarePlan(PlanNo, ArchiveNo, PackageId, ResponsibleWorkerId, StartsOn, EndsOn, Status, ChangedReason)
SELECT CONCAT('DEMO-PLAN-', d.Suffix), d.ArchiveNo, p.PackageId, w.WorkerId,
       DATEADD(month, -3, @MonthStart), DATEADD(day, 90, @Today), 'ACTIVE', N'模拟照护计划'
FROM @Demo d JOIN dbo.CarePackage p ON p.Name = CONCAT(N'演示照护包', d.Suffix)
JOIN dbo.Worker w ON w.WorkerNo = CONCAT('DEMO-WORKER-', d.Suffix)
WHERE NOT EXISTS (SELECT 1 FROM dbo.CarePlan existing WHERE existing.PlanNo = CONCAT('DEMO-PLAN-', d.Suffix));

DECLARE @Scheduled TABLE (
    OrderNo varchar(30) PRIMARY KEY, ArchiveNo varchar(20), PlanId int, ServiceTypeId int, CommunityId int,
    WorkerId int, StartsAt datetime2(0), EndsAt datetime2(0), IsHistorical bit,
    Address nvarchar(200), Latitude decimal(9,6), Longitude decimal(9,6), Price decimal(12,2)
);

INSERT @Scheduled
SELECT CONCAT('DEMO-ORDER-', d.Suffix, '-', n.Scenario), d.ArchiveNo, p.PlanId, t.ServiceTypeId, d.CommunityId,
       w.WorkerId, times.StartsAt, DATEADD(hour, 1, times.StartsAt), IIF(n.Scenario < 3, 1, 0),
       d.Address, d.Latitude, d.Longitude, t.Rate
FROM @Demo d CROSS JOIN (VALUES (1),(2),(3)) n(Scenario)
JOIN dbo.CarePlan p ON p.PlanNo = CONCAT('DEMO-PLAN-', d.Suffix)
JOIN dbo.ServiceType t ON t.Code = CONCAT('DEMO-SERVICE-', d.Suffix)
JOIN dbo.Worker w ON w.WorkerNo = CONCAT('DEMO-WORKER-', d.Suffix)
CROSS APPLY (VALUES (CASE WHEN n.Scenario = 3 THEN DATEADD(hour, 4, @Now)
    ELSE DATEADD(hour, 1, CONVERT(datetime2(0), DATEADD(day, d.Seq, DATEADD(month, n.Scenario - 3, @MonthStart)))) END)) times(StartsAt);

-- 既有示例订单保留绝对时间。重复执行时重新读取该时刻，避免每天插入新排班。
UPDATE d SET StartsAt = o.AppointmentStart, EndsAt = o.AppointmentEnd
FROM @Scheduled d JOIN dbo.ServiceOrder o ON o.OrderNo = d.OrderNo;

INSERT dbo.WorkerShift(WorkerId, StartsAt, EndsAt, Capacity)
SELECT d.WorkerId, DATEADD(hour, -5, d.StartsAt), DATEADD(hour, IIF(d.IsHistorical = 1, 2, 36), d.EndsAt), 4
FROM @Scheduled d WHERE NOT EXISTS (
    SELECT 1 FROM dbo.WorkerShift s WHERE s.WorkerId = d.WorkerId AND s.StartsAt = DATEADD(hour, -5, d.StartsAt)
);

INSERT dbo.ServiceOrder(OrderNo, ArchiveNo, PlanId, ServiceTypeId, CommunityId, Status, Price,
       AppointmentStart, AppointmentEnd, Address, Latitude, Longitude, Channel, CreatedAt, DispatchDeadline)
SELECT OrderNo, ArchiveNo, PlanId, ServiceTypeId, CommunityId,
       CASE WHEN OrderNo IN ('DEMO-ORDER-004-2','DEMO-ORDER-005-2') THEN 'AWAITING_CONFIRMATION'
            WHEN IsHistorical=1 THEN 'COMPLETED'
            WHEN OrderNo IN ('DEMO-ORDER-006-3','DEMO-ORDER-007-3') THEN 'POOL'
            ELSE 'NEW' END, Price,
       StartsAt, EndsAt, Address, Latitude, Longitude, 'COMMUNITY',
       IIF(IsHistorical = 1, DATEADD(hour, -2, StartsAt), @Now), IIF(IsHistorical = 1, DATEADD(hour, -1, StartsAt), DATEADD(minute, 30, @Now))
FROM @Scheduled d WHERE NOT EXISTS (SELECT 1 FROM dbo.ServiceOrder o WHERE o.OrderNo = d.OrderNo);

INSERT dbo.ServiceDispatch(OrderId, WorkerId, ShiftId, OfferedAt, OfferExpiresAt, AcceptedAt, ClosedAt, CloseReason)
SELECT o.OrderId, d.WorkerId, s.ShiftId, DATEADD(hour, -2, d.StartsAt), DATEADD(minute, -90, d.StartsAt),
       DATEADD(minute, -110, d.StartsAt), d.EndsAt, N'服务完成'
FROM @Scheduled d JOIN dbo.ServiceOrder o ON o.OrderNo = d.OrderNo
JOIN dbo.WorkerShift s ON s.WorkerId = d.WorkerId AND s.StartsAt = DATEADD(hour, -5, d.StartsAt)
WHERE d.IsHistorical = 1 AND NOT EXISTS (SELECT 1 FROM dbo.ServiceDispatch x WHERE x.OrderId = o.OrderId);

INSERT dbo.ServiceVisit(OrderId, DispatchId, WorkerId, CheckInAt, CheckOutAt, InLatitude, InLongitude,
       OutLatitude, OutLongitude, InFence, OutFence, InShift, OutShift, ServiceRecord, WorkStatus,
       EffectiveMinutes, ReviewReason, ConfirmedAt, ConfirmedBy, ConfirmationText, ConfirmationHash, FeedbackScore, Feedback,
       SubsidyCategory, SubsidyAbilityLevel)
SELECT o.OrderId, x.DispatchId, x.WorkerId, d.StartsAt, d.EndsAt, d.Latitude, d.Longitude, d.Latitude,
       d.Longitude, 1, IIF(example.NeedsReview=1,0,1), 1, 1, N'模拟完成上门服务',
       IIF(example.NeedsReview=1,'REVIEW','VALID'), IIF(example.NeedsReview=1,NULL,60),
       IIF(example.NeedsReview=1,N'模拟签退超出服务围栏',NULL),
       IIF(example.IsSigned=1,DATEADD(minute,5,d.EndsAt),NULL), IIF(example.IsSigned=1,1,NULL),
       IIF(example.IsSigned=1,N'模拟家属电子签字',NULL),
       IIF(example.IsSigned=1,dbo.fn_ServiceConfirmationHash(
           o.OrderId,1,DATEADD(minute,5,d.EndsAt),N'模拟家属电子签字'),NULL),
        IIF(example.IsSigned=1,5,NULL), IIF(example.IsSigned=1,N'模拟评价',NULL),
        elder.SubsidyCategory, package.AbilityLevel
FROM @Scheduled d JOIN dbo.ServiceOrder o ON o.OrderNo = d.OrderNo
JOIN dbo.ElderArchive elder ON elder.ArchiveNo = o.ArchiveNo
JOIN dbo.CarePlan planRow ON planRow.PlanId = o.PlanId
JOIN dbo.CarePackage package ON package.PackageId = planRow.PackageId
JOIN dbo.ServiceDispatch x ON x.OrderId = o.OrderId AND x.CloseReason = N'服务完成'
CROSS APPLY (VALUES (
    IIF(d.OrderNo IN ('DEMO-ORDER-006-2','DEMO-ORDER-007-2'),1,0),
    IIF(o.Status='COMPLETED',1,0)
)) example(NeedsReview, IsSigned)
WHERE d.IsHistorical = 1 AND NOT EXISTS (SELECT 1 FROM dbo.ServiceVisit v WHERE v.OrderId = o.OrderId);

UPDATE v SET ConfirmationHash = dbo.fn_ServiceConfirmationHash(v.OrderId, v.ConfirmedBy, v.ConfirmedAt, v.ConfirmationText)
FROM dbo.ServiceVisit v JOIN dbo.ServiceOrder o ON o.OrderId = v.OrderId
JOIN @Scheduled d ON d.OrderNo = o.OrderNo AND d.IsHistorical = 1
WHERE v.ConfirmationHash IS NULL AND v.ConfirmedAt IS NOT NULL AND v.ConfirmedBy IS NOT NULL
  AND v.ConfirmationText IS NOT NULL;

UPDATE v SET ComplaintText = N'模拟投诉：请核实服务人员到场时间。',
    ComplainedAt = DATEADD(minute, 10, v.ConfirmedAt), ComplainedBy = v.ConfirmedBy,
    ComplaintResolution = IIF(o.OrderNo = 'DEMO-ORDER-002-1', N'社区已联系双方核实并反馈。', NULL),
    ComplaintResolvedAt = IIF(o.OrderNo = 'DEMO-ORDER-002-1', DATEADD(minute, 60, v.ConfirmedAt), NULL),
    ComplaintResolvedBy = IIF(o.OrderNo = 'DEMO-ORDER-002-1', 1, NULL)
FROM dbo.ServiceVisit v JOIN dbo.ServiceOrder o ON o.OrderId = v.OrderId
WHERE o.OrderNo IN ('DEMO-ORDER-001-1', 'DEMO-ORDER-002-1') AND v.ComplainedAt IS NULL;

COMMIT;
PRINT N'服务业务模拟数据已就绪。';
GO
