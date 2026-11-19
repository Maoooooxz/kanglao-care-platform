USE [KanglaoCourse];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET ARITHABORT ON;
SET NUMERIC_ROUNDABORT OFF;

IF OBJECT_ID(N'dbo.AppUser', N'U') IS NULL OR OBJECT_ID(N'dbo.ServiceDispatch', N'U') IS NULL
    THROW 51700, N'请先安装账户和服务派单模块。', 1;

BEGIN TRANSACTION;

IF OBJECT_ID(N'dbo.HealthDevice', N'U') IS NULL
    CREATE TABLE dbo.HealthDevice (
        DeviceId int IDENTITY PRIMARY KEY,
        DeviceCode varchar(24) NOT NULL UNIQUE,
        DeviceType varchar(12) NOT NULL,
        IsEnabled bit NOT NULL DEFAULT 1
    );

IF OBJECT_ID(N'dbo.HealthBinding', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.HealthBinding (
        BindingId int IDENTITY PRIMARY KEY,
        DeviceId int NOT NULL REFERENCES dbo.HealthDevice (DeviceId),
        ArchiveNo varchar(20) NOT NULL REFERENCES dbo.ElderArchive (ArchiveNo),
        StartsAt datetime2(0) NOT NULL,
        EndsAt datetime2(0) NULL,
        CONSTRAINT UQ_HealthBinding_Start UNIQUE (DeviceId, StartsAt),
        CONSTRAINT CK_HealthBinding_Period CHECK (EndsAt > StartsAt)
    );
    CREATE UNIQUE INDEX UX_HealthBinding_Open ON dbo.HealthBinding (DeviceId) WHERE EndsAt IS NULL;
END;

IF OBJECT_ID(N'dbo.HealthThreshold', N'U') IS NULL
    CREATE TABLE dbo.HealthThreshold (
        MetricCode varchar(24) PRIMARY KEY,
        MetricName nvarchar(60) NOT NULL,
        UnitLabel nvarchar(16) NOT NULL,
        MinimumValue decimal(10, 2) NOT NULL,
        MaximumValue decimal(10, 2) NOT NULL,
        TriageMinutes smallint NOT NULL CHECK (TriageMinutes > 0),
        Severity tinyint NOT NULL CHECK (Severity BETWEEN 1 AND 3),
        CHECK (MaximumValue >= MinimumValue)
    );

IF OBJECT_ID(N'dbo.HealthResponseRule', N'U') IS NULL
    CREATE TABLE dbo.HealthResponseRule (
        CommunityId int NOT NULL REFERENCES dbo.Community (CommunityId),
        Severity tinyint NOT NULL CHECK (Severity BETWEEN 1 AND 3),
        ResponseMinutes smallint NOT NULL CHECK (ResponseMinutes > 0),
        PRIMARY KEY (CommunityId, Severity)
    );

IF OBJECT_ID(N'dbo.HealthReading', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.HealthReading (
        ReadingId int IDENTITY PRIMARY KEY,
        BindingId int NOT NULL REFERENCES dbo.HealthBinding (BindingId),
        PacketKey varchar(64) NOT NULL UNIQUE,
        MetricCode varchar(24) NOT NULL REFERENCES dbo.HealthThreshold (MetricCode),
        MeasuredValue decimal(10, 2) NOT NULL,
        CapturedAt datetime2(0) NOT NULL,
        ReceivedAt datetime2(0) NOT NULL,
        SourceType varchar(12) NOT NULL CHECK (SourceType IN ('DEVICE', 'MANUAL')),
        IsAbnormal bit NOT NULL,
        CHECK (CapturedAt <= ReceivedAt)
    );
    CREATE INDEX IX_HealthReading_BindingTime ON dbo.HealthReading (BindingId, CapturedAt DESC);
END;

IF OBJECT_ID(N'dbo.HealthAlert', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.HealthAlert (
        AlertId int IDENTITY PRIMARY KEY,
        ReadingId int NOT NULL UNIQUE REFERENCES dbo.HealthReading (ReadingId),
        Severity tinyint NOT NULL CHECK (Severity BETWEEN 1 AND 3),
        State varchar(12) NOT NULL DEFAULT 'PENDING' CHECK (State IN ('PENDING', 'FALSE_ALARM', 'CONFIRMED', 'TIMEOUT')),
        OpenedAt datetime2(0) NOT NULL,
        TriageDeadline datetime2(0) NOT NULL,
        ReviewedAt datetime2(0) NULL,
        ReviewedBy int NULL REFERENCES dbo.AppUser (UserId),
        CHECK (TriageDeadline > OpenedAt),
        CHECK ((State = 'PENDING' AND ReviewedAt IS NULL AND ReviewedBy IS NULL)
            OR (State IN ('FALSE_ALARM', 'CONFIRMED') AND ReviewedAt IS NOT NULL AND ReviewedBy IS NOT NULL)
            OR (State = 'TIMEOUT' AND ReviewedAt IS NOT NULL AND ReviewedBy IS NULL))
    );
    CREATE INDEX IX_HealthAlert_Triage ON dbo.HealthAlert (State, TriageDeadline);
END;

IF OBJECT_ID(N'dbo.HealthEvent', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.HealthEvent (
        EventId int IDENTITY PRIMARY KEY,
        ArchiveNo varchar(20) NOT NULL REFERENCES dbo.ElderArchive (ArchiveNo),
        AlertId int NULL REFERENCES dbo.HealthAlert (AlertId),
        RequestKey varchar(64) NULL,
        SourceType varchar(12) NOT NULL CHECK (SourceType IN ('THRESHOLD', 'SOS', 'MANUAL')),
        Origin varchar(24) NOT NULL DEFAULT 'SYSTEM',
        Severity tinyint NOT NULL CHECK (Severity BETWEEN 1 AND 3),
        OpenedAt datetime2(0) NOT NULL,
        ResponseDeadline datetime2(0) NOT NULL,
        RespondedAt datetime2(0) NULL,
        RespondedBy int NULL REFERENCES dbo.AppUser (UserId),
        ArrivedAt datetime2(0) NULL,
        ClosedAt datetime2(0) NULL,
        Resolution nvarchar(400) NULL,
        EscalatedAt datetime2(0) NULL,
        LastActorId int NULL REFERENCES dbo.AppUser (UserId),
        CHECK ((SourceType = 'THRESHOLD' AND AlertId IS NOT NULL AND RequestKey IS NULL)
            OR (SourceType IN ('SOS', 'MANUAL') AND AlertId IS NULL AND RequestKey IS NOT NULL)),
        CHECK (ResponseDeadline > OpenedAt),
        CHECK ((RespondedAt IS NULL AND RespondedBy IS NULL)
            OR (RespondedAt IS NOT NULL AND RespondedAt >= OpenedAt AND RespondedBy IS NOT NULL)),
        CHECK (ArrivedAt IS NULL OR (RespondedAt IS NOT NULL AND ArrivedAt >= RespondedAt)),
        CHECK ((ClosedAt IS NULL AND Resolution IS NULL)
            OR (ClosedAt IS NOT NULL AND RespondedAt IS NOT NULL AND ClosedAt >= COALESCE(ArrivedAt, RespondedAt)
                AND Resolution IS NOT NULL AND LEN(Resolution) > 0)),
        CHECK (EscalatedAt IS NULL OR EscalatedAt >= ResponseDeadline)
    );
    CREATE UNIQUE INDEX UX_HealthEvent_Alert ON dbo.HealthEvent (AlertId) WHERE AlertId IS NOT NULL;
    CREATE UNIQUE INDEX UX_HealthEvent_Request ON dbo.HealthEvent (RequestKey) WHERE RequestKey IS NOT NULL;
    CREATE INDEX IX_HealthEvent_Response ON dbo.HealthEvent (ResponseDeadline)
        INCLUDE (RespondedAt, EscalatedAt, ArchiveNo, Severity) WHERE RespondedAt IS NULL AND EscalatedAt IS NULL;
END;

IF OBJECT_ID(N'dbo.HealthNotice', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.HealthNotice (
        NoticeId int IDENTITY PRIMARY KEY,
        RecipientUserId int NOT NULL REFERENCES dbo.AppUser (UserId),
        AlertId int NULL REFERENCES dbo.HealthAlert (AlertId),
        EventId int NULL REFERENCES dbo.HealthEvent (EventId),
        Kind varchar(12) NOT NULL CHECK (Kind IN ('TRIAGE', 'EVENT', 'ESCALATED')),
        CreatedAt datetime2(0) NOT NULL,
        ReadAt datetime2(0) NULL,
        CHECK ((Kind = 'TRIAGE' AND AlertId IS NOT NULL AND EventId IS NULL)
            OR (Kind IN ('EVENT', 'ESCALATED') AND AlertId IS NULL AND EventId IS NOT NULL))
    );
    CREATE UNIQUE INDEX UX_HealthNotice_Alert ON dbo.HealthNotice (RecipientUserId, AlertId) WHERE AlertId IS NOT NULL;
    CREATE UNIQUE INDEX UX_HealthNotice_Event ON dbo.HealthNotice (RecipientUserId, EventId, Kind) WHERE EventId IS NOT NULL;
END;

IF OBJECT_ID(N'dbo.HealthEventAudit', N'U') IS NULL
    CREATE TABLE dbo.HealthEventAudit (
        AuditId int IDENTITY PRIMARY KEY,
        EventId int NOT NULL REFERENCES dbo.HealthEvent (EventId),
        ActorUserId int NULL REFERENCES dbo.AppUser (UserId),
        ActionCode varchar(12) NOT NULL CHECK (ActionCode IN ('OPENED', 'RESPONDED', 'ARRIVED', 'CLOSED', 'ESCALATED')),
        OccurredAt datetime2(0) NOT NULL,
        Details nvarchar(400) NULL
    );

IF OBJECT_ID(N'dbo.CK_HealthDevice_Type', N'C') IS NULL
BEGIN
    DECLARE @OldDeviceCheck sysname = (SELECT TOP (1) name FROM sys.check_constraints
        WHERE parent_object_id=OBJECT_ID(N'dbo.HealthDevice') AND definition LIKE '%VITALS%' AND definition LIKE '%SOS%');
    IF @OldDeviceCheck IS NOT NULL
    BEGIN
        DECLARE @DropDeviceCheck nvarchar(max)=N'ALTER TABLE dbo.HealthDevice DROP CONSTRAINT '+QUOTENAME(@OldDeviceCheck);
        EXEC sys.sp_executesql @DropDeviceCheck;
    END;
    ALTER TABLE dbo.HealthDevice ADD CONSTRAINT CK_HealthDevice_Type
        CHECK (DeviceType IN ('VITALS','SOS','BP_MONITOR','ECG_PATCH','FALL_RADAR'));
END;
IF COL_LENGTH(N'dbo.HealthDevice', N'IsDemo') IS NULL
    ALTER TABLE dbo.HealthDevice ADD IsDemo bit NOT NULL CONSTRAINT DF_HealthDevice_Demo DEFAULT 0;
IF COL_LENGTH(N'dbo.HealthBinding', N'InstallationLocation') IS NULL
    ALTER TABLE dbo.HealthBinding ADD InstallationLocation nvarchar(120) NULL;
IF COL_LENGTH(N'dbo.HealthEvent', N'ReportKind') IS NULL
    ALTER TABLE dbo.HealthEvent ADD ReportKind varchar(12) NULL, ReportText nvarchar(400) NULL,
        CONSTRAINT CK_HealthEvent_Report CHECK (
            (ReportKind IS NULL AND ReportText IS NULL)
            OR (SourceType='MANUAL' AND ReportKind IS NOT NULL AND ReportKind IN ('HEALTH','HOME_RISK')
                AND ReportText IS NOT NULL AND LEN(ReportText)>0)
        );

COMMIT TRANSACTION;
GO

CREATE OR ALTER VIEW dbo.v_HealthAssignedWorker
AS
    SELECT service.ArchiveNo, dispatch.WorkerId
    FROM dbo.ServiceOrder AS service
    JOIN dbo.ServiceDispatch AS dispatch ON dispatch.OrderId = service.OrderId
    WHERE dispatch.AcceptedAt IS NOT NULL AND dispatch.ClosedAt IS NULL
    UNION
    SELECT ArchiveNo, ResponsibleWorkerId
    FROM dbo.CarePlan
    WHERE Status = 'ACTIVE' AND ResponsibleWorkerId IS NOT NULL
      AND CONVERT(date, DATEADD(hour, 8, SYSUTCDATETIME())) BETWEEN StartsOn AND EndsOn;
GO

CREATE OR ALTER FUNCTION dbo.fn_HealthArchiveScope (@UserId int)
RETURNS TABLE
AS
    RETURN (
        SELECT elder.ArchiveNo
        FROM dbo.ElderArchive AS elder
        JOIN dbo.Community AS community ON community.CommunityId = elder.CommunityId
        JOIN dbo.AppUser AS account ON account.UserId = @UserId AND account.Active = 1
        WHERE (account.Role = 'community' AND account.CommunityId = elder.CommunityId)
           OR (account.Role IN ('resident', 'family') AND account.ArchiveNo = elder.ArchiveNo)
           OR (account.Role IN ('street', 'civil') AND account.District = community.District)
           OR (account.Role = 'caregiver' AND EXISTS (
                SELECT 1 FROM dbo.v_HealthAssignedWorker AS assignment
                WHERE assignment.ArchiveNo = elder.ArchiveNo AND assignment.WorkerId = account.WorkerId
           ))
           OR (account.Role = 'agency' AND EXISTS (
                SELECT 1 FROM dbo.v_HealthAssignedWorker AS assignment
                JOIN dbo.Worker AS worker ON worker.WorkerId = assignment.WorkerId
                WHERE assignment.ArchiveNo = elder.ArchiveNo AND worker.AgencyId = account.AgencyId
           ))
    );
GO

CREATE OR ALTER FUNCTION dbo.fn_HealthNoticeRecipients(@ArchiveNo varchar(20))
RETURNS TABLE AS RETURN
(
    SELECT account.UserId
    FROM dbo.ElderArchive elder CROSS JOIN dbo.AppUser account
    WHERE elder.ArchiveNo=@ArchiveNo AND account.Active=1
      AND ((account.Role='community' AND account.CommunityId=elder.CommunityId)
        OR (account.Role IN ('resident','family') AND account.ArchiveNo=elder.ArchiveNo)
        OR (account.Role='caregiver' AND EXISTS (
            SELECT 1 FROM dbo.v_HealthAssignedWorker assignment
            WHERE assignment.ArchiveNo=elder.ArchiveNo AND assignment.WorkerId=account.WorkerId
        )))
);
GO

CREATE OR ALTER VIEW dbo.v_HealthDeviceBindings
AS
    SELECT binding.BindingId, device.DeviceId, device.DeviceCode, device.DeviceType, device.IsEnabled,
           binding.ArchiveNo, binding.StartsAt, binding.EndsAt, binding.InstallationLocation
    FROM dbo.HealthBinding AS binding
    JOIN dbo.HealthDevice AS device ON device.DeviceId = binding.DeviceId;
GO

CREATE OR ALTER VIEW dbo.v_HealthReadingHistory
AS
    SELECT reading.ReadingId, binding.ArchiveNo, device.DeviceCode, reading.PacketKey,
           reading.CapturedAt, reading.ReceivedAt, reading.MetricCode, threshold.MetricName,
           threshold.UnitLabel, reading.MeasuredValue, reading.IsAbnormal, reading.SourceType
    FROM dbo.HealthReading AS reading
    JOIN dbo.HealthBinding AS binding ON binding.BindingId = reading.BindingId
    JOIN dbo.HealthDevice AS device ON device.DeviceId = binding.DeviceId
    JOIN dbo.HealthThreshold AS threshold ON threshold.MetricCode = reading.MetricCode;
GO

CREATE OR ALTER VIEW dbo.v_HealthAlertQueue
AS
    SELECT alert.AlertId, reading.ArchiveNo, reading.ReadingId, reading.MetricName, reading.MeasuredValue,
           reading.UnitLabel, alert.State, alert.Severity, alert.OpenedAt, alert.TriageDeadline,
           alert.ReviewedAt, alert.ReviewedBy, evt.EventId
    FROM dbo.HealthAlert AS alert
    JOIN dbo.v_HealthReadingHistory AS reading ON reading.ReadingId = alert.ReadingId
    LEFT JOIN dbo.HealthEvent AS evt ON evt.AlertId = alert.AlertId;
GO

CREATE OR ALTER VIEW dbo.v_HealthEventOverview
AS
    SELECT evt.EventId, evt.ArchiveNo, elder.FullName, evt.AlertId, evt.SourceType, evt.Origin,
           evt.Severity, evt.OpenedAt, evt.ResponseDeadline, evt.RespondedAt, evt.RespondedBy,
           responder.DisplayName AS ResponderName, evt.ArrivedAt, evt.ClosedAt, evt.Resolution, evt.EscalatedAt,
           CASE WHEN evt.ClosedAt IS NOT NULL THEN 'CLOSED'
                WHEN evt.ArrivedAt IS NOT NULL THEN 'ARRIVED'
                WHEN evt.RespondedAt IS NOT NULL THEN 'RESPONDED'
                WHEN evt.EscalatedAt IS NOT NULL THEN 'ESCALATED'
                 ELSE 'OPEN' END AS State,
           evt.ReportKind, evt.ReportText
    FROM dbo.HealthEvent AS evt
    JOIN dbo.ElderArchive AS elder ON elder.ArchiveNo = evt.ArchiveNo
    LEFT JOIN dbo.AppUser AS responder ON responder.UserId = evt.RespondedBy;
GO

CREATE OR ALTER TRIGGER dbo.tr_HealthEvent_Audit
ON dbo.HealthEvent
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    INSERT dbo.HealthEventAudit (EventId, ActorUserId, ActionCode, OccurredAt, Details)
    SELECT evt.EventId, evt.LastActorId, change.ActionCode, change.OccurredAt, change.Details
    FROM inserted AS evt
    LEFT JOIN deleted AS old ON old.EventId = evt.EventId
    CROSS APPLY (VALUES
        ('OPENED', CASE WHEN old.EventId IS NULL THEN evt.OpenedAt END, CONVERT(nvarchar(400), evt.Origin)),
        ('RESPONDED', CASE WHEN old.RespondedAt IS NULL THEN evt.RespondedAt END, NULL),
        ('ARRIVED', CASE WHEN old.ArrivedAt IS NULL THEN evt.ArrivedAt END, NULL),
        ('CLOSED', CASE WHEN old.ClosedAt IS NULL THEN evt.ClosedAt END, evt.Resolution),
        ('ESCALATED', CASE WHEN old.EscalatedAt IS NULL THEN evt.EscalatedAt END, NULL)
    ) AS change (ActionCode, OccurredAt, Details)
    WHERE change.OccurredAt IS NOT NULL;

    INSERT dbo.HealthNotice (RecipientUserId, EventId, Kind, CreatedAt)
    SELECT account.UserId, evt.EventId, notice.Kind, notice.CreatedAt
    FROM inserted AS evt
    LEFT JOIN deleted AS old ON old.EventId = evt.EventId
    JOIN dbo.ElderArchive AS elder ON elder.ArchiveNo = evt.ArchiveNo
    JOIN dbo.Community AS community ON community.CommunityId = elder.CommunityId
    CROSS JOIN dbo.AppUser AS account
    CROSS APPLY (VALUES
        ('EVENT', CASE WHEN old.EventId IS NULL THEN evt.OpenedAt END),
        ('ESCALATED', CASE WHEN old.EscalatedAt IS NULL THEN evt.EscalatedAt END)
    ) AS notice (Kind, CreatedAt)
    WHERE notice.CreatedAt IS NOT NULL AND account.Active = 1
      AND ((account.Role = 'community' AND account.CommunityId = elder.CommunityId)
        OR (account.Role IN ('resident', 'family') AND account.ArchiveNo = elder.ArchiveNo)
        OR (account.Role = 'caregiver' AND EXISTS (
             SELECT 1 FROM dbo.v_HealthAssignedWorker AS assignment
             WHERE assignment.ArchiveNo = elder.ArchiveNo AND assignment.WorkerId = account.WorkerId
        ))
        OR (notice.Kind = 'ESCALATED' AND account.Role IN ('street', 'civil') AND account.District = community.District));
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RegisterHealthDevice
    @DeviceCode varchar(24), @DeviceType varchar(12), @ArchiveNo varchar(20), @ActorId int,
    @At datetime2(0) = NULL, @InstallationLocation nvarchar(120) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @At = COALESCE(@At, CONVERT(datetime2(0), SYSUTCDATETIME()));

    IF NOT EXISTS (SELECT 1 FROM dbo.AppUser WHERE UserId = @ActorId AND Role = 'community')
        OR NOT EXISTS (SELECT 1 FROM dbo.fn_HealthArchiveScope(@ActorId) WHERE ArchiveNo = @ArchiveNo)
        THROW 51701, N'只能为本社区老人登记设备。', 1;
    IF NULLIF(TRIM(@DeviceCode), '') IS NULL
        THROW 51701, N'设备编号不能为空。', 1;

    BEGIN TRANSACTION;
    INSERT dbo.HealthDevice (DeviceCode, DeviceType) VALUES (@DeviceCode, @DeviceType);
    INSERT dbo.HealthBinding (DeviceId, ArchiveNo, StartsAt, InstallationLocation)
    VALUES (CONVERT(int, SCOPE_IDENTITY()), @ArchiveNo, @At, NULLIF(TRIM(@InstallationLocation), N''));
    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_BindHealthDevice
    @DeviceCode varchar(24), @ArchiveNo varchar(20), @ActorId int = NULL, @At datetime2(0) = NULL,
    @InstallationLocation nvarchar(120) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @At = COALESCE(@At, CONVERT(datetime2(0), SYSUTCDATETIME()));

    IF @ActorId IS NOT NULL AND (NOT EXISTS (SELECT 1 FROM dbo.AppUser WHERE UserId = @ActorId AND Role = 'community')
        OR NOT EXISTS (SELECT 1 FROM dbo.fn_HealthArchiveScope(@ActorId) WHERE ArchiveNo = @ArchiveNo))
        THROW 51701, N'只能为本社区老人绑定设备。', 1;

    DECLARE @DeviceId int;
    BEGIN TRANSACTION;
    SELECT @DeviceId = DeviceId FROM dbo.HealthDevice WITH (UPDLOCK, HOLDLOCK) WHERE DeviceCode = @DeviceCode AND IsEnabled = 1;
    IF @DeviceId IS NULL THROW 51702, N'设备不存在或已停用。', 1;
    IF EXISTS (SELECT 1 FROM dbo.HealthBinding WHERE DeviceId = @DeviceId AND (EndsAt IS NULL OR EndsAt > @At))
        THROW 51703, N'设备的绑定时段重叠，请先解绑。', 1;
    IF @ActorId IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM dbo.HealthBinding AS old
        JOIN dbo.fn_HealthArchiveScope(@ActorId) AS scope ON scope.ArchiveNo = old.ArchiveNo
        WHERE old.BindingId = (SELECT TOP (1) BindingId FROM dbo.HealthBinding WHERE DeviceId = @DeviceId ORDER BY StartsAt DESC)
    )
        THROW 51701, N'只能重新绑定本社区此前登记的设备。', 1;
    INSERT dbo.HealthBinding (DeviceId, ArchiveNo, StartsAt, InstallationLocation)
    VALUES (@DeviceId, @ArchiveNo, @At, NULLIF(TRIM(@InstallationLocation), N''));
    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_UnbindHealthDevice
    @DeviceCode varchar(24), @ActorId int = NULL, @At datetime2(0) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @At = COALESCE(@At, CONVERT(datetime2(0), SYSUTCDATETIME()));
    DECLARE @DeviceId int, @BindingId int, @ArchiveNo varchar(20);

    BEGIN TRANSACTION;
    SELECT @DeviceId = DeviceId FROM dbo.HealthDevice WITH (UPDLOCK, HOLDLOCK) WHERE DeviceCode = @DeviceCode;
    SELECT @BindingId = BindingId, @ArchiveNo = ArchiveNo
    FROM dbo.HealthBinding WHERE DeviceId = @DeviceId AND EndsAt IS NULL AND StartsAt < @At;
    IF @BindingId IS NULL THROW 51704, N'没有可结束的设备绑定。', 1;
    IF @ActorId IS NOT NULL AND (NOT EXISTS (SELECT 1 FROM dbo.AppUser WHERE UserId = @ActorId AND Role = 'community')
        OR NOT EXISTS (SELECT 1 FROM dbo.fn_HealthArchiveScope(@ActorId) WHERE ArchiveNo = @ArchiveNo))
        THROW 51701, N'只能解除本社区老人的设备绑定。', 1;
    IF EXISTS (SELECT 1 FROM dbo.HealthReading WHERE BindingId = @BindingId AND CapturedAt >= @At)
        THROW 51704, N'解绑时间不能早于或等于已有读数时间。', 1;
    UPDATE dbo.HealthBinding SET EndsAt = @At WHERE BindingId = @BindingId;
    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RecordHealthReading
    @DeviceCode varchar(24), @PacketKey varchar(64), @MetricCode varchar(24), @MeasuredValue decimal(10, 2),
    @CapturedAt datetime2(0) = NULL, @ActorId int = NULL, @Now datetime2(0) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Now = COALESCE(@Now, CONVERT(datetime2(0), SYSUTCDATETIME()));
    DECLARE @ExplicitTime datetime2(0) = @CapturedAt;
    SET @CapturedAt = COALESCE(@CapturedAt, @Now);
    IF @CapturedAt > @Now OR NULLIF(TRIM(@PacketKey), '') IS NULL
        THROW 51705, N'请提供唯一的上传编号，采集时间不能晚于当前时刻。', 1;
    IF @ActorId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.AppUser WHERE UserId = @ActorId AND Role IN ('community', 'caregiver'))
        THROW 51701, N'当前账号不能上报体征。', 1;

    DECLARE @DeviceId int, @BindingId int, @ArchiveNo varchar(20), @ExistingId int,
            @Min decimal(10, 2), @Max decimal(10, 2), @TriageMinutes smallint, @Severity tinyint,
            @ReadingId int, @AlertId int;
    BEGIN TRANSACTION;
    SELECT @DeviceId = DeviceId FROM dbo.HealthDevice WITH (UPDLOCK, HOLDLOCK)
    WHERE DeviceCode = @DeviceCode AND IsEnabled = 1 AND DeviceType IN ('VITALS','BP_MONITOR','ECG_PATCH','FALL_RADAR');
    IF @DeviceId IS NULL THROW 51702, N'设备不存在、已停用或不支持体征上报。', 1;

    SELECT @ExistingId = reading.ReadingId, @ArchiveNo = binding.ArchiveNo
    FROM dbo.HealthReading AS reading
    JOIN dbo.HealthBinding AS binding ON binding.BindingId = reading.BindingId
    WHERE reading.PacketKey = @PacketKey AND binding.DeviceId = @DeviceId
      AND reading.MetricCode = @MetricCode AND reading.MeasuredValue = @MeasuredValue
      AND (@ExplicitTime IS NULL OR reading.CapturedAt = @ExplicitTime);
    IF @ExistingId IS NOT NULL
    BEGIN
        IF @ActorId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.fn_HealthArchiveScope(@ActorId) WHERE ArchiveNo = @ArchiveNo)
            THROW 51701, N'不能上报管理范围之外的老人体征。', 1;
        COMMIT TRANSACTION;
        RETURN;
    END;

    IF EXISTS (SELECT 1 FROM dbo.HealthReading WHERE PacketKey = @PacketKey)
        THROW 51705, N'该上传编号已用于其他读数。', 1;
    SELECT @BindingId = BindingId, @ArchiveNo = ArchiveNo
    FROM dbo.HealthBinding WHERE DeviceId = @DeviceId
      AND StartsAt <= @CapturedAt AND (EndsAt IS NULL OR @CapturedAt < EndsAt);
    IF @BindingId IS NULL THROW 51705, N'采集时刻设备没有绑定老人。', 1;
    IF @ActorId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.fn_HealthArchiveScope(@ActorId) WHERE ArchiveNo = @ArchiveNo)
        THROW 51701, N'不能上报管理范围之外的老人体征。', 1;

    SELECT @Min = MinimumValue, @Max = MaximumValue, @TriageMinutes = TriageMinutes, @Severity = Severity
    FROM dbo.HealthThreshold WHERE MetricCode = @MetricCode;
    IF @Severity IS NULL THROW 51705, N'该体征指标没有阈值配置。', 1;

    INSERT dbo.HealthReading (BindingId, PacketKey, MetricCode, MeasuredValue, CapturedAt, ReceivedAt, SourceType, IsAbnormal)
    VALUES (@BindingId, @PacketKey, @MetricCode, @MeasuredValue, @CapturedAt, @Now,
            CASE WHEN @ActorId IS NULL THEN 'DEVICE' ELSE 'MANUAL' END,
            CASE WHEN @MeasuredValue BETWEEN @Min AND @Max THEN 0 ELSE 1 END);
    SET @ReadingId = CONVERT(int, SCOPE_IDENTITY());

    IF @MeasuredValue < @Min OR @MeasuredValue > @Max
    BEGIN
        INSERT dbo.HealthAlert (ReadingId, Severity, OpenedAt, TriageDeadline)
        VALUES (@ReadingId, @Severity, @Now, DATEADD(minute, @TriageMinutes, @Now));
        SET @AlertId = CONVERT(int, SCOPE_IDENTITY());
        INSERT dbo.HealthNotice (RecipientUserId, AlertId, Kind, CreatedAt)
        SELECT recipient.UserId, @AlertId, 'TRIAGE', @Now
        FROM dbo.fn_HealthNoticeRecipients(@ArchiveNo) AS recipient;
    END;
    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_SimulateHealthReadings @Now datetime2(0) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Now=COALESCE(@Now,SYSUTCDATETIME());
    DECLARE @Minute int=DATEDIFF(minute,'20000101',@Now);
    DECLARE @CapturedAt datetime2(0)=DATEADD(minute,@Minute,CONVERT(datetime2(0),'20000101'));
    DECLARE @DeviceId int, @Code varchar(24), @Metric varchar(24), @Packet varchar(64), @Value decimal(10,2);
    DECLARE devices CURSOR LOCAL FAST_FORWARD FOR
        SELECT DeviceId FROM dbo.HealthDevice WHERE IsDemo=1 AND IsEnabled=1
          AND DeviceType IN ('VITALS','BP_MONITOR','ECG_PATCH','FALL_RADAR') ORDER BY DeviceId;
    OPEN devices;
    FETCH NEXT FROM devices INTO @DeviceId;
    WHILE @@FETCH_STATUS=0
    BEGIN
        BEGIN TRANSACTION;
        SELECT @Code=NULL, @Metric=NULL, @Value=NULL;
        SELECT @Code=DeviceCode, @Metric=CASE DeviceType
            WHEN 'BP_MONITOR' THEN 'DEMO-SYSTOLIC' WHEN 'ECG_PATCH' THEN 'DEMO-ECG-RATE'
            WHEN 'FALL_RADAR' THEN 'DEMO-FALL' ELSE 'DEMO-METRIC-1' END
        FROM dbo.HealthDevice WITH (UPDLOCK,HOLDLOCK)
        WHERE DeviceId=@DeviceId AND IsDemo=1 AND IsEnabled=1 AND DeviceType<>'SOS';
        SET @Packet=CONCAT('SIM-',@DeviceId,'-',@Minute);
        IF @Code IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.HealthReading WHERE PacketKey=@Packet)
           AND EXISTS (
               SELECT 1 FROM dbo.HealthBinding binding JOIN dbo.ElderArchive elder ON elder.ArchiveNo=binding.ArchiveNo
               WHERE binding.DeviceId=@DeviceId AND binding.StartsAt<=@CapturedAt AND binding.EndsAt IS NULL
                 AND elder.IsActive=1 AND LEFT(elder.IdNumber,6)='000000'
           )
        BEGIN
            SELECT @Value=CASE WHEN (@Minute+@DeviceId)%5=0 THEN MaximumValue+1
                               ELSE (MinimumValue+MaximumValue)/2.0 END
            FROM dbo.HealthThreshold WHERE MetricCode=@Metric;
            IF @Value IS NOT NULL
                EXEC dbo.usp_RecordHealthReading @Code,@Packet,@Metric,@Value,@CapturedAt,@Now=@Now;
        END;
        COMMIT;
        FETCH NEXT FROM devices INTO @DeviceId;
    END;
    CLOSE devices;
    DEALLOCATE devices;
