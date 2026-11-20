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
DECLARE @Labels table (
    Seq int PRIMARY KEY, WorkerName nvarchar(30), AgencyName nvarchar(50),
    ServiceName nvarchar(50), RecordText nvarchar(200)
);
INSERT @Labels VALUES
    (1, N'王海燕', N'清溪里居家养老服务站', N'午餐送餐到家', N'午餐送达并核对餐别，老人确认饭菜温度合适。'),
    (2, N'陈立新', N'松荫苑长者照护中心', N'居家助浴与防滑照护', N'上门协助沐浴，检查浴室防滑垫和扶手，结束后整理地面。'),
    (3, N'林瑞霞', N'竹风巷助老服务社', N'社区门诊陪诊', N'陪同老人到社区门诊签到和候诊，返家后将复诊时间告知家属。'),
    (4, N'张玉玲', N'梧桐庭居家服务中心', N'居室日常清洁', N'清理厨房台面与常用过道，按老人习惯归置生活用品。'),
    (5, N'马晓彤', N'溪桥北康复照护站', N'居家关节活动陪练', N'按照护计划陪同完成当日关节活动，记录练习时长。'),
    (6, N'孙庆芳', N'柳湾里长者服务站', N'晚餐送餐到家', N'将晚餐放在餐桌，按预约核对餐品并提醒趁热用餐。'),
    (7, N'丁亚萍', N'香樟院互助照护站', N'助浴与洗发', N'协助老人洗发和沐浴，按约定整理换洗用品。'),
    (8, N'杨海英', N'青禾街社区照护中心', N'复诊出行陪同', N'陪同办理复诊签到，协助查找诊室，按时送老人回家。'),
    (9, N'宋明玉', N'玉兰路社区服务社', N'厨房清洁与收纳', N'完成厨房地面清扫和台面清洁，保留老人常用物品的位置。'),
    (10, N'吴丽娟', N'望山里居家照护中心', N'助行器使用陪练', N'在住宅走廊陪老人练习使用助行器，按约定记录完成情况。'),
    (11, N'顾雪芳', N'榆林小院养老服务站', N'软食午餐配送', N'按订单配送软食午餐，提醒老人核对餐盒标签。'),
    (12, N'萧晓玲', N'丁香园长者照护站', N'床旁擦浴', N'按约定协助床旁擦浴，更换床边使用过的毛巾与垫巾。'),
    (13, N'周云浩', N'枫林东助老服务社', N'检验检查陪同', N'陪同老人完成检查登记，核对并提醒领取报告的时间。'),
    (14, N'夏秋芬', N'景和里居家服务站', N'换洗床品与整理', N'换洗常用床品，将清洁后的衣物归入柜中。'),
    (15, N'何雨欣', N'银杏西康复照护站', N'握力与上肢活动陪练', N'陪老人按计划完成上肢练习，记录练习完成情况。'),
    (16, N'彭春芳', N'槐影小区长者服务站', N'清淡餐配送', N'配送预约的清淡餐，确认老人收到餐盒后离开。'),
    (17, N'章玉芬', N'晴川里社区照护站', N'到家助浴与更衣', N'协助沐浴更衣，收好用过的物品并擦干浴室地面。'),
    (18, N'曹秀琴', N'月桥南助老服务站', N'专科复诊陪护', N'陪同老人到预约科室并协助路线指引，回家后联系家属。'),
    (19, N'钟亚琴', N'听松苑居家服务社', N'客厅清洁与通道整理', N'完成客厅清洁，和老人一起确认过道没有杂物。'),
    (20, N'罗佳丽', N'春泉里长者照护中心', N'日常活动与康复随访', N'按照护单陪同完成日常活动，记录并反馈本次服务情况。');

;WITH NumberedArchive AS (
    SELECT ROW_NUMBER() OVER (ORDER BY e.ArchiveNo) AS Seq, e.ArchiveNo, e.CommunityId, c.District,
           COALESCE(a.AbilityLevel, N'轻度失能') AS AbilityLevel, e.Address,
           COALESCE(e.Latitude, c.Latitude) AS Latitude, COALESCE(e.Longitude, c.Longitude) AS Longitude
    FROM dbo.ElderArchive e JOIN dbo.Community c ON c.CommunityId = e.CommunityId
    LEFT JOIN dbo.v_CurrentAbilityAssessment a ON a.ArchiveNo = e.ArchiveNo
    WHERE e.ArchiveNo LIKE 'E[0-9][0-9][0-9][0-9]' AND e.ArchiveNo BETWEEN 'E0001' AND 'E0020'
      AND LEFT(e.IdNumber,6)='000000'
)
INSERT @Demo SELECT Seq, RIGHT('000' + CONVERT(varchar(3), Seq), 3), ArchiveNo, CommunityId, District,
                    AbilityLevel, Address, Latitude, Longitude
