USE [KanglaoCourse];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF DB_NAME() <> N'KanglaoCourse' OR @@TRANCOUNT <> 0
    THROW 52000, N'请在项目数据库的独立会话中运行迁移。', 1;

BEGIN TRANSACTION;
IF COL_LENGTH(N'dbo.Community', N'District') IS NULL
    ALTER TABLE dbo.Community ADD
        District nvarchar(80) NOT NULL CONSTRAINT DF_Community_District DEFAULT N'海淀演示区',
        Latitude decimal(9,6) NOT NULL CONSTRAINT DF_Community_Lat DEFAULT (40.008000),
        Longitude decimal(9,6) NOT NULL CONSTRAINT DF_Community_Lon DEFAULT (116.341000),
        RadiusMeters int NOT NULL CONSTRAINT DF_Community_Radius DEFAULT (3000);

IF COL_LENGTH(N'dbo.ElderArchive', N'GuardianName') IS NULL
    ALTER TABLE dbo.ElderArchive ADD
        GuardianName nvarchar(100) NULL,
        GuardianContactEncrypted varbinary(1024) NULL,
        IsActive bit NOT NULL CONSTRAINT DF_ElderArchive_Active DEFAULT (1),
        Latitude decimal(9,6) NOT NULL CONSTRAINT DF_ElderArchive_Lat DEFAULT (40.008000),
        Longitude decimal(9,6) NOT NULL CONSTRAINT DF_ElderArchive_Lon DEFAULT (116.341000),
        Tags nvarchar(200) NULL;

IF OBJECT_ID(N'dbo.AppUser', N'U') IS NULL
    CREATE TABLE dbo.AppUser (
        UserId int IDENTITY PRIMARY KEY,
        Username varchar(48) NOT NULL UNIQUE,
        DisplayName nvarchar(80) NOT NULL,
        PasswordHash varchar(255) NOT NULL,
        Role varchar(16) NOT NULL
            CHECK (Role IN ('community','family','resident','caregiver','agency','street','civil')),
        CommunityId int NULL REFERENCES dbo.Community(CommunityId),
        ArchiveNo varchar(20) NULL REFERENCES dbo.ElderArchive(ArchiveNo),
        WorkerId int NULL,
        AgencyId int NULL,
        District nvarchar(80) NULL,
        Active bit NOT NULL DEFAULT (1),
        FailedAttempts int NOT NULL DEFAULT (0),
        LockedUntil datetime2(0) NULL,
        CHECK (
            (Role = 'community' AND CommunityId IS NOT NULL) OR
            (Role IN ('family','resident') AND ArchiveNo IS NOT NULL) OR
            (Role = 'caregiver' AND WorkerId IS NOT NULL) OR
            (Role = 'agency' AND AgencyId IS NOT NULL) OR
            (Role IN ('street','civil') AND District IS NOT NULL)
        )
    );

IF OBJECT_ID(N'dbo.ArchiveAudit', N'U') IS NULL
    CREATE TABLE dbo.ArchiveAudit (
        AuditId bigint IDENTITY PRIMARY KEY,
        ArchiveNo varchar(20) NOT NULL REFERENCES dbo.ElderArchive(ArchiveNo),
        EventType varchar(20) NOT NULL,
        BeforeCommunityId int NULL,
        AfterCommunityId int NOT NULL,
        ActorUserId int NULL REFERENCES dbo.AppUser(UserId),
        OccurredAt datetime2(0) NOT NULL DEFAULT SYSUTCDATETIME()
    );

