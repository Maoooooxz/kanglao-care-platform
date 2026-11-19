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

IF DB_NAME() <> N'KanglaoCourse' OR COL_LENGTH('dbo.ElderArchive', 'IsActive') IS NULL
    THROW 51200, N'请先安装档案核心脚本。', 1;
GO

SET XACT_ABORT ON;
IF OBJECT_ID('dbo.ServiceType', 'U') IS NULL
BEGIN
    BEGIN TRANSACTION;
    CREATE TABLE dbo.ServiceType (
        ServiceTypeId int IDENTITY PRIMARY KEY,
        Code varchar(30) NOT NULL UNIQUE,
        Name nvarchar(100) NOT NULL UNIQUE,
        Unit nvarchar(8) NOT NULL CHECK (Unit IN (N'次', N'小时')),
        Rate decimal(10,2) NOT NULL CHECK (Rate >= 0),
        StandardMinutes smallint NOT NULL CHECK (StandardMinutes > 0),
        Subsidizable bit NOT NULL DEFAULT 1
    );

    CREATE TABLE dbo.Agency (
        AgencyId int IDENTITY PRIMARY KEY,
        AgencyNo varchar(30) NOT NULL UNIQUE,
        Name nvarchar(100) NOT NULL,
        District nvarchar(40) NOT NULL
    );

    CREATE TABLE dbo.Worker (
        WorkerId int IDENTITY PRIMARY KEY,
        WorkerNo varchar(30) NOT NULL UNIQUE,
        AgencyId int NOT NULL REFERENCES dbo.Agency(AgencyId),
        Name nvarchar(100) NOT NULL,
        Grade nvarchar(40) NOT NULL,
        Rating decimal(3,2) NOT NULL DEFAULT 5 CHECK (Rating BETWEEN 0 AND 5),
        TrainingCompletedOn date NULL,
        IsActive bit NOT NULL DEFAULT 1
    );

    CREATE TABLE dbo.WorkerCommunity (
        WorkerId int NOT NULL REFERENCES dbo.Worker(WorkerId),
        CommunityId int NOT NULL REFERENCES dbo.Community(CommunityId),
        PRIMARY KEY (WorkerId, CommunityId)
    );

    CREATE TABLE dbo.WorkerService (
        WorkerId int NOT NULL REFERENCES dbo.Worker(WorkerId),
        ServiceTypeId int NOT NULL REFERENCES dbo.ServiceType(ServiceTypeId),
        CredentialNo nvarchar(60) NOT NULL,
        ValidFrom date NOT NULL,
        ValidThrough date NOT NULL,
        PRIMARY KEY (WorkerId, ServiceTypeId),
        CHECK (ValidThrough >= ValidFrom)
    );

    CREATE TABLE dbo.WorkerRestriction (
        RestrictionId int IDENTITY PRIMARY KEY,
        WorkerId int NOT NULL REFERENCES dbo.Worker(WorkerId),
        Reason nvarchar(250) NOT NULL,
        CreatedAt datetime2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
        ResolvedAt datetime2(0) NULL,
        CHECK (ResolvedAt >= CreatedAt)
    );
    CREATE INDEX IX_WorkerRestriction_Active ON dbo.WorkerRestriction(WorkerId, ResolvedAt)
        WHERE ResolvedAt IS NULL;

    CREATE TABLE dbo.WorkerShift (
        ShiftId int IDENTITY PRIMARY KEY,
        WorkerId int NOT NULL REFERENCES dbo.Worker(WorkerId),
        StartsAt datetime2(0) NOT NULL,
        EndsAt datetime2(0) NOT NULL,
        Capacity int NOT NULL CHECK (Capacity > 0),
        IsOpen bit NOT NULL DEFAULT 1,
        UNIQUE (WorkerId, StartsAt),
        CHECK (EndsAt > StartsAt)
    );
    CREATE INDEX IX_WorkerShift_Interval ON dbo.WorkerShift(WorkerId, StartsAt, EndsAt);

    CREATE TABLE dbo.CarePackage (
        PackageId int IDENTITY PRIMARY KEY,
        Name nvarchar(100) NOT NULL UNIQUE,
        AbilityLevel nvarchar(20) NOT NULL
    );

    CREATE TABLE dbo.CarePackageService (
        PackageId int NOT NULL REFERENCES dbo.CarePackage(PackageId),
        ServiceTypeId int NOT NULL REFERENCES dbo.ServiceType(ServiceTypeId),
        VisitsPerWeek tinyint NOT NULL CHECK (VisitsPerWeek > 0),
        PRIMARY KEY (PackageId, ServiceTypeId)
    );

    CREATE TABLE dbo.CarePlan (
        PlanId int IDENTITY PRIMARY KEY,
        PlanNo varchar(30) NULL UNIQUE,
        ArchiveNo varchar(20) NOT NULL REFERENCES dbo.ElderArchive(ArchiveNo),
        PackageId int NOT NULL REFERENCES dbo.CarePackage(PackageId),
        ResponsibleWorkerId int NOT NULL REFERENCES dbo.Worker(WorkerId),
        StartsOn date NOT NULL,
        EndsOn date NOT NULL,
        Status varchar(12) NOT NULL CHECK (Status IN ('ACTIVE','PAUSED','ENDED')),
        ChangedReason nvarchar(250) NOT NULL DEFAULT N'新建',
        CreatedAt datetime2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
        CHECK (EndsOn >= StartsOn)
    );
    CREATE INDEX IX_CarePlan_ArchiveDates ON dbo.CarePlan(ArchiveNo, StartsOn, EndsOn, Status);

    CREATE TABLE dbo.CarePlanAudit (
        AuditId int IDENTITY PRIMARY KEY,
        PlanId int NOT NULL REFERENCES dbo.CarePlan(PlanId),
        OldStatus varchar(12) NULL,
        NewStatus varchar(12) NOT NULL,
        Reason nvarchar(250) NOT NULL,
        LoggedAt datetime2(0) NOT NULL DEFAULT SYSUTCDATETIME()
    );

    CREATE TABLE dbo.ServiceOrder (
        OrderId int IDENTITY PRIMARY KEY,
        OrderNo varchar(30) NULL UNIQUE,
        ArchiveNo varchar(20) NOT NULL REFERENCES dbo.ElderArchive(ArchiveNo),
        PlanId int NOT NULL REFERENCES dbo.CarePlan(PlanId),
        ServiceTypeId int NOT NULL REFERENCES dbo.ServiceType(ServiceTypeId),
        CommunityId int NOT NULL REFERENCES dbo.Community(CommunityId),
        Status varchar(24) NOT NULL CHECK (Status IN (
            'NEW','POOL','OFFERED','ACCEPTED','IN_SERVICE','AWAITING_CONFIRMATION',
            'COMPLETED','REVIEW','RESCHEDULE','CANCELLED'
        )),
        Price decimal(12,2) NOT NULL CHECK (Price >= 0),
        AppointmentStart datetime2(0) NOT NULL,
        AppointmentEnd datetime2(0) NOT NULL,
        Address nvarchar(200) NOT NULL,
        Latitude decimal(9,6) NOT NULL CHECK (Latitude BETWEEN -90 AND 90),
        Longitude decimal(9,6) NOT NULL CHECK (Longitude BETWEEN -180 AND 180),
        Channel varchar(12) NOT NULL CHECK (Channel IN ('PHONE','FAMILY','COMMUNITY')),
        CreatedAt datetime2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
        DispatchDeadline datetime2(0) NOT NULL,
        ReviewReason nvarchar(250) NULL,
        CHECK (AppointmentEnd > AppointmentStart)
    );
    CREATE INDEX IX_ServiceOrder_StatusDeadline ON dbo.ServiceOrder(Status, DispatchDeadline, ArchiveNo);
    CREATE INDEX IX_ServiceOrder_Community ON dbo.ServiceOrder(CommunityId, AppointmentStart, OrderId);

    CREATE TABLE dbo.ServiceDispatch (
        DispatchId int IDENTITY PRIMARY KEY,
        OrderId int NOT NULL REFERENCES dbo.ServiceOrder(OrderId),
        WorkerId int NOT NULL REFERENCES dbo.Worker(WorkerId),
        ShiftId int NOT NULL REFERENCES dbo.WorkerShift(ShiftId),
        OfferedAt datetime2(0) NOT NULL,
        OfferExpiresAt datetime2(0) NOT NULL,
        AcceptedAt datetime2(0) NULL,
        ClosedAt datetime2(0) NULL,
        CloseReason nvarchar(250) NULL,
        CHECK (OfferExpiresAt > OfferedAt),
        CHECK (AcceptedAt >= OfferedAt),
        CHECK (ClosedAt >= OfferedAt),
        CONSTRAINT CK_ServiceDispatch_Close CHECK (
            (ClosedAt IS NULL AND CloseReason IS NULL) OR (ClosedAt IS NOT NULL AND CloseReason IS NOT NULL)
        )
    );
    CREATE UNIQUE INDEX UX_ServiceDispatch_Open ON dbo.ServiceDispatch(OrderId) WHERE ClosedAt IS NULL;
    CREATE INDEX IX_ServiceDispatch_Quota ON dbo.ServiceDispatch(ShiftId, AcceptedAt, ClosedAt)
        INCLUDE (OrderId, WorkerId, CloseReason);

    CREATE TABLE dbo.ServiceDispatchAudit (
        AuditId int IDENTITY PRIMARY KEY,
        DispatchId int NOT NULL REFERENCES dbo.ServiceDispatch(DispatchId),
        Action varchar(12) NOT NULL,
        Reason nvarchar(250) NULL,
        LoggedAt datetime2(0) NOT NULL DEFAULT SYSUTCDATETIME()
    );

    CREATE TABLE dbo.ServiceVisit (
        OrderId int PRIMARY KEY REFERENCES dbo.ServiceOrder(OrderId),
        DispatchId int NOT NULL UNIQUE REFERENCES dbo.ServiceDispatch(DispatchId),
        WorkerId int NOT NULL REFERENCES dbo.Worker(WorkerId),
        CheckInAt datetime2(0) NOT NULL,
        CheckOutAt datetime2(0) NULL,
        InLatitude decimal(9,6) NOT NULL CHECK (InLatitude BETWEEN -90 AND 90),
        InLongitude decimal(9,6) NOT NULL CHECK (InLongitude BETWEEN -180 AND 180),
        OutLatitude decimal(9,6) NULL CHECK (OutLatitude BETWEEN -90 AND 90),
        OutLongitude decimal(9,6) NULL CHECK (OutLongitude BETWEEN -180 AND 180),
        InFence bit NOT NULL,
        OutFence bit NULL,
        InShift bit NOT NULL,
        OutShift bit NULL,
        ExpiredDuringVisit bit NOT NULL DEFAULT 0,
        ServiceRecord nvarchar(500) NULL,
        WorkStatus varchar(12) NOT NULL CHECK (WorkStatus IN ('OPEN','VALID','REVIEW','REJECTED')),
        EffectiveMinutes int NULL CHECK (EffectiveMinutes >= 0),
        ReviewReason nvarchar(250) NULL,
        ConfirmedAt datetime2(0) NULL,
        ConfirmedBy int NULL,
        ConfirmationText nvarchar(200) NULL,
        ConfirmationHash varbinary(32) NULL,
        FeedbackScore tinyint NULL CHECK (FeedbackScore BETWEEN 1 AND 5),
        Feedback nvarchar(300) NULL,
        ComplaintText nvarchar(300) NULL,
        ComplainedAt datetime2(0) NULL,
        ComplainedBy int NULL,
        ComplaintResolution nvarchar(300) NULL,
        ComplaintResolvedAt datetime2(0) NULL,
        ComplaintResolvedBy int NULL,
        CHECK (CheckOutAt >= CheckInAt),
        CONSTRAINT CK_ServiceVisit_Confirmation CHECK (
            (ConfirmedAt IS NULL AND ConfirmedBy IS NULL AND ConfirmationText IS NULL AND ConfirmationHash IS NULL)
            OR (ConfirmedAt IS NOT NULL AND ConfirmedAt >= CheckOutAt AND CheckOutAt IS NOT NULL
                AND ConfirmedBy IS NOT NULL AND LEN(ConfirmationText) > 0 AND ConfirmationText IS NOT NULL
                AND ConfirmationHash IS NOT NULL)
        )
    );
    CREATE INDEX IX_ServiceVisit_WorkerPeriod ON dbo.ServiceVisit(WorkerId, CheckOutAt, WorkStatus);

    CREATE TABLE dbo.ServiceVisitAudit (
        AuditId int IDENTITY PRIMARY KEY,
        OrderId int NOT NULL REFERENCES dbo.ServiceVisit(OrderId),
        OldStatus varchar(12) NULL,
        NewStatus varchar(12) NOT NULL,
        Reason nvarchar(250) NULL,
        LoggedAt datetime2(0) NOT NULL DEFAULT SYSUTCDATETIME()
    );
    COMMIT;