FROM NumberedArchive;

IF (SELECT COUNT(*) FROM @Demo) <> 20
    THROW 51224, N'请先准备 E0001 至 E0020 的模拟档案。', 1;

BEGIN TRANSACTION;
EXEC dbo.usp_ServiceLock 'seed', N'services';

INSERT dbo.Agency(AgencyNo, Name, District)
SELECT CONCAT('DEMO-AGENCY-', d.Suffix), label.AgencyName, d.District
FROM @Demo d JOIN @Labels label ON label.Seq=d.Seq
WHERE NOT EXISTS (SELECT 1 FROM dbo.Agency a WHERE a.AgencyNo = CONCAT('DEMO-AGENCY-', d.Suffix));

UPDATE agency SET Name=label.AgencyName
FROM @Demo demo JOIN @Labels label ON label.Seq=demo.Seq
JOIN dbo.Agency agency ON agency.AgencyNo=CONCAT('DEMO-AGENCY-',demo.Suffix)
WHERE agency.Name=CONCAT(N'演示服务机构',demo.Suffix);

INSERT dbo.Worker(WorkerNo, AgencyId, Name, Grade, TrainingCompletedOn)
SELECT CONCAT('DEMO-WORKER-', d.Suffix), a.AgencyId, label.WorkerName, N'养老护理员',
       DATEADD(day, -d.Seq - 30, @Today)
FROM @Demo d JOIN dbo.Agency a ON a.AgencyNo = CONCAT('DEMO-AGENCY-', d.Suffix)
JOIN @Labels label ON label.Seq=d.Seq
WHERE NOT EXISTS (SELECT 1 FROM dbo.Worker w WHERE w.WorkerNo = CONCAT('DEMO-WORKER-', d.Suffix));

UPDATE worker SET Name=label.WorkerName, Grade=IIF(worker.Grade=N'示例护理员',N'养老护理员',worker.Grade)
FROM @Demo demo JOIN @Labels label ON label.Seq=demo.Seq
JOIN dbo.Worker worker ON worker.WorkerNo=CONCAT('DEMO-WORKER-',demo.Suffix)
WHERE worker.Name=CONCAT(N'演示护工',demo.Suffix);

UPDATE w SET TrainingCompletedOn = DATEADD(day, -d.Seq - 30, @Today)
FROM dbo.Worker w JOIN @Demo d ON w.WorkerNo = CONCAT('DEMO-WORKER-', d.Suffix)
WHERE w.TrainingCompletedOn IS NULL;

INSERT dbo.WorkerCommunity(WorkerId, CommunityId)
SELECT w.WorkerId, home.CommunityId
FROM @Demo d JOIN dbo.Worker w ON w.WorkerNo=CONCAT('DEMO-WORKER-',d.Suffix)
JOIN dbo.Agency agency ON agency.AgencyId=w.AgencyId
JOIN dbo.Community home ON home.CommunityId=CASE WHEN d.Seq<=2 THEN 1 WHEN d.Seq=3 THEN 2 ELSE d.Seq END
    AND home.District=agency.District
WHERE NOT EXISTS (SELECT 1 FROM dbo.WorkerCommunity n WHERE n.WorkerId=w.WorkerId AND n.CommunityId=home.CommunityId);

INSERT dbo.ServiceType(Code, Name, Unit, Rate, StandardMinutes, Subsidizable, CategoryCode)
SELECT CONCAT('DEMO-SERVICE-', d.Suffix), label.ServiceName,
       IIF(categories.Kind IN (0,1), N'次', N'小时'), categories.Rate, 60, 1, categories.CategoryCode
FROM @Demo d JOIN @Labels label ON label.Seq=d.Seq
JOIN (VALUES (0,'MEAL',26),(1,'BATH',65),(2,'ESCORT',55),
    (3,'HOUSEWORK',42),(4,'REHAB',58)) categories(Kind, CategoryCode, Rate)
