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

IF OBJECT_ID(N'dbo.ServiceOrder', N'U') IS NULL OR OBJECT_ID(N'dbo.v_SubsidyEligibleOrder', N'V') IS NULL
    THROW 51800, N'请先执行服务、派单和工时模块。', 1;

BEGIN TRANSACTION;

IF OBJECT_ID(N'dbo.SubsidyPolicy', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.SubsidyPolicy (
        PolicyId int IDENTITY(1, 1) PRIMARY KEY,
        PolicyName nvarchar(100) NOT NULL,
        District nvarchar(80) NOT NULL,
        ServiceTypeId int NOT NULL REFERENCES dbo.ServiceType(ServiceTypeId),
        ValidFrom date NOT NULL,
        ValidThrough date NOT NULL,
        HourlyRate decimal(10, 2) NOT NULL,
        MaxPerOrder decimal(10, 2) NOT NULL,
        CONSTRAINT CK_SubsidyPolicy_Dates CHECK (ValidThrough >= ValidFrom),
        CONSTRAINT CK_SubsidyPolicy_Rates CHECK (HourlyRate > 0 AND MaxPerOrder > 0),
        CONSTRAINT UQ_SubsidyPolicy_Start UNIQUE (District, ServiceTypeId, ValidFrom)
    );
END;

IF OBJECT_ID(N'dbo.SubsidyClaim', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.SubsidyClaim (
        ClaimId int IDENTITY(1, 1) PRIMARY KEY,
        ArchiveNo varchar(20) NOT NULL REFERENCES dbo.ElderArchive(ArchiveNo),
        CommunityId int NOT NULL REFERENCES dbo.Community(CommunityId),
        ServiceTypeId int NOT NULL REFERENCES dbo.ServiceType(ServiceTypeId),
        PeriodMonth date NOT NULL,
        Status varchar(12) NOT NULL CONSTRAINT DF_SubsidyClaim_Status DEFAULT 'DRAFT',
        TotalAmount decimal(14, 2) NOT NULL CONSTRAINT DF_SubsidyClaim_Total DEFAULT 0,
        SubmittedAt datetime2(0) NULL,
        ApprovedAt datetime2(0) NULL,
        PaidAt datetime2(0) NULL,
        ChangedBy int NULL REFERENCES dbo.AppUser(UserId),
        ChangeNote nvarchar(250) NOT NULL CONSTRAINT DF_SubsidyClaim_Note DEFAULT N'',
        CONSTRAINT UQ_SubsidyClaim_Period UNIQUE (ArchiveNo, ServiceTypeId, PeriodMonth),
        CONSTRAINT CK_SubsidyClaim_Period CHECK (DAY(PeriodMonth) = 1),
        CONSTRAINT CK_SubsidyClaim_Status CHECK (Status IN ('DRAFT','STREET','CIVIL','RETURNED','APPROVED','PAID')),
        CONSTRAINT CK_SubsidyClaim_Total CHECK (TotalAmount >= 0)
    );
    CREATE INDEX IX_SubsidyClaim_Community_Status_Period
        ON dbo.SubsidyClaim(CommunityId, Status, PeriodMonth);
END;

IF OBJECT_ID(N'dbo.SubsidyClaimOrder', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.SubsidyClaimOrder (
        ClaimId int NOT NULL REFERENCES dbo.SubsidyClaim(ClaimId),
        OrderId int NOT NULL REFERENCES dbo.ServiceOrder(OrderId),
        PolicyId int NOT NULL REFERENCES dbo.SubsidyPolicy(PolicyId),
        ServiceCompletedAt datetime2(0) NOT NULL,
        ConfirmedAt datetime2(0) NOT NULL,
        EffectiveMinutes int NOT NULL,
        OrderPrice decimal(14, 2) NOT NULL,
        HourlyRate decimal(10, 2) NOT NULL,
        MaxPerOrder decimal(10, 2) NOT NULL,
        Amount decimal(14, 2) NOT NULL,
        CONSTRAINT PK_SubsidyClaimOrder PRIMARY KEY (ClaimId, OrderId),
        CONSTRAINT UQ_SubsidyClaimOrder_Order UNIQUE (OrderId),
        CONSTRAINT CK_SubsidyClaimOrder_Values CHECK (
            EffectiveMinutes > 0 AND OrderPrice >= 0 AND Amount >= 0
            AND Amount <= OrderPrice AND Amount <= MaxPerOrder
        )
    );
END;

IF OBJECT_ID(N'dbo.SubsidyClaimLog', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.SubsidyClaimLog (
        LogId bigint IDENTITY(1, 1) PRIMARY KEY,
        ClaimId int NOT NULL REFERENCES dbo.SubsidyClaim(ClaimId),
        PreviousStatus varchar(12) NULL,
        CurrentStatus varchar(12) NOT NULL,
        ActorId int NULL REFERENCES dbo.AppUser(UserId),
        ChangedAt datetime2(0) NOT NULL CONSTRAINT DF_SubsidyClaimLog_At DEFAULT SYSUTCDATETIME(),
        Note nvarchar(250) NOT NULL,
        TotalAmount decimal(14, 2) NOT NULL,
        OrderSnapshot nvarchar(max) NOT NULL
    );
    CREATE INDEX IX_SubsidyClaimLog_Claim ON dbo.SubsidyClaimLog(ClaimId, LogId);
END;

IF OBJECT_ID(N'dbo.ServiceInspection', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ServiceInspection (
        InspectionId int IDENTITY(1, 1) PRIMARY KEY,
        OrderId int NULL REFERENCES dbo.ServiceOrder(OrderId),
        WorkerId int NOT NULL REFERENCES dbo.Worker(WorkerId),
        ReviewDistrict nvarchar(80) NOT NULL,
        InspectorId int NULL REFERENCES dbo.AppUser(UserId),
        Score tinyint NOT NULL,
        Finding nvarchar(250) NOT NULL,
        RestrictionId int NULL REFERENCES dbo.WorkerRestriction(RestrictionId),
        Status varchar(12) NOT NULL,
        InspectedAt datetime2(0) NOT NULL,
        Correction nvarchar(250) NULL,
        CorrectedAt datetime2(0) NULL,
        ClosedAt datetime2(0) NULL,
        ChangedBy int NULL REFERENCES dbo.AppUser(UserId),
        CONSTRAINT CK_ServiceInspection_Score CHECK (Score BETWEEN 0 AND 100),
        CONSTRAINT CK_ServiceInspection_Status CHECK (Status IN ('OPEN', 'CORRECTED', 'CLOSED'))
    );
    CREATE INDEX IX_ServiceInspection_District_Status ON dbo.ServiceInspection(ReviewDistrict, Status, InspectedAt);
END;

IF OBJECT_ID(N'dbo.ServiceInspectionLog', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ServiceInspectionLog (
        LogId bigint IDENTITY(1, 1) PRIMARY KEY,
        InspectionId int NOT NULL REFERENCES dbo.ServiceInspection(InspectionId),
        PreviousStatus varchar(12) NULL,
        CurrentStatus varchar(12) NOT NULL,
        ActorId int NULL REFERENCES dbo.AppUser(UserId),
        ChangedAt datetime2(0) NOT NULL CONSTRAINT DF_ServiceInspectionLog_At DEFAULT SYSUTCDATETIME(),
        Correction nvarchar(250) NULL
    );
END;

COMMIT TRANSACTION;
GO

CREATE OR ALTER TRIGGER dbo.tr_SubsidyClaim_Log ON dbo.SubsidyClaim
AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.SubsidyClaimLog (
        ClaimId, PreviousStatus, CurrentStatus, ActorId, Note, TotalAmount, OrderSnapshot
    )
    SELECT new.ClaimId, old.Status, new.Status, new.ChangedBy, new.ChangeNote, new.TotalAmount,
           (SELECT line.OrderId, line.PolicyId, line.EffectiveMinutes, line.OrderPrice,
                   line.HourlyRate, line.MaxPerOrder, line.Amount, line.ServiceCompletedAt, line.ConfirmedAt
            FROM dbo.SubsidyClaimOrder line
            WHERE line.ClaimId = new.ClaimId ORDER BY line.OrderId FOR JSON PATH)
    FROM inserted new
    LEFT JOIN deleted old ON old.ClaimId = new.ClaimId
    WHERE (old.ClaimId IS NULL AND new.Status <> 'DRAFT') OR old.Status <> new.Status;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_ServiceInspection_Log ON dbo.ServiceInspection
AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.ServiceInspectionLog (InspectionId, PreviousStatus, CurrentStatus, ActorId, Correction)
    SELECT new.InspectionId, old.Status, new.Status, new.ChangedBy, new.Correction
    FROM inserted new
    LEFT JOIN deleted old ON old.InspectionId = new.InspectionId
    WHERE old.InspectionId IS NULL OR old.Status <> new.Status;
END;
GO

CREATE OR ALTER VIEW dbo.v_SubsidyClaimSummary AS
SELECT claim.ClaimId, claim.ArchiveNo, elder.FullName, claim.CommunityId, community.Name AS CommunityName,
       community.District, claim.ServiceTypeId, service.Name AS ServiceName,
       claim.PeriodMonth, claim.Status, claim.TotalAmount, claim.ChangeNote,
       claim.SubmittedAt, claim.ApprovedAt, claim.PaidAt,
       (SELECT COUNT(*) FROM dbo.SubsidyClaimOrder line WHERE line.ClaimId = claim.ClaimId) AS OrderCount
FROM dbo.SubsidyClaim claim
JOIN dbo.ElderArchive elder ON elder.ArchiveNo = claim.ArchiveNo
JOIN dbo.Community community ON community.CommunityId = claim.CommunityId
JOIN dbo.ServiceType service ON service.ServiceTypeId = claim.ServiceTypeId;
GO

CREATE OR ALTER VIEW dbo.v_SubsidyClaimTrace AS
SELECT line.ClaimId, line.OrderId, claim.ArchiveNo, claim.ServiceTypeId,
       line.PolicyId, policy.PolicyName, line.ServiceCompletedAt, line.ConfirmedAt,
       line.EffectiveMinutes, line.OrderPrice, line.HourlyRate, line.MaxPerOrder, line.Amount
FROM dbo.SubsidyClaimOrder line
JOIN dbo.SubsidyClaim claim ON claim.ClaimId = line.ClaimId
JOIN dbo.SubsidyPolicy policy ON policy.PolicyId = line.PolicyId;
GO

CREATE OR ALTER VIEW dbo.v_QualityInspectionSummary AS
SELECT inspection.InspectionId, inspection.OrderId, inspection.WorkerId, worker.Name AS WorkerName,
       agency.AgencyId, agency.Name AS AgencyName, inspection.ReviewDistrict,
       inspection.Score, inspection.Finding, inspection.Status, inspection.InspectedAt,
       inspection.Correction, inspection.CorrectedAt, inspection.ClosedAt, inspection.RestrictionId
FROM dbo.ServiceInspection inspection
JOIN dbo.Worker worker ON worker.WorkerId = inspection.WorkerId
JOIN dbo.Agency agency ON agency.AgencyId = worker.AgencyId;
GO

CREATE OR ALTER VIEW dbo.v_DistrictServiceCoverage AS
SELECT community.CommunityId, community.Name AS CommunityName, community.District,
       COUNT(DISTINCT elder.ArchiveNo) AS ElderCount,
       COUNT(DISTINCT CASE WHEN orders.Status = 'COMPLETED' THEN orders.ArchiveNo END) AS ServedElderCount,
       COUNT(DISTINCT CASE WHEN orders.Status = 'COMPLETED' THEN orders.OrderId END) AS CompletedOrderCount
FROM dbo.Community community
LEFT JOIN dbo.ElderArchive elder ON elder.CommunityId = community.CommunityId AND elder.IsActive = 1
LEFT JOIN dbo.ServiceOrder orders ON orders.CommunityId = community.CommunityId AND orders.ArchiveNo = elder.ArchiveNo
GROUP BY community.CommunityId, community.Name, community.District;
GO

CREATE OR ALTER PROCEDURE dbo.usp_SaveSubsidyPolicy
    @ActorId int, @PolicyName nvarchar(100), @District nvarchar(80), @ServiceTypeId int,
    @ValidFrom date, @ValidThrough date, @HourlyRate decimal(10, 2), @MaxPerOrder decimal(10, 2),
    @ClosePrevious bit = 0
AS
BEGIN
    SET XACT_ABORT ON;
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;
        IF NOT EXISTS (
            SELECT 1 FROM dbo.AppUser
            WHERE UserId = @ActorId AND Active = 1 AND Role = 'civil' AND District = @District
        )
            THROW 51801, N'只有本辖区的民政账号可以维护补贴政策。', 1;
        IF NULLIF(TRIM(@PolicyName), N'') IS NULL OR @ValidFrom IS NULL
           OR @ValidThrough IS NULL OR @ValidThrough < @ValidFrom
            THROW 51802, N'请填写政策名称和有效日期。', 1;

        IF @ClosePrevious = 1
        BEGIN
            DECLARE @PreviousPolicyId int, @Today date = CONVERT(date, DATEADD(hour, 8, SYSUTCDATETIME()));
            IF @ValidFrom <= @Today
                THROW 51815, N'接续现有政策时，新政策须从未来日期生效。', 1;

            SELECT @PreviousPolicyId = PolicyId
            FROM dbo.SubsidyPolicy WITH (UPDLOCK, HOLDLOCK)
            WHERE District = @District AND ServiceTypeId = @ServiceTypeId
              AND ValidFrom < @ValidFrom AND ValidThrough >= @ValidFrom;

            IF EXISTS (
                SELECT 1 FROM dbo.SubsidyClaimOrder
                WHERE PolicyId = @PreviousPolicyId
                  AND ServiceCompletedAt >= DATEADD(hour, -8, CONVERT(datetime2(0), @ValidFrom))
            )
                THROW 51816, N'旧政策已有该日期之后的核算记录。', 1;

            UPDATE dbo.SubsidyPolicy
            SET ValidThrough = DATEADD(day, -1, @ValidFrom)
            WHERE PolicyId = @PreviousPolicyId;
        END;
        IF EXISTS (
            SELECT 1 FROM dbo.SubsidyPolicy WITH (UPDLOCK, HOLDLOCK)
            WHERE District = @District AND ServiceTypeId = @ServiceTypeId
              AND ValidFrom <= @ValidThrough AND ValidThrough >= @ValidFrom
        )
            THROW 51803, N'同一辖区和项目的补贴政策有效期不能重叠。', 1;

        INSERT dbo.SubsidyPolicy (PolicyName, District, ServiceTypeId, ValidFrom, ValidThrough, HourlyRate, MaxPerOrder)
        VALUES (@PolicyName, @District, @ServiceTypeId, @ValidFrom, @ValidThrough, @HourlyRate, @MaxPerOrder);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_SubmitSubsidyClaim
    @ActorId int, @ArchiveNo varchar(20), @CommunityId int, @ServiceTypeId int,
    @PeriodMonth date, @OrderIdsJson nvarchar(max)
AS
BEGIN
    SET XACT_ABORT ON;
    SET NOCOUNT ON;

    IF @PeriodMonth IS NULL OR DAY(@PeriodMonth) <> 1 OR ISNULL(ISJSON(@OrderIdsJson, ARRAY), 0) <> 1
        THROW 51804, N'请选择有效月份和至少一笔服务订单。', 1;

    DECLARE @RequestedOrders TABLE (OrderId int NULL);
    INSERT @RequestedOrders (OrderId)
    SELECT TRY_CONVERT(int, value) FROM OPENJSON(@OrderIdsJson);
    DECLARE @RequestedCount int = (SELECT COUNT(*) FROM @RequestedOrders);
    IF @RequestedCount = 0 OR EXISTS (SELECT 1 FROM @RequestedOrders WHERE OrderId IS NULL OR OrderId <= 0)
        OR EXISTS (SELECT OrderId FROM @RequestedOrders GROUP BY OrderId HAVING COUNT(*) > 1)
        THROW 51805, N'订单清单为空、无效或包含重复订单。', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        IF NOT EXISTS (
            SELECT 1 FROM dbo.AppUser
            WHERE UserId = @ActorId AND Active = 1 AND Role = 'community' AND CommunityId = @CommunityId
        )
            THROW 51806, N'该申报不属于当前社区。', 1;

        DECLARE @ClaimId int, @CurrentStatus varchar(12), @ExistingCommunityId int;
        SELECT @ClaimId = ClaimId, @CurrentStatus = Status, @ExistingCommunityId = CommunityId
        FROM dbo.SubsidyClaim WITH (UPDLOCK, HOLDLOCK)
        WHERE ArchiveNo = @ArchiveNo AND ServiceTypeId = @ServiceTypeId AND PeriodMonth = @PeriodMonth;

        IF @ClaimId IS NOT NULL AND (@CurrentStatus <> 'RETURNED' OR @ExistingCommunityId <> @CommunityId)
            THROW 51807, N'同一老人、项目和月份已有申报，只有原社区可以修改退回的申报。', 1;

        DECLARE @MonthStartUtc datetime2(0) = DATEADD(hour, -8, CONVERT(datetime2(0), @PeriodMonth));
        DECLARE @NextMonthStartUtc datetime2(0) = DATEADD(hour, -8, CONVERT(datetime2(0), DATEADD(month, 1, @PeriodMonth)));
        DECLARE @Lines TABLE (
            OrderId int PRIMARY KEY, PolicyId int NOT NULL, ServiceCompletedAt datetime2(0) NOT NULL,
            ConfirmedAt datetime2(0) NOT NULL, EffectiveMinutes int NOT NULL, OrderPrice decimal(14, 2) NOT NULL,
            HourlyRate decimal(10, 2) NOT NULL, MaxPerOrder decimal(10, 2) NOT NULL, Amount decimal(14, 2) NOT NULL
        );
        INSERT @Lines
        SELECT visit.OrderId, policy.PolicyId, visit.CheckOutAt, visit.ConfirmedAt, visit.EffectiveMinutes,
               visit.Price, policy.HourlyRate, policy.MaxPerOrder, calculation.Amount
        FROM @RequestedOrders requested
        JOIN dbo.v_SubsidyEligibleOrder visit ON visit.OrderId = requested.OrderId
        JOIN dbo.Community community ON community.CommunityId = visit.CommunityId
        CROSS APPLY (
            SELECT TOP (1) candidate.PolicyId, candidate.HourlyRate, candidate.MaxPerOrder
            FROM dbo.SubsidyPolicy candidate
            WHERE candidate.District = community.District AND candidate.ServiceTypeId = visit.ServiceTypeId
              AND CONVERT(date, DATEADD(hour, 8, visit.CheckOutAt)) BETWEEN candidate.ValidFrom AND candidate.ValidThrough
            ORDER BY candidate.ValidFrom DESC
        ) policy
        CROSS APPLY (
            SELECT MIN(value) AS Amount
            FROM (VALUES (CONVERT(decimal(14, 2), policy.HourlyRate * visit.EffectiveMinutes / 60.0)),
                         (visit.Price), (policy.MaxPerOrder)) amounts(value)
        ) calculation
        WHERE visit.ArchiveNo = @ArchiveNo AND visit.CommunityId = @CommunityId AND visit.ServiceTypeId = @ServiceTypeId
          AND visit.CheckOutAt >= @MonthStartUtc AND visit.CheckOutAt < @NextMonthStartUtc
          AND visit.ConfirmedAt IS NOT NULL AND visit.EffectiveMinutes > 0
          AND NOT EXISTS (
              SELECT 1 FROM dbo.SubsidyClaimOrder existing WITH (UPDLOCK, HOLDLOCK)
              WHERE existing.OrderId = visit.OrderId AND (@ClaimId IS NULL OR existing.ClaimId <> @ClaimId)
          );

        IF (SELECT COUNT(*) FROM @Lines) <> @RequestedCount
            THROW 51808, N'订单须属于同一老人、社区、项目和服务月份，并具备签字、有效工时及适用政策。', 1;

        IF @ClaimId IS NULL
        BEGIN
            INSERT dbo.SubsidyClaim (ArchiveNo, CommunityId, ServiceTypeId, PeriodMonth, ChangedBy)
            VALUES (@ArchiveNo, @CommunityId, @ServiceTypeId, @PeriodMonth, @ActorId);
            SET @ClaimId = CONVERT(int, SCOPE_IDENTITY());
        END
        ELSE
            DELETE FROM dbo.SubsidyClaimOrder WHERE ClaimId = @ClaimId;

        INSERT dbo.SubsidyClaimOrder (
            ClaimId, OrderId, PolicyId, ServiceCompletedAt, ConfirmedAt, EffectiveMinutes,
            OrderPrice, HourlyRate, MaxPerOrder, Amount
        )
        SELECT @ClaimId, OrderId, PolicyId, ServiceCompletedAt, ConfirmedAt, EffectiveMinutes,
               OrderPrice, HourlyRate, MaxPerOrder, Amount
        FROM @Lines;

        UPDATE dbo.SubsidyClaim
        SET Status = 'STREET', TotalAmount = (SELECT SUM(Amount) FROM @Lines),
            SubmittedAt = SYSUTCDATETIME(), ChangedBy = @ActorId,
            ChangeNote = CASE WHEN @CurrentStatus = 'RETURNED' THEN N'修改后重新提交' ELSE N'提交申报' END
        WHERE ClaimId = @ClaimId;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ProgressSubsidyClaim
    @ActorId int, @ClaimId int, @Action varchar(10), @Note nvarchar(250)
AS
BEGIN
    SET XACT_ABORT ON;
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @Status varchar(12), @Role varchar(16);
        SELECT @Status = claim.Status, @Role = actor.Role
        FROM dbo.SubsidyClaim claim WITH (UPDLOCK, HOLDLOCK)
        JOIN dbo.Community community ON community.CommunityId = claim.CommunityId
        JOIN dbo.AppUser actor ON actor.District = community.District AND actor.UserId = @ActorId AND actor.Active = 1
        WHERE claim.ClaimId = @ClaimId;

        DECLARE @NextStatus varchar(12) = CASE
            WHEN @Role = 'street' AND @Status = 'STREET' AND @Action = 'approve' THEN 'CIVIL'
            WHEN @Role = 'civil' AND @Status = 'CIVIL' AND @Action = 'approve' THEN 'APPROVED'
            WHEN @Role = 'civil' AND @Status = 'APPROVED' AND @Action = 'pay' THEN 'PAID'
            WHEN (@Role = 'street' AND @Status = 'STREET' OR @Role = 'civil' AND @Status = 'CIVIL')
                AND @Action = 'return' THEN 'RETURNED'
        END;

        IF @NextStatus IS NULL
            THROW 51809, N'当前账号或申报状态不允许执行该操作。', 1;
        IF @NextStatus = 'RETURNED' AND NULLIF(TRIM(@Note), N'') IS NULL
            THROW 51810, N'请填写退回原因。', 1;

        UPDATE dbo.SubsidyClaim
        SET Status = @NextStatus, ChangedBy = @ActorId,
            ChangeNote = COALESCE(NULLIF(TRIM(@Note), N''), CASE @NextStatus
                WHEN 'CIVIL' THEN N'街道审核通过'
                WHEN 'APPROVED' THEN N'民政审核通过'
                ELSE N'已模拟拨付' END),
            ApprovedAt = CASE WHEN @NextStatus = 'APPROVED' THEN SYSUTCDATETIME() ELSE ApprovedAt END,
            PaidAt = CASE WHEN @NextStatus = 'PAID' THEN SYSUTCDATETIME() ELSE PaidAt END
        WHERE ClaimId = @ClaimId;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RegisterInspection
    @ActorId int, @TargetType varchar(10), @TargetId int, @Score int, @Finding nvarchar(250)
AS
BEGIN
    SET XACT_ABORT ON;
    SET NOCOUNT ON;
    IF @Score IS NULL OR @Score NOT BETWEEN 0 AND 100 OR NULLIF(TRIM(@Finding), N'') IS NULL
        THROW 51811, N'请填写 0 至 100 分的评价和检查结论。', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @WorkerId int, @OrderId int, @District nvarchar(80), @RestrictionId int;
        DECLARE @Now datetime2(0) = SYSUTCDATETIME();

        IF @TargetType = 'order'
            SELECT @WorkerId = visit.WorkerId, @OrderId = orders.OrderId, @District = community.District
            FROM dbo.ServiceOrder orders
            JOIN dbo.ServiceVisit visit ON visit.OrderId = orders.OrderId
            JOIN dbo.Community community ON community.CommunityId = orders.CommunityId
            WHERE orders.OrderId = @TargetId AND orders.Status = 'COMPLETED';
        ELSE IF @TargetType = 'worker'
            SELECT @WorkerId = worker.WorkerId, @District = agency.District
            FROM dbo.Worker worker JOIN dbo.Agency agency ON agency.AgencyId = worker.AgencyId
            WHERE worker.WorkerId = @TargetId;

        IF @WorkerId IS NULL OR NOT EXISTS (
            SELECT 1 FROM dbo.AppUser
            WHERE UserId = @ActorId AND Active = 1 AND Role IN ('street','civil') AND District = @District
        )
            THROW 51812, N'检查对象不存在或不属于当前辖区。', 1;

        IF @Score < 60
        BEGIN
            DECLARE @WorkerKey nvarchar(40) = CONVERT(nvarchar(40), @WorkerId);
            EXEC dbo.usp_ServiceLock 'worker', @WorkerKey;
            INSERT dbo.WorkerRestriction (WorkerId, Reason, CreatedAt)
            VALUES (@WorkerId, @Finding, @Now);
            SET @RestrictionId = CONVERT(int, SCOPE_IDENTITY());
        END;

        INSERT dbo.ServiceInspection (
            OrderId, WorkerId, ReviewDistrict, InspectorId, Score, Finding, RestrictionId,
            Status, InspectedAt, ClosedAt, ChangedBy
        )
        VALUES (@OrderId, @WorkerId, @District, @ActorId, @Score, @Finding, @RestrictionId,
                CASE WHEN @RestrictionId IS NULL THEN 'CLOSED' ELSE 'OPEN' END, @Now,
                CASE WHEN @RestrictionId IS NULL THEN @Now END, @ActorId);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ProgressInspection
    @ActorId int, @InspectionId int, @Action varchar(10), @Correction nvarchar(250)
AS
BEGIN
    SET XACT_ABORT ON;
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @Status varchar(12), @Role varchar(16), @RestrictionId int, @WorkerId int;
        DECLARE @Now datetime2(0) = SYSUTCDATETIME();
        SELECT @Status = inspection.Status, @Role = actor.Role,
               @RestrictionId = inspection.RestrictionId, @WorkerId = inspection.WorkerId
        FROM dbo.ServiceInspection inspection WITH (UPDLOCK, HOLDLOCK)
        JOIN dbo.Worker worker ON worker.WorkerId = inspection.WorkerId
        JOIN dbo.AppUser actor ON actor.UserId = @ActorId AND actor.Active = 1
            AND (actor.Role = 'agency' AND actor.AgencyId = worker.AgencyId
                 OR actor.Role IN ('street','civil') AND actor.District = inspection.ReviewDistrict)
        WHERE inspection.InspectionId = @InspectionId;

        IF @Role = 'agency' AND @Status = 'OPEN' AND @Action = 'correct'
        BEGIN
            IF NULLIF(TRIM(@Correction), N'') IS NULL
                THROW 51813, N'请填写整改内容。', 1;
            UPDATE dbo.ServiceInspection
            SET Status = 'CORRECTED', Correction = @Correction, CorrectedAt = @Now, ChangedBy = @ActorId
            WHERE InspectionId = @InspectionId;
        END
        ELSE IF @Role IN ('street','civil') AND @Status = 'CORRECTED' AND @Action = 'close'
        BEGIN
            DECLARE @WorkerKey nvarchar(40) = CONVERT(nvarchar(40), @WorkerId);
            EXEC dbo.usp_ServiceLock 'worker', @WorkerKey;
            UPDATE dbo.ServiceInspection SET Status = 'CLOSED', ClosedAt = @Now, ChangedBy = @ActorId
            WHERE InspectionId = @InspectionId;
            UPDATE dbo.WorkerRestriction SET ResolvedAt = @Now WHERE RestrictionId = @RestrictionId;
        END
        ELSE IF @Role IN ('street','civil') AND @Status = 'CORRECTED' AND @Action = 'reopen'
        BEGIN
            IF NULLIF(TRIM(@Correction), N'') IS NULL
                THROW 51817, N'请填写复查退回原因。', 1;
            UPDATE dbo.ServiceInspection
            SET Status = 'OPEN', Correction = @Correction, CorrectedAt = NULL, ChangedBy = @ActorId
            WHERE InspectionId = @InspectionId;
        END
        ELSE
            THROW 51814, N'当前账号或检查状态不允许执行该操作。', 1;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