END;
GO

IF COL_LENGTH('dbo.ServiceVisit', 'ConfirmationHash') IS NULL
    ALTER TABLE dbo.ServiceVisit ADD ConfirmationHash varbinary(32) NULL;
IF COL_LENGTH('dbo.ServiceVisit', 'ComplaintText') IS NULL
    ALTER TABLE dbo.ServiceVisit ADD ComplaintText nvarchar(300) NULL, ComplainedAt datetime2(0) NULL,
        ComplainedBy int NULL, ComplaintResolution nvarchar(300) NULL,
        ComplaintResolvedAt datetime2(0) NULL, ComplaintResolvedBy int NULL;
IF COL_LENGTH('dbo.Worker', 'TrainingCompletedOn') IS NULL
    ALTER TABLE dbo.Worker ADD TrainingCompletedOn date NULL;
IF COL_LENGTH('dbo.ServiceType', 'CategoryCode') IS NULL
    ALTER TABLE dbo.ServiceType ADD CategoryCode varchar(12) NULL
        CONSTRAINT CK_ServiceType_Category CHECK (CategoryCode IN ('MEAL','BATH','ESCORT','HOUSEWORK','REHAB'));
IF COL_LENGTH('dbo.WorkerService', 'CredentialType') IS NULL
    ALTER TABLE dbo.WorkerService ADD CredentialType nvarchar(40) NULL, CredentialLevel nvarchar(40) NULL;
IF COL_LENGTH('dbo.ServiceDispatch', 'TimeoutFollowedUpAt') IS NULL
    ALTER TABLE dbo.ServiceDispatch ADD TimeoutFollowedUpAt datetime2(0) NULL,
        TimeoutFollowedUpBy int NULL REFERENCES dbo.AppUser(UserId), TimeoutFollowupNote nvarchar(250) NULL;
IF COL_LENGTH('dbo.ServiceVisit', 'SubsidyCategory') IS NULL
    ALTER TABLE dbo.ServiceVisit ADD SubsidyCategory varchar(12) NULL, SubsidyAbilityLevel nvarchar(20) NULL,
        CONSTRAINT CK_ServiceVisit_SubsidyBasis CHECK (
            (SubsidyCategory IS NULL AND SubsidyAbilityLevel IS NULL)
            OR (SubsidyCategory IS NOT NULL AND SubsidyCategory IN ('GENERAL','LOW_INCOME')
                AND SubsidyAbilityLevel IS NOT NULL)
        );
GO