IF NOT EXISTS (SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.ElderArchive') AND name = N'IX_ElderArchive_Community')
    EXEC(N'CREATE INDEX IX_ElderArchive_Community ON dbo.ElderArchive(CommunityId, IsActive, ArchiveNo)
        INCLUDE (FullName, BirthDate);');
COMMIT;
GO

CREATE OR ALTER TRIGGER dbo.tr_ElderArchive_Audit ON dbo.ElderArchive
AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.ArchiveAudit(ArchiveNo, EventType, BeforeCommunityId, AfterCommunityId, ActorUserId)
    SELECT current_row.ArchiveNo,
           CASE WHEN old.ArchiveNo IS NULL THEN 'created'
                WHEN old.CommunityId <> current_row.CommunityId THEN 'transferred'
                WHEN old.IsActive <> current_row.IsActive THEN 'status'
                ELSE 'updated' END,
           old.CommunityId, current_row.CommunityId, TRY_CONVERT(int, SESSION_CONTEXT(N'app_user'))
    FROM inserted AS current_row
    LEFT JOIN deleted AS old ON old.IdNumber = current_row.IdNumber
    WHERE old.ArchiveNo IS NULL OR old.CommunityId <> current_row.CommunityId
       OR old.IsActive <> current_row.IsActive OR old.FullName <> current_row.FullName
       OR old.BirthDate <> current_row.BirthDate OR old.Address <> current_row.Address
       OR old.Latitude <> current_row.Latitude OR old.Longitude <> current_row.Longitude
       OR ISNULL(old.GuardianName,N'') <> ISNULL(current_row.GuardianName,N'')
       OR ISNULL(old.GuardianContactEncrypted,0x) <> ISNULL(current_row.GuardianContactEncrypted,0x)
       OR ISNULL(old.Tags,N'') <> ISNULL(current_row.Tags,N'');
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_TransferElderArchive
    @ArchiveNo varchar(20), @FromCommunityId int, @ToCommunityId int
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.ElderArchive SET CommunityId = @ToCommunityId
    WHERE ArchiveNo = @ArchiveNo AND CommunityId = @FromCommunityId AND IsActive = 1;
    IF @@ROWCOUNT <> 1 THROW 52001, N'档案已迁移、已停用或超出当前社区范围。', 1;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RecordAbilityAssessment
    @AssessmentNo varchar(24), @ArchiveNo varchar(20), @ScaleCode varchar(8),
    @Score decimal(6,2), @AbilityLevel nvarchar(20), @EvaluatorName nvarchar(100),
    @AssessmentDate date, @ValidThrough date
AS
BEGIN
    SET NOCOUNT ON;
    IF @AssessmentDate > CONVERT(date, DATEADD(hour,8,SYSUTCDATETIME()))
        THROW 51101, N'评估日期不能晚于当天。', 1;
    INSERT dbo.AbilityAssessment
        (AssessmentNo, ArchiveNo, ScaleCode, Score, AbilityLevel, EvaluatorName, AssessmentDate, ValidThrough)
    SELECT @AssessmentNo, @ArchiveNo, @ScaleCode, @Score, @AbilityLevel, @EvaluatorName, @AssessmentDate, @ValidThrough
    FROM dbo.ElderArchive WITH (UPDLOCK,HOLDLOCK) WHERE ArchiveNo = @ArchiveNo AND IsActive = 1;
    IF @@ROWCOUNT <> 1
    BEGIN
        IF EXISTS (SELECT 1 FROM dbo.ElderArchive WHERE ArchiveNo = @ArchiveNo)
            THROW 52002, N'档案已停用。', 1;
        -- 保留旧版调用者接收的外键错误。
        INSERT dbo.AbilityAssessment
            (AssessmentNo, ArchiveNo, ScaleCode, Score, AbilityLevel, EvaluatorName, AssessmentDate, ValidThrough)
        VALUES (@AssessmentNo, @ArchiveNo, @ScaleCode, @Score, @AbilityLevel, @EvaluatorName, @AssessmentDate, @ValidThrough);
    END;
END;
GO

CREATE OR ALTER VIEW dbo.v_CurrentAbilityAssessment AS
SELECT elder.ArchiveNo, elder.FullName, latest.AssessmentId, latest.AssessmentNo,
       latest.ScaleCode, latest.Score, latest.AbilityLevel, latest.EvaluatorName,
       latest.AssessmentDate, latest.ValidThrough,
       CASE WHEN latest.AssessmentId IS NULL THEN N'未评估'
            WHEN latest.ValidThrough >= calendar.Today THEN N'有效'
            ELSE N'已过期' END AS AssessmentStatus
FROM dbo.ElderArchive AS elder
CROSS JOIN (SELECT CONVERT(date,DATEADD(hour,8,SYSUTCDATETIME())) AS Today) AS calendar
OUTER APPLY (
    SELECT TOP (1) a.AssessmentId, a.AssessmentNo, a.ScaleCode, a.Score, a.AbilityLevel,
           a.EvaluatorName, a.AssessmentDate, a.ValidThrough
    FROM dbo.AbilityAssessment AS a
    WHERE a.ArchiveNo = elder.ArchiveNo AND a.AssessmentDate <= calendar.Today
    ORDER BY a.AssessmentDate DESC, a.AssessmentId DESC
) AS latest;
GO