ON categories.Kind = (d.Seq - 1) % 5
WHERE NOT EXISTS (SELECT 1 FROM dbo.ServiceType t WHERE t.Code = CONCAT('DEMO-SERVICE-', d.Suffix));

UPDATE service SET Name=label.ServiceName
FROM @Demo demo JOIN @Labels label ON label.Seq=demo.Seq
JOIN dbo.ServiceType service ON service.Code=CONCAT('DEMO-SERVICE-',demo.Suffix)
WHERE service.Name=CONCAT(CHOOSE((demo.Seq-1)%5+1,N'助餐',N'助浴',N'陪诊',N'家政',N'康复护理'),N'（演示',demo.Suffix,N'）')
  AND NOT EXISTS (SELECT 1 FROM dbo.ServiceType other WHERE other.Name=label.ServiceName);

INSERT dbo.WorkerService(WorkerId, ServiceTypeId, CredentialNo, ValidFrom, ValidThrough, CredentialType, CredentialLevel)
SELECT w.WorkerId, t.ServiceTypeId, CONCAT(N'模拟证书-', d.Suffix), DATEADD(year, -1, @Today), DATEADD(year, 1, @Today),
       N'养老护理', N'初级'
FROM @Demo d JOIN dbo.Worker w ON w.WorkerNo = CONCAT('DEMO-WORKER-', d.Suffix)
JOIN dbo.ServiceType t ON t.Code = CONCAT('DEMO-SERVICE-', d.Suffix)
WHERE NOT EXISTS (SELECT 1 FROM dbo.WorkerService s WHERE s.WorkerId = w.WorkerId AND s.ServiceTypeId = t.ServiceTypeId);

UPDATE package SET Name=CONCAT(label.ServiceName,N'照护包')
FROM @Demo demo JOIN @Labels label ON label.Seq=demo.Seq
JOIN dbo.CarePlan planRow ON planRow.PlanNo=CONCAT('DEMO-PLAN-',demo.Suffix) AND planRow.ArchiveNo=demo.ArchiveNo
JOIN dbo.CarePackage package ON package.PackageId=planRow.PackageId
WHERE package.Name=CONCAT(N'演示照护包',demo.Suffix)
  AND NOT EXISTS (SELECT 1 FROM dbo.CarePackage other WHERE other.Name=CONCAT(label.ServiceName,N'照护包'));

INSERT dbo.CarePackage(Name, AbilityLevel)
SELECT CONCAT(label.ServiceName,N'照护包'), d.AbilityLevel
FROM @Demo d JOIN @Labels label ON label.Seq=d.Seq
WHERE NOT EXISTS (SELECT 1 FROM dbo.CarePlan p WHERE p.PlanNo=CONCAT('DEMO-PLAN-',d.Suffix))
  AND NOT EXISTS (SELECT 1 FROM dbo.CarePackage p WHERE p.Name=CONCAT(label.ServiceName,N'照护包'));

DECLARE @Packages table (Seq int PRIMARY KEY, PackageId int NOT NULL);
INSERT @Packages
SELECT demo.Seq, COALESCE(existing.PackageId,package.PackageId)
FROM @Demo demo JOIN @Labels label ON label.Seq=demo.Seq
LEFT JOIN dbo.CarePlan existing ON existing.PlanNo=CONCAT('DEMO-PLAN-',demo.Suffix)
LEFT JOIN dbo.CarePackage package ON package.Name=CONCAT(label.ServiceName,N'照护包');

INSERT dbo.CarePackageService(PackageId, ServiceTypeId, VisitsPerWeek)
SELECT p.PackageId, t.ServiceTypeId, 2 FROM @Demo d
JOIN @Packages p ON p.Seq=d.Seq
JOIN dbo.ServiceType t ON t.Code = CONCAT('DEMO-SERVICE-', d.Suffix)
WHERE NOT EXISTS (SELECT 1 FROM dbo.CarePackageService ps WHERE ps.PackageId = p.PackageId AND ps.ServiceTypeId = t.ServiceTypeId);

INSERT dbo.CarePlan(PlanNo, ArchiveNo, PackageId, ResponsibleWorkerId, StartsOn, EndsOn, Status, ChangedReason)
SELECT CONCAT('DEMO-PLAN-', d.Suffix), d.ArchiveNo, p.PackageId, w.WorkerId,
       DATEADD(month, -3, @MonthStart), DATEADD(day, 90, @Today), 'ACTIVE', N'根据评估结果制定居家照护安排'