CREATE OR ALTER FUNCTION dbo.fn_ServiceConfirmationHash(
    @OrderId int, @ActorId int, @ConfirmedAt datetime2(0), @Signature nvarchar(200)
)
RETURNS varbinary(32) AS
BEGIN
    RETURN HASHBYTES('SHA2_256', CONVERT(varbinary(max), CONCAT(
        @OrderId, '|', @ActorId, '|', CONVERT(varchar(19), @ConfirmedAt, 126), '|', @Signature)));
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_CarePlanAudit ON dbo.CarePlan AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.CarePlanAudit(PlanId, OldStatus, NewStatus, Reason)
    SELECT i.PlanId, d.Status, i.Status, i.ChangedReason
    FROM inserted i LEFT JOIN deleted d ON d.PlanId = i.PlanId
    WHERE d.PlanId IS NULL OR d.Status <> i.Status;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_ServiceDispatchAudit ON dbo.ServiceDispatch AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.ServiceDispatchAudit(DispatchId, Action, Reason)
    SELECT i.DispatchId, 'OFFERED', NULL
    FROM inserted i LEFT JOIN deleted d ON d.DispatchId = i.DispatchId
    WHERE d.DispatchId IS NULL;
    INSERT dbo.ServiceDispatchAudit(DispatchId, Action, Reason)
    SELECT i.DispatchId, 'ACCEPTED', NULL
    FROM inserted i LEFT JOIN deleted d ON d.DispatchId = i.DispatchId
    WHERE d.AcceptedAt IS NULL AND i.AcceptedAt IS NOT NULL;
    INSERT dbo.ServiceDispatchAudit(DispatchId, Action, Reason)
    SELECT i.DispatchId, 'CLOSED', i.CloseReason
    FROM inserted i LEFT JOIN deleted d ON d.DispatchId = i.DispatchId
    WHERE d.ClosedAt IS NULL AND i.ClosedAt IS NOT NULL;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_ServiceVisitAudit ON dbo.ServiceVisit AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.ServiceVisitAudit(OrderId, OldStatus, NewStatus, Reason)
    SELECT i.OrderId, d.WorkStatus, i.WorkStatus, i.ReviewReason
    FROM inserted i LEFT JOIN deleted d ON d.OrderId = i.OrderId
    WHERE d.OrderId IS NULL OR d.WorkStatus <> i.WorkStatus;
    INSERT dbo.ServiceVisitAudit(OrderId, OldStatus, NewStatus, Reason)
    SELECT i.OrderId, i.WorkStatus, i.WorkStatus,
           CASE signer.Role WHEN 'resident' THEN N'老人本人签字完成' WHEN 'family' THEN N'家属签字完成'
               ELSE N'服务签字完成' END
    FROM inserted i LEFT JOIN deleted d ON d.OrderId = i.OrderId
    LEFT JOIN dbo.AppUser signer ON signer.UserId = i.ConfirmedBy
    WHERE d.ConfirmedAt IS NULL AND i.ConfirmedAt IS NOT NULL;
    INSERT dbo.ServiceVisitAudit(OrderId, OldStatus, NewStatus, Reason)
    SELECT i.OrderId, i.WorkStatus, i.WorkStatus,
           IIF(i.ComplaintResolvedAt IS NULL, N'提交服务投诉', N'社区回复服务投诉')
    FROM inserted i LEFT JOIN deleted d ON d.OrderId = i.OrderId
    WHERE (d.ComplainedAt IS NULL AND i.ComplainedAt IS NOT NULL)
       OR (d.ComplaintResolvedAt IS NULL AND i.ComplaintResolvedAt IS NOT NULL);
END;
GO

CREATE OR ALTER VIEW dbo.v_CarePlanOverview AS
SELECT p.PlanId, p.PlanNo, p.ArchiveNo, e.FullName, e.CommunityId, c.District,
       p.PackageId, k.Name AS PackageName, k.AbilityLevel, p.ResponsibleWorkerId,
       w.Name AS WorkerName, w.AgencyId, p.StartsOn, p.EndsOn, p.Status, p.ChangedReason,
       a.AssessmentStatus, a.ValidThrough
FROM dbo.CarePlan p
JOIN dbo.ElderArchive e ON e.ArchiveNo = p.ArchiveNo
JOIN dbo.Community c ON c.CommunityId = e.CommunityId
JOIN dbo.CarePackage k ON k.PackageId = p.PackageId
JOIN dbo.Worker w ON w.WorkerId = p.ResponsibleWorkerId
JOIN dbo.v_CurrentAbilityAssessment a ON a.ArchiveNo = p.ArchiveNo;
GO

CREATE OR ALTER VIEW dbo.v_ServiceOrderOverview AS
SELECT o.OrderId, o.OrderNo, o.ArchiveNo, e.FullName, o.PlanId, o.ServiceTypeId, t.Name AS ServiceName,
       t.Unit, o.CommunityId, c.District, o.Status, o.Price, o.AppointmentStart, o.AppointmentEnd,
       o.Address, o.Latitude, o.Longitude, o.Channel, o.CreatedAt, o.DispatchDeadline, o.ReviewReason,
       d.DispatchId, d.WorkerId, w.Name AS WorkerName, w.AgencyId, d.OfferExpiresAt, d.ClosedAt,
       v.CheckInAt, v.CheckOutAt, v.WorkStatus, v.EffectiveMinutes, v.ConfirmedAt, v.FeedbackScore, v.Feedback,
       v.ComplaintText, v.ComplainedAt, v.ComplaintResolution, v.ComplaintResolvedAt,
       v.ServiceRecord, t.Subsidizable
FROM dbo.ServiceOrder o
JOIN dbo.ElderArchive e ON e.ArchiveNo = o.ArchiveNo
JOIN dbo.Community c ON c.CommunityId = o.CommunityId
JOIN dbo.ServiceType t ON t.ServiceTypeId = o.ServiceTypeId
OUTER APPLY (SELECT TOP (1) * FROM dbo.ServiceDispatch x WHERE x.OrderId = o.OrderId ORDER BY x.DispatchId DESC) d
LEFT JOIN dbo.Worker w ON w.WorkerId = d.WorkerId
LEFT JOIN dbo.ServiceVisit v ON v.OrderId = o.OrderId;
GO

CREATE OR ALTER VIEW dbo.v_ServiceDispatchHistory AS
SELECT d.DispatchId, d.OrderId, d.WorkerId, w.Name AS WorkerName, w.AgencyId, d.ShiftId,
       d.OfferedAt, d.OfferExpiresAt, d.AcceptedAt, d.ClosedAt, d.CloseReason,
       o.ArchiveNo, o.CommunityId, c.District, d.TimeoutFollowedUpAt, d.TimeoutFollowupNote
FROM dbo.ServiceDispatch d JOIN dbo.Worker w ON w.WorkerId = d.WorkerId
JOIN dbo.ServiceOrder o ON o.OrderId = d.OrderId JOIN dbo.Community c ON c.CommunityId = o.CommunityId;
GO

CREATE OR ALTER VIEW dbo.v_ManualDispatchPool AS
SELECT OrderId, ArchiveNo, ServiceTypeId, ServiceName, CommunityId, District, AppointmentStart,
       DispatchDeadline, ReviewReason FROM dbo.v_ServiceOrderOverview WHERE Status = 'POOL';
GO

CREATE OR ALTER VIEW dbo.v_WorkerShiftAvailability AS
SELECT s.ShiftId, s.WorkerId, w.Name AS WorkerName, w.AgencyId, a.District,
       s.StartsAt, s.EndsAt, s.Capacity, s.IsOpen,
       COUNT(CASE WHEN d.ClosedAt IS NULL OR visit.CheckOutAt IS NOT NULL THEN d.DispatchId END) AS AcceptedCount,
       s.Capacity - COUNT(CASE WHEN d.ClosedAt IS NULL OR visit.CheckOutAt IS NOT NULL THEN d.DispatchId END) AS Remaining
FROM dbo.WorkerShift s JOIN dbo.Worker w ON w.WorkerId = s.WorkerId JOIN dbo.Agency a ON a.AgencyId = w.AgencyId
LEFT JOIN dbo.ServiceDispatch d ON d.ShiftId = s.ShiftId AND d.AcceptedAt IS NOT NULL
LEFT JOIN dbo.ServiceVisit visit ON visit.DispatchId = d.DispatchId
GROUP BY s.ShiftId, s.WorkerId, w.Name, w.AgencyId, a.District, s.StartsAt, s.EndsAt, s.Capacity, s.IsOpen;
GO

CREATE OR ALTER VIEW dbo.v_WorkerMonthlyHours AS
SELECT v.WorkerId, w.Name AS WorkerName, w.AgencyId, a.District,
       CONVERT(char(7), DATEADD(hour, 8, v.CheckOutAt), 126) AS WorkMonth,
       COUNT_BIG(*) AS Visits, SUM(CONVERT(bigint, v.EffectiveMinutes)) AS EffectiveMinutes
FROM dbo.ServiceVisit v JOIN dbo.Worker w ON v.WorkerId = w.WorkerId JOIN dbo.Agency a ON a.AgencyId = w.AgencyId
WHERE v.WorkStatus = 'VALID' AND v.CheckOutAt IS NOT NULL
GROUP BY v.WorkerId, w.Name, w.AgencyId, a.District, CONVERT(char(7), DATEADD(hour, 8, v.CheckOutAt), 126);
GO

CREATE OR ALTER VIEW dbo.v_WorkHourReview AS
SELECT v.OrderId, o.ArchiveNo, o.CommunityId, c.District, v.WorkerId, w.AgencyId, w.Name AS WorkerName,
       v.CheckInAt, v.CheckOutAt, v.InFence, v.OutFence, v.InShift, v.OutShift, v.ReviewReason
FROM dbo.ServiceVisit v JOIN dbo.ServiceOrder o ON o.OrderId = v.OrderId
JOIN dbo.Worker w ON w.WorkerId = v.WorkerId JOIN dbo.Community c ON c.CommunityId = o.CommunityId
WHERE v.WorkStatus = 'REVIEW';
GO