END;
GO

CREATE OR ALTER FUNCTION dbo.fn_HealthResponseMinutes (@ArchiveNo varchar(20), @Severity tinyint)
RETURNS smallint
AS
BEGIN
    DECLARE @Minutes smallint;
    SELECT @Minutes = response_rule.ResponseMinutes
    FROM dbo.HealthResponseRule AS response_rule
    JOIN dbo.ElderArchive AS elder ON elder.CommunityId = response_rule.CommunityId
    WHERE elder.ArchiveNo = @ArchiveNo AND response_rule.Severity = @Severity;
    RETURN COALESCE(@Minutes, CASE @Severity WHEN 3 THEN 5 WHEN 2 THEN 15 ELSE 30 END);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ReviewHealthAlert
    @AlertId int, @ActorId int, @Decision varchar(12), @Now datetime2(0) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Now = COALESCE(@Now, CONVERT(datetime2(0), SYSUTCDATETIME()));

    IF @Decision NOT IN ('FALSE_ALARM', 'CONFIRMED') OR @Decision IS NULL
        THROW 51706, N'请选择误报或确认告警。', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.AppUser WHERE UserId = @ActorId AND Role = 'community')
        THROW 51701, N'只有所属社区值班人员可以复核体征告警。', 1;

    DECLARE @ArchiveNo varchar(20), @Severity tinyint;
    BEGIN TRANSACTION;
    SELECT @ArchiveNo = binding.ArchiveNo, @Severity = alert.Severity
    FROM dbo.HealthAlert AS alert WITH (UPDLOCK, HOLDLOCK)
    JOIN dbo.HealthReading AS reading ON reading.ReadingId = alert.ReadingId
    JOIN dbo.HealthBinding AS binding ON binding.BindingId = reading.BindingId
    WHERE alert.AlertId = @AlertId AND alert.State = 'PENDING'
      AND @Now >= alert.OpenedAt AND @Now < alert.TriageDeadline;

    IF @Severity IS NULL THROW 51706, N'告警不存在、已处理或已到复核截止时间。', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.fn_HealthArchiveScope(@ActorId) WHERE ArchiveNo = @ArchiveNo)
        THROW 51701, N'只能处理本社区老人的告警。', 1;

    UPDATE dbo.HealthAlert SET State = @Decision, ReviewedAt = @Now, ReviewedBy = @ActorId WHERE AlertId = @AlertId;
    IF @Decision = 'CONFIRMED'
        INSERT dbo.HealthEvent (ArchiveNo, AlertId, SourceType, Origin, Severity, OpenedAt, ResponseDeadline, LastActorId)
        VALUES (@ArchiveNo, @AlertId, 'THRESHOLD', 'REVIEW', @Severity, @Now,
                DATEADD(minute, dbo.fn_HealthResponseMinutes(@ArchiveNo, @Severity), @Now), @ActorId);
    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_OpenHealthEvent
    @ArchiveNo varchar(20), @RequestKey varchar(64), @SourceType varchar(12), @ActorId int = NULL,
    @Now datetime2(0) = NULL, @ReportKind varchar(12) = NULL, @ReportText nvarchar(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Now = COALESCE(@Now, CONVERT(datetime2(0), SYSUTCDATETIME()));
    IF @SourceType NOT IN ('SOS', 'MANUAL') OR @SourceType IS NULL OR NULLIF(TRIM(@RequestKey), '') IS NULL
        THROW 51707, N'请提供事件来源和唯一请求编号。', 1;
    SET @ReportText=NULLIF(TRIM(@ReportText),N'');
    IF (@ReportKind IS NOT NULL OR @ReportText IS NOT NULL)
       AND (@SourceType<>'MANUAL' OR @ReportKind IS NULL OR @ReportKind NOT IN ('HEALTH','HOME_RISK') OR @ReportText IS NULL)
        THROW 51707, N'人工报告须填写正确的异常来源与说明。', 1;
    IF @ActorId IS NOT NULL AND (NOT EXISTS (
        SELECT 1 FROM dbo.AppUser WHERE UserId = @ActorId
          AND (Role IN ('community', 'caregiver') OR (Role IN ('resident', 'family') AND @SourceType = 'SOS'))
    ) OR NOT EXISTS (SELECT 1 FROM dbo.fn_HealthArchiveScope(@ActorId) WHERE ArchiveNo = @ArchiveNo))
        THROW 51701, N'当前账号不能为该老人发起此事件。', 1;

    DECLARE @ExistingArchive varchar(20), @ExistingSource varchar(12), @ExistingKind varchar(12), @ExistingText nvarchar(400),
            @Severity tinyint = CASE WHEN @SourceType = 'SOS' THEN 3 ELSE 2 END;
    BEGIN TRANSACTION;
    SELECT @ExistingArchive = ArchiveNo, @ExistingSource = SourceType, @ExistingKind=ReportKind, @ExistingText=ReportText
    FROM dbo.HealthEvent WITH (UPDLOCK, HOLDLOCK) WHERE RequestKey = @RequestKey;
    IF @ExistingArchive IS NOT NULL
    BEGIN
        IF @ExistingArchive <> @ArchiveNo OR @ExistingSource <> @SourceType
           OR ISNULL(@ExistingKind,'')<>ISNULL(@ReportKind,'') OR ISNULL(@ExistingText,N'')<>ISNULL(@ReportText,N'')
            THROW 51707, N'该请求编号已用于其他事件。', 1;
        COMMIT TRANSACTION;
        RETURN;
    END;

    INSERT dbo.HealthEvent (ArchiveNo, RequestKey, SourceType, Origin, Severity, OpenedAt, ResponseDeadline, LastActorId,
                            ReportKind, ReportText)
    VALUES (@ArchiveNo, @RequestKey, @SourceType, CASE WHEN @ActorId IS NULL THEN 'DEVICE' ELSE 'USER' END,
            @Severity, @Now, DATEADD(minute, dbo.fn_HealthResponseMinutes(@ArchiveNo, @Severity), @Now), @ActorId,
            @ReportKind, @ReportText);
    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_UpdateHealthEvent
    @EventId int, @ActorId int, @Action varchar(12), @Resolution nvarchar(400) = NULL, @Now datetime2(0) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Now = COALESCE(@Now, CONVERT(datetime2(0), SYSUTCDATETIME()));
    IF NOT EXISTS (SELECT 1 FROM dbo.AppUser WHERE UserId = @ActorId AND Role IN ('community', 'caregiver', 'street', 'civil'))
        THROW 51701, N'当前账号没有应急处置权限。', 1;

    DECLARE @ArchiveNo varchar(20), @OpenedAt datetime2(0), @RespondedAt datetime2(0),
            @RespondedBy int, @ArrivedAt datetime2(0), @ClosedAt datetime2(0),
            @ResponseDeadline datetime2(0), @EscalatedAt datetime2(0);
    BEGIN TRANSACTION;
    SELECT @ArchiveNo = ArchiveNo, @OpenedAt = OpenedAt, @RespondedAt = RespondedAt,
           @RespondedBy = RespondedBy, @ArrivedAt = ArrivedAt, @ClosedAt = ClosedAt,
           @ResponseDeadline = ResponseDeadline, @EscalatedAt = EscalatedAt
    FROM dbo.HealthEvent WITH (UPDLOCK, HOLDLOCK) WHERE EventId = @EventId;

    IF @OpenedAt IS NULL OR @ClosedAt IS NOT NULL OR @Now < @OpenedAt
        THROW 51708, N'应急事件不存在、尚未开始或已处置完成。', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.fn_HealthArchiveScope(@ActorId) WHERE ArchiveNo = @ArchiveNo)
       AND ISNULL(@RespondedBy, 0) <> @ActorId
        THROW 51701, N'当前账号不在该事件的处置范围。', 1;

    IF @Action = 'RESPOND' AND @RespondedAt IS NULL
        UPDATE dbo.HealthEvent
        SET RespondedAt = @Now, RespondedBy = @ActorId, LastActorId = @ActorId,
            EscalatedAt = CASE WHEN @Now >= @ResponseDeadline AND @EscalatedAt IS NULL THEN @Now ELSE EscalatedAt END,
            Severity = CASE WHEN @Now >= @ResponseDeadline AND @EscalatedAt IS NULL AND Severity < 3
                            THEN Severity + 1 ELSE Severity END
        WHERE EventId = @EventId;
    ELSE IF @Action = 'ARRIVE' AND @RespondedBy = @ActorId AND @ArrivedAt IS NULL AND @Now >= @RespondedAt
        UPDATE dbo.HealthEvent SET ArrivedAt = @Now, LastActorId = @ActorId WHERE EventId = @EventId;
    ELSE IF @Action = 'CLOSE' AND @RespondedBy = @ActorId AND @Now >= COALESCE(@ArrivedAt, @RespondedAt)
            AND NULLIF(TRIM(@Resolution), N'') IS NOT NULL
        UPDATE dbo.HealthEvent SET ClosedAt = @Now, Resolution = @Resolution, LastActorId = @ActorId WHERE EventId = @EventId;
    ELSE
        THROW 51708, N'操作与当前状态不符，或处置结果为空。', 1;
    COMMIT TRANSACTION;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ProcessHealthTimeouts @Now datetime2(0) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Now = COALESCE(@Now, CONVERT(datetime2(0), SYSUTCDATETIME()));

    DECLARE @DueAlerts TABLE (AlertId int PRIMARY KEY, ReadingId int, Severity tinyint);
    BEGIN TRANSACTION;

    UPDATE dbo.HealthAlert SET State = 'TIMEOUT', ReviewedAt = @Now
    OUTPUT inserted.AlertId, inserted.ReadingId, inserted.Severity
        INTO @DueAlerts (AlertId, ReadingId, Severity)
    WHERE State = 'PENDING' AND TriageDeadline <= @Now;

    INSERT dbo.HealthEvent (ArchiveNo, AlertId, SourceType, Origin, Severity, OpenedAt, ResponseDeadline)
    SELECT binding.ArchiveNo, due.AlertId, 'THRESHOLD', 'TRIAGE_TIMEOUT', due.Severity, @Now,
           DATEADD(minute, dbo.fn_HealthResponseMinutes(binding.ArchiveNo, due.Severity), @Now)
    FROM @DueAlerts AS due
    JOIN dbo.HealthReading AS reading ON reading.ReadingId = due.ReadingId
    JOIN dbo.HealthBinding AS binding ON binding.BindingId = reading.BindingId;

    UPDATE dbo.HealthEvent
    SET EscalatedAt = @Now, Severity = CASE WHEN Severity < 3 THEN Severity + 1 ELSE Severity END, LastActorId = NULL
    WHERE RespondedAt IS NULL AND EscalatedAt IS NULL AND ResponseDeadline <= @Now;
    COMMIT TRANSACTION;
END;
GO

PRINT N'健康监测与应急数据库对象已就绪。';