FROM @Demo d JOIN @Packages p ON p.Seq=d.Seq
JOIN dbo.Worker w ON w.WorkerNo = CONCAT('DEMO-WORKER-', d.Suffix)
WHERE NOT EXISTS (SELECT 1 FROM dbo.CarePlan existing WHERE existing.PlanNo = CONCAT('DEMO-PLAN-', d.Suffix));

DECLARE @Scheduled TABLE (
    OrderNo varchar(30) PRIMARY KEY, ArchiveNo varchar(20), PlanId int, ServiceTypeId int, CommunityId int,
    WorkerId int, StartsAt datetime2(0), EndsAt datetime2(0), IsHistorical bit,
    Address nvarchar(200), Latitude decimal(9,6), Longitude decimal(9,6), Price decimal(12,2), Seq int
);

INSERT @Scheduled
SELECT CONCAT('DEMO-ORDER-', d.Suffix, '-', n.Scenario), d.ArchiveNo, p.PlanId, t.ServiceTypeId, d.CommunityId,
       w.WorkerId, times.StartsAt, DATEADD(hour, 1, times.StartsAt), IIF(n.Scenario < 3, 1, 0),
       d.Address, d.Latitude, d.Longitude, t.Rate, d.Seq
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

UPDATE orders SET Address=scheduled.Address
FROM dbo.ServiceOrder orders JOIN @Scheduled scheduled ON scheduled.OrderNo=orders.OrderNo AND scheduled.ArchiveNo=orders.ArchiveNo
WHERE orders.Address=CONCAT(N'演示路 ',scheduled.Seq,N' 号') AND orders.Address<>scheduled.Address;

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
       d.Longitude, 1, IIF(example.NeedsReview=1,0,1), 1, 1, label.RecordText,
       IIF(example.NeedsReview=1,'REVIEW','VALID'), IIF(example.NeedsReview=1,NULL,60),
       IIF(example.NeedsReview=1,N'模拟签退超出服务围栏',NULL),
       IIF(example.IsSigned=1,DATEADD(minute,5,d.EndsAt),NULL), IIF(example.IsSigned=1,1,NULL),
       IIF(example.IsSigned=1,N'模拟家属电子签字',NULL),
       IIF(example.IsSigned=1,dbo.fn_ServiceConfirmationHash(
           o.OrderId,1,DATEADD(minute,5,d.EndsAt),N'模拟家属电子签字'),NULL),
        IIF(example.IsSigned=1,4+label.Seq%2,NULL),
        IIF(example.IsSigned=1,CHOOSE((label.Seq-1)%3+1,N'服务准时，交代得很清楚。',N'照护细心，老人感觉自在。',
             N'预约时间安排合适，下次还会预约。'),NULL),
        elder.SubsidyCategory, package.AbilityLevel
FROM @Scheduled d JOIN dbo.ServiceOrder o ON o.OrderNo = d.OrderNo
JOIN dbo.ElderArchive elder ON elder.ArchiveNo = o.ArchiveNo
JOIN dbo.CarePlan planRow ON planRow.PlanId = o.PlanId
JOIN dbo.CarePackage package ON package.PackageId = planRow.PackageId
JOIN @Labels label ON label.Seq=d.Seq
JOIN dbo.ServiceDispatch x ON x.OrderId = o.OrderId AND x.CloseReason = N'服务完成'
CROSS APPLY (VALUES (
    IIF(d.OrderNo IN ('DEMO-ORDER-006-2','DEMO-ORDER-007-2'),1,0),
    IIF(o.Status='COMPLETED',1,0)
)) example(NeedsReview, IsSigned)
WHERE d.IsHistorical = 1 AND NOT EXISTS (SELECT 1 FROM dbo.ServiceVisit v WHERE v.OrderId = o.OrderId);

UPDATE visit SET ServiceRecord=label.RecordText
FROM dbo.ServiceVisit visit JOIN dbo.ServiceOrder orders ON orders.OrderId=visit.OrderId
JOIN @Scheduled scheduled ON scheduled.OrderNo=orders.OrderNo AND scheduled.ArchiveNo=orders.ArchiveNo AND scheduled.IsHistorical=1
JOIN @Labels label ON label.Seq=scheduled.Seq
WHERE visit.ServiceRecord=N'模拟完成上门服务';

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