CREATE OR ALTER VIEW dbo.v_SubsidyEligibleOrder AS
SELECT o.OrderId, o.ArchiveNo, o.ServiceTypeId, o.CommunityId, v.WorkerId, w.AgencyId,
       v.ConfirmedAt, v.CheckOutAt, v.EffectiveMinutes, o.Price, v.SubsidyCategory, v.SubsidyAbilityLevel
FROM dbo.ServiceOrder o JOIN dbo.ServiceVisit v ON v.OrderId = o.OrderId
JOIN dbo.Worker w ON w.WorkerId = v.WorkerId JOIN dbo.ServiceType t ON t.ServiceTypeId = o.ServiceTypeId
WHERE o.Status = 'COMPLETED' AND t.Subsidizable = 1 AND v.WorkStatus = 'VALID'
    AND v.ConfirmedAt IS NOT NULL AND v.CheckOutAt IS NOT NULL AND v.EffectiveMinutes > 0
    AND v.ConfirmationHash = dbo.fn_ServiceConfirmationHash(o.OrderId, v.ConfirmedBy, v.ConfirmedAt, v.ConfirmationText);
GO

CREATE OR ALTER PROCEDURE dbo.usp_ServiceLock @Kind varchar(12), @Identifier nvarchar(40) AS
BEGIN
    SET NOCOUNT ON;
    IF @Kind = 'archive'
    BEGIN
        DECLARE @ArchiveNo varchar(20) = CONVERT(varchar(20), @Identifier), @LockedArchive varchar(20);
        SELECT @LockedArchive = ArchiveNo FROM dbo.ElderArchive WITH (UPDLOCK, HOLDLOCK) WHERE ArchiveNo = @ArchiveNo;
    END;
    DECLARE @Resource nvarchar(255) = CONCAT(N'Kanglao:', @Kind, N':', UPPER(@Identifier));
    DECLARE @Result int;
    EXEC @Result = sys.sp_getapplock @Resource = @Resource, @LockMode = 'Exclusive',
        @LockOwner = 'Transaction', @LockTimeout = 10000;
    IF @Result < 0 THROW 51201, N'该记录正在处理，请稍后重试。', 1;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RecordAbilityAssessment
    @AssessmentNo varchar(24), @ArchiveNo varchar(20), @ScaleCode varchar(8), @Score decimal(6,2),
    @AbilityLevel nvarchar(20), @EvaluatorName nvarchar(100), @AssessmentDate date, @ValidThrough date
AS
BEGIN
    SET NOCOUNT ON;
    IF @AssessmentDate > CONVERT(date, DATEADD(hour, 8, SYSUTCDATETIME()))
        THROW 51101, N'评估日期不能晚于当天。', 1;

    DECLARE @OwnTransaction bit = IIF(@@TRANCOUNT = 0, 1, 0);
    IF @OwnTransaction = 1 BEGIN TRANSACTION;
    BEGIN TRY
        EXEC dbo.usp_ServiceLock 'archive', @ArchiveNo;
        IF EXISTS (SELECT 1 FROM dbo.ElderArchive WHERE ArchiveNo = @ArchiveNo AND IsActive = 0)
            THROW 52002, N'档案已停用。', 1;
        INSERT dbo.AbilityAssessment(AssessmentNo, ArchiveNo, ScaleCode, Score, AbilityLevel,
                                     EvaluatorName, AssessmentDate, ValidThrough)
        VALUES (@AssessmentNo, @ArchiveNo, @ScaleCode, @Score, @AbilityLevel, @EvaluatorName, @AssessmentDate, @ValidThrough);
        IF @OwnTransaction = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF @OwnTransaction = 1 AND XACT_STATE() <> 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CreateCarePlan
    @ArchiveNo varchar(20), @PackageId int, @WorkerId int, @StartsOn date, @EndsOn date,
    @ActingCommunityId int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;
    EXEC dbo.usp_ServiceLock 'archive', @ArchiveNo;
    IF @StartsOn IS NULL OR @EndsOn IS NULL OR @EndsOn < @StartsOn
       OR @EndsOn < CONVERT(date, DATEADD(hour, 8, SYSUTCDATETIME()))
        THROW 51202, N'请选择有效的计划日期。', 1;
    IF NOT EXISTS (
        SELECT 1 FROM dbo.v_CurrentAbilityAssessment a JOIN dbo.CarePackage p ON p.AbilityLevel = a.AbilityLevel
        JOIN dbo.ElderArchive e ON e.ArchiveNo = a.ArchiveNo
        JOIN dbo.WorkerCommunity wc ON wc.CommunityId = e.CommunityId AND wc.WorkerId = @WorkerId
        JOIN dbo.Worker w ON w.WorkerId = wc.WorkerId AND w.IsActive = 1
        WHERE a.ArchiveNo = @ArchiveNo AND a.AssessmentStatus = N'有效' AND p.PackageId = @PackageId
            AND e.IsActive = 1 AND a.ValidThrough >= @StartsOn
            AND (@ActingCommunityId IS NULL OR e.CommunityId = @ActingCommunityId)
    ) THROW 51203, N'需要有效评估、能力匹配的服务包及服务本社区的在岗护工。', 1;
    IF EXISTS (SELECT 1 FROM dbo.CarePlan WHERE ArchiveNo = @ArchiveNo AND Status IN ('ACTIVE','PAUSED')
               AND StartsOn <= @EndsOn AND EndsOn >= @StartsOn)
        THROW 51204, N'该老人已有时间重叠的照护计划。', 1;
    INSERT dbo.CarePlan(PlanNo, ArchiveNo, PackageId, ResponsibleWorkerId, StartsOn, EndsOn, Status)
    VALUES (CONCAT('CP-', CONVERT(varchar(24), CRYPT_GEN_RANDOM(12), 2)),
            @ArchiveNo, @PackageId, @WorkerId, @StartsOn, @EndsOn, 'ACTIVE');
    COMMIT;
END;
GO

CREATE OR ALTER FUNCTION dbo.fn_EligibleServiceShifts(@OrderId int)
RETURNS TABLE AS RETURN
(
    SELECT s.ShiftId, s.WorkerId, s.WorkerName, s.AgencyId, s.Remaining
    FROM dbo.ServiceOrder o JOIN dbo.v_WorkerShiftAvailability s
        ON s.StartsAt <= o.AppointmentStart AND s.EndsAt >= o.AppointmentEnd
    JOIN dbo.Worker w ON w.WorkerId = s.WorkerId AND w.IsActive = 1
    JOIN dbo.WorkerCommunity c ON c.WorkerId = w.WorkerId AND c.CommunityId = o.CommunityId
    JOIN dbo.WorkerService cert ON cert.WorkerId = w.WorkerId AND cert.ServiceTypeId = o.ServiceTypeId
        AND cert.ValidFrom <= CONVERT(date, DATEADD(hour, 8, o.AppointmentStart))
        AND cert.ValidThrough >= CONVERT(date, DATEADD(hour, 8, o.AppointmentEnd))
    WHERE o.OrderId = @OrderId AND s.IsOpen = 1 AND s.Remaining > 0
      AND NOT EXISTS (
          SELECT 1 FROM dbo.WorkerRestriction r WHERE r.WorkerId = w.WorkerId AND r.ResolvedAt IS NULL
      ) AND NOT EXISTS (
          SELECT 1 FROM dbo.ServiceDispatch d JOIN dbo.ServiceOrder otherOrder ON otherOrder.OrderId = d.OrderId
          WHERE d.WorkerId = w.WorkerId AND d.OrderId <> o.OrderId AND d.AcceptedAt IS NOT NULL
              AND d.ClosedAt IS NULL AND otherOrder.AppointmentStart < o.AppointmentEnd
              AND otherOrder.AppointmentEnd > o.AppointmentStart
      )
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_ServiceOrderAction
    @OrderId int, @Action varchar(24), @WorkerId int = NULL, @Reason nvarchar(500) = NULL,
    @ActorId int = NULL, @Latitude decimal(9,6) = NULL, @Longitude decimal(9,6) = NULL,
    @NewStart datetime2(0) = NULL, @NewEnd datetime2(0) = NULL, @FeedbackScore tinyint = NULL,
    @Now datetime2(0) = NULL, @FenceMeters int = 150
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Now = COALESCE(@Now, SYSUTCDATETIME());
    IF NULLIF(TRIM(@Reason), N'') IS NULL SET @Reason = NULL;
    DECLARE @ArchiveNo varchar(20) = (SELECT ArchiveNo FROM dbo.ServiceOrder WHERE OrderId = @OrderId);
    IF @ArchiveNo IS NULL THROW 51212, N'订单不存在。', 1;

    BEGIN TRANSACTION;
    EXEC dbo.usp_ServiceLock 'archive', @ArchiveNo;
    DECLARE @Status varchar(24), @Start datetime2(0), @End datetime2(0), @PlanId int,
            @SiteLat decimal(9,6), @SiteLng decimal(9,6), @ServiceTypeId int, @CommunityId int, @Deadline datetime2(0);
    SELECT @Status = Status, @Start = AppointmentStart, @End = AppointmentEnd, @PlanId = PlanId,
           @SiteLat = Latitude, @SiteLng = Longitude, @ServiceTypeId = ServiceTypeId,
           @CommunityId = CommunityId, @Deadline = DispatchDeadline
    FROM dbo.ServiceOrder WHERE OrderId = @OrderId;

    DECLARE @DispatchId int, @AssignedWorker int, @ShiftId int, @OfferExpiresAt datetime2(0), @AcceptedAt datetime2(0);
    SELECT @DispatchId = DispatchId, @AssignedWorker = WorkerId, @ShiftId = ShiftId,
           @OfferExpiresAt = OfferExpiresAt, @AcceptedAt = AcceptedAt
    FROM dbo.ServiceDispatch WHERE OrderId = @OrderId AND ClosedAt IS NULL;

    -- 按编号顺序锁定涉及的护工，名额检查与接受操作占用同一把锁。
    DECLARE @FirstWorker int = COALESCE(@AssignedWorker, @WorkerId), @SecondWorker int = @WorkerId;
    IF @WorkerId < @FirstWorker
        SELECT @FirstWorker = @WorkerId, @SecondWorker = @AssignedWorker;
    DECLARE @WorkerKey nvarchar(40);
    IF @FirstWorker IS NOT NULL
    BEGIN
        SET @WorkerKey = CONVERT(nvarchar(40), @FirstWorker);
        EXEC dbo.usp_ServiceLock 'worker', @WorkerKey;
    END;
    IF @SecondWorker IS NOT NULL AND @SecondWorker <> @FirstWorker
    BEGIN
        SET @WorkerKey = CONVERT(nvarchar(40), @SecondWorker);
        EXEC dbo.usp_ServiceLock 'worker', @WorkerKey;
    END;

    DECLARE @Today date = CONVERT(date, DATEADD(hour, 8, @Now));
    DECLARE @StartOn date = CONVERT(date, DATEADD(hour, 8, IIF(@Action = 'RESCHEDULE', @NewStart, @Start)));
    DECLARE @EndOn date = CONVERT(date, DATEADD(hour, 8, IIF(@Action = 'RESCHEDULE', @NewEnd, @End)));
    DECLARE @AssessmentValidThrough date, @AbilityLevel nvarchar(20);
    SELECT TOP (1) @AssessmentValidThrough = ValidThrough, @AbilityLevel = AbilityLevel
    FROM dbo.AbilityAssessment WHERE ArchiveNo = @ArchiveNo AND AssessmentDate <= @Today
    ORDER BY AssessmentDate DESC, AssessmentId DESC;

    DECLARE @CanProceed bit = 0;
    IF @AssessmentValidThrough >= @Today AND @AssessmentValidThrough >= @EndOn AND EXISTS (
        SELECT 1 FROM dbo.ElderArchive e JOIN dbo.CarePlan p ON p.ArchiveNo = e.ArchiveNo
        JOIN dbo.CarePackage k ON k.PackageId = p.PackageId AND k.AbilityLevel = @AbilityLevel
        JOIN dbo.CarePackageService ps ON ps.PackageId = k.PackageId AND ps.ServiceTypeId = @ServiceTypeId
        WHERE e.ArchiveNo = @ArchiveNo AND e.IsActive = 1 AND e.CommunityId = @CommunityId
          AND p.PlanId = @PlanId AND p.Status = 'ACTIVE' AND p.StartsOn <= @StartOn AND p.EndsOn >= @EndOn
    ) SET @CanProceed = 1;

    IF @Action = 'DISPATCH'
    BEGIN
        IF @Status NOT IN ('NEW','POOL','OFFERED','ACCEPTED') OR @Start <= @Now OR @CanProceed = 0 OR @WorkerId IS NULL
            THROW 51213, N'订单状态、预约日期或照护条件不允许派单。', 1;
        IF @DispatchId IS NOT NULL
        BEGIN
            IF @Reason IS NULL THROW 51213, N'改派须填写原因。', 1;
            UPDATE dbo.ServiceDispatch SET ClosedAt = @Now, CloseReason = @Reason WHERE DispatchId = @DispatchId;
        END;
        SET @ShiftId = (SELECT TOP (1) ShiftId FROM dbo.fn_EligibleServiceShifts(@OrderId)
                        WHERE WorkerId = @WorkerId ORDER BY ShiftId);
        IF @ShiftId IS NULL THROW 51214, N'所选护工资质、覆盖范围、排班或名额不符合要求。', 1;
        SET @OfferExpiresAt = IIF(@Start < DATEADD(minute, 30, @Now), @Start, DATEADD(minute, 30, @Now));
        INSERT dbo.ServiceDispatch(OrderId, WorkerId, ShiftId, OfferedAt, OfferExpiresAt)
        VALUES (@OrderId, @WorkerId, @ShiftId, @Now, @OfferExpiresAt);
        UPDATE dbo.ServiceOrder SET Status = 'OFFERED', ReviewReason = NULL WHERE OrderId = @OrderId;
    END
    ELSE IF @Action = 'ACCEPT'
    BEGIN
        IF @Status <> 'OFFERED' OR @AssignedWorker IS NULL OR @WorkerId IS NULL OR @AssignedWorker <> @WorkerId
            OR @OfferExpiresAt <= @Now OR @CanProceed = 0
            THROW 51215, N'当前护工没有可接受的派单，或评估、预约已失效。', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.fn_EligibleServiceShifts(@OrderId) WHERE ShiftId = @ShiftId)
            THROW 51214, N'接单时护工资质、排班或名额已变化。', 1;
        UPDATE dbo.ServiceDispatch SET AcceptedAt = @Now WHERE DispatchId = @DispatchId;
        UPDATE dbo.ServiceOrder SET Status = 'ACCEPTED' WHERE OrderId = @OrderId;
    END
    ELSE IF @Action IN ('CHECK_IN','CHECK_OUT')
    BEGIN
        IF @AssignedWorker IS NULL OR @WorkerId IS NULL OR @AssignedWorker <> @WorkerId
            THROW 51216, N'只有实际接单护工可签到签退。', 1;
        IF (@Latitude IS NULL AND @Longitude IS NOT NULL) OR (@Latitude IS NOT NULL AND @Longitude IS NULL)
            THROW 51216, N'请同时填写模拟纬度和经度，或同时留空。', 1;
        SET @Latitude = COALESCE(@Latitude, @SiteLat);
        SET @Longitude = COALESCE(@Longitude, @SiteLng);
        IF @Latitude NOT BETWEEN -90 AND 90 OR @Longitude NOT BETWEEN -180 AND 180 OR @FenceMeters <= 0
            THROW 51216, N'签到签退坐标或围栏参数无效。', 1;
        DECLARE @InFence bit = IIF(geography::Point(@Latitude, @Longitude, 4326)
            .STDistance(geography::Point(@SiteLat, @SiteLng, 4326)) <= @FenceMeters, 1, 0);
        DECLARE @InShift bit = IIF(EXISTS (SELECT 1 FROM dbo.WorkerShift WHERE ShiftId = @ShiftId
            AND StartsAt <= @Now AND EndsAt >= @Now AND IsOpen = 1), 1, 0);
        IF @Action = 'CHECK_IN'
        BEGIN
            IF @Status <> 'ACCEPTED' OR @AcceptedAt IS NULL OR @CanProceed = 0
                THROW 51217, N'仅有效且已接单的预约可签到，评估过期的订单需复核。', 1;
            IF @Now < @Start OR @Now >= @End OR NOT EXISTS (
                SELECT 1 FROM dbo.CarePlan WHERE PlanId = @PlanId AND Status = 'ACTIVE'
                    AND StartsOn <= @Today AND EndsOn >= @Today
            )
                THROW 51217, N'仅预约时段和照护计划有效期内可签到。', 1;
            IF EXISTS (SELECT 1 FROM dbo.ServiceVisit WHERE WorkerId = @WorkerId AND CheckOutAt IS NULL)
                THROW 51217, N'请先签退该护工正在进行的服务。', 1;
            IF NOT EXISTS (SELECT 1 FROM dbo.WorkerService s JOIN dbo.Worker w ON w.WorkerId = s.WorkerId
                           WHERE s.WorkerId = @WorkerId AND s.ServiceTypeId = @ServiceTypeId
                               AND s.ValidFrom <= @Today AND s.ValidThrough >= @Today AND w.IsActive = 1)
                OR EXISTS (SELECT 1 FROM dbo.WorkerRestriction WHERE WorkerId = @WorkerId AND ResolvedAt IS NULL)
                THROW 51214, N'护工资质失效或尚有整改限制。', 1;
            INSERT dbo.ServiceVisit(OrderId, DispatchId, WorkerId, CheckInAt, InLatitude, InLongitude, InFence, InShift,
                                    WorkStatus, SubsidyCategory, SubsidyAbilityLevel)
            SELECT @OrderId, @DispatchId, @WorkerId, @Now, @Latitude, @Longitude, @InFence, @InShift,
                   'OPEN', SubsidyCategory, @AbilityLevel
            FROM dbo.ElderArchive WHERE ArchiveNo = @ArchiveNo;
            UPDATE dbo.ServiceOrder SET Status = 'IN_SERVICE' WHERE OrderId = @OrderId;
        END
        ELSE
        BEGIN
            IF @Status <> 'IN_SERVICE' OR @Reason IS NULL
                THROW 51217, N'服务进行中才能签退，签退需要填写服务记录。', 1;
            UPDATE visit SET CheckOutAt = @Now, OutLatitude = @Latitude, OutLongitude = @Longitude,
                OutFence = @InFence, OutShift = @InShift, ServiceRecord = @Reason,
                ExpiredDuringVisit = IIF(@AssessmentValidThrough >= @Today, ExpiredDuringVisit, 1),
                WorkStatus = IIF(review.Reason IS NULL, 'VALID', 'REVIEW'),
                EffectiveMinutes = IIF(review.Reason IS NULL, DATEDIFF(minute, visit.CheckInAt, @Now), NULL),
                ReviewReason = review.Reason
            FROM dbo.ServiceVisit visit
            CROSS APPLY (VALUES (NULLIF(CONCAT_WS(N'；',
                CASE WHEN @Now > @End THEN N'签退晚于预约结束时间' END,
                CASE WHEN visit.InFence = 0 OR @InFence = 0 THEN N'签到或签退超出定位围栏' END,
                CASE WHEN visit.InShift = 0 OR @InShift = 0 THEN N'签到或签退超出班次范围' END
            ), N''))) review(Reason)
            WHERE visit.OrderId = @OrderId AND visit.CheckOutAt IS NULL;
            UPDATE dbo.ServiceDispatch SET ClosedAt = @Now, CloseReason = N'服务完成' WHERE DispatchId = @DispatchId;
            UPDATE dbo.ServiceOrder SET Status = 'AWAITING_CONFIRMATION' WHERE OrderId = @OrderId;
        END;
    END
    ELSE IF @Action = 'CONFIRM'
    BEGIN
        IF @Status <> 'AWAITING_CONFIRMATION' OR @Reason IS NULL OR NOT EXISTS (
            SELECT 1 FROM dbo.AppUser WHERE UserId = @ActorId AND Role IN ('family','resident')
                AND Active = 1 AND ArchiveNo = @ArchiveNo
        )
            THROW 51218, N'仅待确认的服务可由老人本人或关联家属签字。', 1;
        UPDATE dbo.ServiceVisit SET ConfirmedAt = @Now, ConfirmedBy = @ActorId, ConfirmationText = LEFT(@Reason, 200),
            ConfirmationHash = dbo.fn_ServiceConfirmationHash(@OrderId, @ActorId, @Now, LEFT(@Reason, 200))
        WHERE OrderId = @OrderId AND CheckOutAt IS NOT NULL AND ServiceRecord IS NOT NULL AND ConfirmedAt IS NULL;
        IF @@ROWCOUNT <> 1 THROW 51218, N'签退和服务记录尚未完成。', 1;
        UPDATE dbo.ServiceOrder SET Status = 'COMPLETED' WHERE OrderId = @OrderId;
    END
    ELSE IF @Action = 'FEEDBACK'
    BEGIN
        IF @Status <> 'COMPLETED' OR @FeedbackScore IS NULL OR @FeedbackScore NOT BETWEEN 1 AND 5
            THROW 51218, N'评价需要已完成的订单和 1 到 5 分。', 1;
        UPDATE dbo.ServiceVisit SET FeedbackScore = @FeedbackScore, Feedback = LEFT(@Reason, 300) WHERE OrderId = @OrderId;
    END
    ELSE IF @Action = 'COMPLAIN'
    BEGIN
        IF @Status <> 'COMPLETED' OR @Reason IS NULL OR @ActorId IS NULL
            THROW 51218, N'服务投诉需要已完成订单和投诉内容。', 1;
        UPDATE dbo.ServiceVisit SET ComplaintText = LEFT(@Reason, 300), ComplainedAt = @Now, ComplainedBy = @ActorId
        WHERE OrderId = @OrderId AND ComplainedAt IS NULL;
        IF @@ROWCOUNT <> 1 THROW 51218, N'该订单已有一条服务投诉。', 1;
    END
    ELSE IF @Action = 'COMPLAINT_RESOLVE'
    BEGIN
        IF @Reason IS NULL OR @ActorId IS NULL THROW 51218, N'请填写投诉的处理结果。', 1;
        UPDATE dbo.ServiceVisit SET ComplaintResolution = LEFT(@Reason, 300),
            ComplaintResolvedAt = @Now, ComplaintResolvedBy = @ActorId
        WHERE OrderId = @OrderId AND ComplainedAt IS NOT NULL AND ComplaintResolvedAt IS NULL;
        IF @@ROWCOUNT <> 1 THROW 51218, N'该订单没有待处理的投诉。', 1;
    END
    ELSE IF @Action IN ('WORK_APPROVE','WORK_REJECT')
    BEGIN
        IF @Reason IS NULL THROW 51219, N'工时审核须填写理由。', 1;
        UPDATE dbo.ServiceVisit SET WorkStatus = IIF(@Action = 'WORK_APPROVE', 'VALID', 'REJECTED'),
            ReviewReason = LEFT(@Reason, 250), EffectiveMinutes = IIF(@Action = 'WORK_APPROVE', DATEDIFF(minute, CheckInAt, CheckOutAt), NULL)
        WHERE OrderId = @OrderId AND WorkStatus = 'REVIEW' AND CheckOutAt IS NOT NULL;
        IF @@ROWCOUNT <> 1 THROW 51219, N'订单没有待复核工时。', 1;
    END
    ELSE IF @Action = 'REVIEW_APPROVE'
    BEGIN
        IF @Status <> 'REVIEW' OR @Reason IS NULL OR @AssessmentValidThrough IS NULL OR @AssessmentValidThrough < @Today
            THROW 51220, N'人工复核需要恢复有效评估并填写理由。', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.CarePlan WHERE PlanId = @PlanId AND Status = 'ACTIVE')
            THROW 51220, N'请先复核并恢复照护计划。', 1;
        IF @Start <= @Now OR @CanProceed = 0
        BEGIN
            UPDATE dbo.ServiceDispatch SET ClosedAt = @Now, CloseReason = N'复核后重新预约' WHERE DispatchId = @DispatchId;
            UPDATE dbo.ServiceOrder SET Status = 'RESCHEDULE', ReviewReason = LEFT(@Reason, 250) WHERE OrderId = @OrderId;
        END
        ELSE
            UPDATE dbo.ServiceOrder SET Status = IIF(@AcceptedAt IS NULL, 'POOL', 'ACCEPTED'), ReviewReason = LEFT(@Reason, 250)
            WHERE OrderId = @OrderId;
    END
    ELSE IF @Action = 'RESCHEDULE'
    BEGIN
        IF @Status NOT IN ('RESCHEDULE','POOL') OR @NewStart IS NULL OR @NewEnd IS NULL
            OR @NewStart <= @Now OR @NewEnd <= @NewStart OR @CanProceed = 0
            THROW 51221, N'重新预约需要未来时段及有效的评估、照护计划和社区地址。', 1;
        UPDATE o SET Status = 'NEW', AppointmentStart = @NewStart, AppointmentEnd = @NewEnd, ReviewReason = NULL,
            Price = IIF(t.Unit = N'次', t.Rate, t.Rate * DATEDIFF(minute, @NewStart, @NewEnd) / 60.0),
            DispatchDeadline = DATEADD(minute, 30, @Now)
        FROM dbo.ServiceOrder o JOIN dbo.ServiceType t ON t.ServiceTypeId = o.ServiceTypeId WHERE o.OrderId = @OrderId;
    END
    ELSE IF @Action = 'CANCEL'
    BEGIN
        IF @Status NOT IN ('NEW','POOL','OFFERED','ACCEPTED','REVIEW','RESCHEDULE') OR @Reason IS NULL
            THROW 51222, N'当前状态不能取消，取消须填写原因。', 1;
        UPDATE dbo.ServiceDispatch SET ClosedAt = @Now, CloseReason = LEFT(@Reason, 250) WHERE DispatchId = @DispatchId;
        UPDATE dbo.ServiceOrder SET Status = 'CANCELLED', ReviewReason = LEFT(@Reason, 250) WHERE OrderId = @OrderId;
    END
    ELSE THROW 51223, N'未知订单操作。', 1;
    COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ProcessServiceTimeouts @Now datetime2(0) = NULL AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Now = COALESCE(@Now, SYSUTCDATETIME());
    DECLARE @Today date = CONVERT(date, DATEADD(hour, 8, @Now));
    DECLARE @ArchiveNo varchar(20), @ValidThrough date;
    DECLARE pending CURSOR LOCAL FAST_FORWARD FOR
        SELECT ArchiveNo FROM dbo.CarePlan WHERE Status IN ('ACTIVE','PAUSED')
        UNION
        SELECT ArchiveNo FROM dbo.ServiceOrder WHERE Status IN ('NEW','OFFERED','POOL','ACCEPTED','IN_SERVICE');
    OPEN pending;
    FETCH NEXT FROM pending INTO @ArchiveNo;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRANSACTION;
        EXEC dbo.usp_ServiceLock 'archive', @ArchiveNo;
        SET @ValidThrough = (SELECT TOP (1) ValidThrough FROM dbo.AbilityAssessment
                            WHERE ArchiveNo = @ArchiveNo AND AssessmentDate <= @Today
                            ORDER BY AssessmentDate DESC, AssessmentId DESC);
        UPDATE dbo.CarePlan SET Status = 'ENDED', ChangedReason = N'计划周期结束'
        WHERE ArchiveNo = @ArchiveNo AND Status IN ('ACTIVE','PAUSED') AND EndsOn < @Today;
        IF @ValidThrough IS NULL OR @ValidThrough < @Today
        BEGIN
            UPDATE dbo.CarePlan SET Status = 'PAUSED', ChangedReason = N'能力评估到期，待人工复核'
            WHERE ArchiveNo = @ArchiveNo AND Status = 'ACTIVE';
            UPDATE v SET ExpiredDuringVisit = 1 FROM dbo.ServiceVisit v
            JOIN dbo.ServiceOrder o ON o.OrderId = v.OrderId
            WHERE o.ArchiveNo = @ArchiveNo AND o.Status = 'IN_SERVICE' AND v.ExpiredDuringVisit = 0;
            UPDATE d SET ClosedAt = @Now, CloseReason = N'评估过期结束待接派单'
            FROM dbo.ServiceDispatch d JOIN dbo.ServiceOrder o ON o.OrderId = d.OrderId
            WHERE o.ArchiveNo = @ArchiveNo AND o.Status = 'OFFERED' AND d.ClosedAt IS NULL AND d.OfferedAt <= @Now;
            UPDATE dbo.ServiceOrder SET Status = 'REVIEW', ReviewReason = N'评估过期，待人工复核'
            WHERE ArchiveNo = @ArchiveNo AND Status IN ('NEW','OFFERED','POOL','ACCEPTED');
        END;
        UPDATE o SET Status = 'REVIEW', ReviewReason = N'档案归属社区已变，需人工复核'
        FROM dbo.ServiceOrder o JOIN dbo.ElderArchive e ON e.ArchiveNo = o.ArchiveNo
        WHERE o.ArchiveNo = @ArchiveNo AND o.Status IN ('NEW','POOL','OFFERED','ACCEPTED') AND o.CommunityId <> e.CommunityId;
        UPDATE d SET ClosedAt = @Now, CloseReason = N'预约已结束，待重新预约'
        FROM dbo.ServiceDispatch d JOIN dbo.ServiceOrder o ON o.OrderId = d.OrderId
        WHERE o.ArchiveNo = @ArchiveNo AND o.Status IN ('NEW','POOL','OFFERED','ACCEPTED')
          AND o.AppointmentEnd <= @Now AND d.ClosedAt IS NULL AND d.OfferedAt <= @Now;
        UPDATE dbo.ServiceOrder SET Status = 'RESCHEDULE', ReviewReason = N'预约已结束，待重新预约'
        WHERE ArchiveNo = @ArchiveNo AND Status IN ('NEW','POOL','OFFERED','ACCEPTED') AND AppointmentEnd <= @Now;
        UPDATE o SET Status = 'POOL', ReviewReason = N'派单超过接单时限'
        FROM dbo.ServiceOrder o JOIN dbo.ServiceDispatch d ON d.OrderId = o.OrderId
        WHERE o.ArchiveNo = @ArchiveNo AND o.Status = 'OFFERED' AND d.ClosedAt IS NULL AND d.OfferExpiresAt <= @Now;
        UPDATE d SET ClosedAt = @Now, CloseReason = N'派单超过接单时限'
        FROM dbo.ServiceDispatch d JOIN dbo.ServiceOrder o ON o.OrderId = d.OrderId
        WHERE o.ArchiveNo = @ArchiveNo AND o.Status = 'POOL' AND d.ClosedAt IS NULL AND d.OfferExpiresAt <= @Now;
        UPDATE dbo.ServiceOrder SET Status = 'POOL', ReviewReason = N'订单超过自动派单时限'
        WHERE ArchiveNo = @ArchiveNo AND Status = 'NEW' AND DispatchDeadline <= @Now;
        COMMIT;
        FETCH NEXT FROM pending INTO @ArchiveNo;
    END;
    CLOSE pending;
    DEALLOCATE pending;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ChangeCarePlan @PlanId int, @Action varchar(12), @Reason nvarchar(250),
    @ActingCommunityId int = NULL AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @ArchiveNo varchar(20) = (SELECT ArchiveNo FROM dbo.CarePlan WHERE PlanId = @PlanId);
    IF @ArchiveNo IS NULL OR NULLIF(TRIM(@Reason), N'') IS NULL
        THROW 51205, N'计划或审核理由无效。', 1;
    BEGIN TRANSACTION;
    EXEC dbo.usp_ServiceLock 'archive', @ArchiveNo;
    IF @ActingCommunityId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.ElderArchive
        WHERE ArchiveNo = @ArchiveNo AND CommunityId = @ActingCommunityId)
        THROW 51205, N'档案已移出当前社区。', 1;
    IF @Action = 'END'
        UPDATE dbo.CarePlan SET Status = 'ENDED', ChangedReason = @Reason WHERE PlanId = @PlanId AND Status <> 'ENDED';
    ELSE IF @Action = 'RESUME'
        UPDATE p SET Status = 'ACTIVE', ChangedReason = @Reason
        FROM dbo.CarePlan p JOIN dbo.CarePackage k ON p.PackageId = k.PackageId
        JOIN dbo.v_CurrentAbilityAssessment a ON a.ArchiveNo = p.ArchiveNo AND a.AbilityLevel = k.AbilityLevel
        WHERE p.PlanId = @PlanId AND p.Status = 'PAUSED' AND a.AssessmentStatus = N'有效'
            AND p.EndsOn >= CONVERT(date, DATEADD(hour, 8, SYSUTCDATETIME()));
    ELSE THROW 51205, N'未知计划操作。', 1;
    IF @@ROWCOUNT <> 1 THROW 51205, N'计划状态或最新评估不允许该操作。', 1;
    COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CreateWorkerShift @WorkerId int, @StartsAt datetime2(0),
    @EndsAt datetime2(0), @Capacity int AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @WorkerKey nvarchar(40) = CONVERT(nvarchar(40), @WorkerId);
    IF @StartsAt IS NULL OR @EndsAt IS NULL OR @EndsAt <= @StartsAt OR @Capacity < 1
        THROW 51206, N'请填写有效时段和接单上限。', 1;
    BEGIN TRANSACTION;
    EXEC dbo.usp_ServiceLock 'worker', @WorkerKey;
    IF NOT EXISTS (SELECT 1 FROM dbo.Worker WHERE WorkerId = @WorkerId AND IsActive = 1)
        THROW 51206, N'护工须为在岗状态。', 1;
    IF EXISTS (SELECT 1 FROM dbo.WorkerShift WHERE WorkerId = @WorkerId AND IsOpen = 1
               AND StartsAt < @EndsAt AND EndsAt > @StartsAt)
        THROW 51207, N'同一护工的班次不能重叠。', 1;
    INSERT dbo.WorkerShift(WorkerId, StartsAt, EndsAt, Capacity) VALUES (@WorkerId, @StartsAt, @EndsAt, @Capacity);
    COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_SetWorkerCredential @WorkerId int, @ServiceTypeId int,
    @CredentialNo nvarchar(60), @ValidFrom date, @ValidThrough date,
    @CredentialType nvarchar(40) = NULL, @CredentialLevel nvarchar(40) = NULL AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @WorkerKey nvarchar(40) = CONVERT(nvarchar(40), @WorkerId);
    IF NULLIF(TRIM(@CredentialNo), N'') IS NULL OR @ValidFrom IS NULL OR @ValidThrough IS NULL
       OR @ValidThrough < @ValidFrom
        THROW 51208, N'请填写有效证书编号和日期。', 1;
    SET @CredentialType = NULLIF(TRIM(@CredentialType), N'');
    SET @CredentialLevel = NULLIF(TRIM(@CredentialLevel), N'');
    IF (@CredentialType IS NULL AND @CredentialLevel IS NOT NULL)
       OR (@CredentialType IS NOT NULL AND @CredentialLevel IS NULL)
        THROW 51208, N'证书类型和等级应同时填写。', 1;
    BEGIN TRANSACTION;
    EXEC dbo.usp_ServiceLock 'worker', @WorkerKey;
    UPDATE dbo.WorkerService SET CredentialNo = @CredentialNo, ValidFrom = @ValidFrom, ValidThrough = @ValidThrough,
        CredentialType = COALESCE(@CredentialType, CredentialType), CredentialLevel = COALESCE(@CredentialLevel, CredentialLevel)
    WHERE WorkerId = @WorkerId AND ServiceTypeId = @ServiceTypeId;
    IF @@ROWCOUNT = 0
        INSERT dbo.WorkerService(WorkerId, ServiceTypeId, CredentialNo, ValidFrom, ValidThrough, CredentialType, CredentialLevel)
        VALUES (@WorkerId, @ServiceTypeId, @CredentialNo, @ValidFrom, @ValidThrough, @CredentialType, @CredentialLevel);
    COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_FollowUpDispatchTimeout
    @ActorId int, @DispatchId int, @Note nvarchar(250)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NULLIF(TRIM(@Note), N'') IS NULL
        THROW 51225, N'请填写机构跟进说明。', 1;
    UPDATE dispatch SET TimeoutFollowedUpAt=SYSUTCDATETIME(), TimeoutFollowedUpBy=@ActorId,
        TimeoutFollowupNote=TRIM(@Note)
    FROM dbo.ServiceDispatch dispatch
    JOIN dbo.Worker worker ON worker.WorkerId=dispatch.WorkerId
    JOIN dbo.AppUser actor ON actor.UserId=@ActorId AND actor.Role='agency' AND actor.Active=1
        AND actor.AgencyId=worker.AgencyId
    WHERE dispatch.DispatchId=@DispatchId AND dispatch.AcceptedAt IS NULL
      AND dispatch.ClosedAt>=dispatch.OfferExpiresAt AND dispatch.CloseReason=N'派单超过接单时限'
      AND dispatch.TimeoutFollowedUpAt IS NULL;
    IF @@ROWCOUNT<>1
        THROW 51225, N'派单不属于本机构、未超时或已有跟进记录。', 1;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CreateServiceOrder @ArchiveNo varchar(20), @ServiceTypeId int,
    @AppointmentStart datetime2(0), @AppointmentEnd datetime2(0), @Address nvarchar(200),
    @Latitude decimal(9,6), @Longitude decimal(9,6), @Channel varchar(12), @Now datetime2(0) = NULL,
    @ActingCommunityId int = NULL AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Now = COALESCE(@Now, SYSUTCDATETIME());
    IF @AppointmentStart IS NULL OR @AppointmentEnd IS NULL
       OR @AppointmentStart <= @Now OR @AppointmentEnd <= @AppointmentStart
        THROW 51209, N'预约应在未来且结束时刻晚于开始时刻。', 1;
    SET @Address = NULLIF(TRIM(@Address), N'');
    IF (@Address IS NOT NULL AND (@Latitude IS NULL OR @Longitude IS NULL))
       OR (@Latitude IS NULL AND @Longitude IS NOT NULL) OR (@Latitude IS NOT NULL AND @Longitude IS NULL)
        THROW 51210, N'自填服务地址时须同时填写纬度和经度；使用档案地址时两项可同时留空。', 1;
    BEGIN TRANSACTION;
    EXEC dbo.usp_ServiceLock 'archive', @ArchiveNo;
    DECLARE @CommunityId int, @CenterLat decimal(9,6), @CenterLng decimal(9,6), @Radius int;
    SELECT @CommunityId = e.CommunityId, @Address = COALESCE(@Address, e.Address),
        @Latitude = COALESCE(@Latitude, e.Latitude), @Longitude = COALESCE(@Longitude, e.Longitude),
        @CenterLat = c.Latitude, @CenterLng = c.Longitude, @Radius = c.RadiusMeters
    FROM dbo.ElderArchive e JOIN dbo.Community c ON c.CommunityId = e.CommunityId
    WHERE e.ArchiveNo = @ArchiveNo AND e.IsActive = 1
      AND (@ActingCommunityId IS NULL OR e.CommunityId = @ActingCommunityId);
    IF @CommunityId IS NULL OR @Latitude IS NULL OR @Longitude IS NULL OR @CenterLat IS NULL OR @CenterLng IS NULL
        OR @Radius IS NULL OR @Latitude NOT BETWEEN -90 AND 90 OR @Longitude NOT BETWEEN -180 AND 180
        THROW 51210, N'档案状态或社区服务位置无效。', 1;
    IF geography::Point(@Latitude, @Longitude, 4326).STDistance(geography::Point(@CenterLat, @CenterLng, 4326)) > @Radius
        THROW 51210, N'服务地址超出所属社区范围。', 1;
    DECLARE @StartOn date = CONVERT(date, DATEADD(hour, 8, @AppointmentStart));
    DECLARE @EndOn date = CONVERT(date, DATEADD(hour, 8, @AppointmentEnd));
    DECLARE @Today date = CONVERT(date, DATEADD(hour, 8, @Now));
    DECLARE @AbilityLevel nvarchar(20), @ValidThrough date;
    SELECT TOP (1) @AbilityLevel = AbilityLevel, @ValidThrough = ValidThrough
    FROM dbo.AbilityAssessment WHERE ArchiveNo = @ArchiveNo AND AssessmentDate <= @Today
    ORDER BY AssessmentDate DESC, AssessmentId DESC;
    DECLARE @PlanId int = (
        SELECT TOP (1) p.PlanId FROM dbo.CarePlan p
        JOIN dbo.CarePackageService ps ON ps.PackageId = p.PackageId AND ps.ServiceTypeId = @ServiceTypeId
        JOIN dbo.CarePackage k ON k.PackageId = p.PackageId AND k.AbilityLevel = @AbilityLevel
        WHERE p.ArchiveNo = @ArchiveNo AND p.Status = 'ACTIVE' AND p.StartsOn <= @StartOn AND p.EndsOn >= @EndOn
          AND @ValidThrough >= @Today AND @ValidThrough >= @EndOn ORDER BY p.PlanId DESC
    );
    IF @PlanId IS NULL THROW 51211, N'预约时段或服务项目没有有效的评估和照护计划覆盖。', 1;
    INSERT dbo.ServiceOrder(OrderNo, ArchiveNo, PlanId, ServiceTypeId, CommunityId, Status, Price,
                            AppointmentStart, AppointmentEnd, Address, Latitude, Longitude, Channel, DispatchDeadline)
    SELECT CONCAT('SO-', CONVERT(varchar(24), CRYPT_GEN_RANDOM(12), 2)), @ArchiveNo, @PlanId,
        ServiceTypeId, @CommunityId, 'NEW', IIF(Unit = N'次', Rate, Rate * DATEDIFF(minute, @AppointmentStart, @AppointmentEnd) / 60.0),
        @AppointmentStart, @AppointmentEnd, @Address, @Latitude, @Longitude, @Channel, DATEADD(minute, 30, @Now)
    FROM dbo.ServiceType WHERE ServiceTypeId = @ServiceTypeId;
    COMMIT;
END;
GO
