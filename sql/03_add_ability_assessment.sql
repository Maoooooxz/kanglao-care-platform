USE [KanglaoCourse];
GO

SET NOCOUNT ON;

IF DB_NAME() <> N'KanglaoCourse' OR @@TRANCOUNT <> 0
    THROW 51100, N'请在 KanglaoCourse 数据库的无活动事务会话中升级。', 1;

IF OBJECT_ID(N'dbo.ElderArchive', N'U') IS NULL
    THROW 51100, N'请先运行 01_init.sql 创建老人档案表。', 1;

SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    IF OBJECT_ID(N'dbo.AbilityAssessment', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.AbilityAssessment (
            AssessmentId int IDENTITY(1, 1) NOT NULL,
            AssessmentNo varchar(24) NOT NULL,
            ArchiveNo varchar(20) NOT NULL,
            ScaleCode varchar(8) NOT NULL,
            Score decimal(6, 2) NOT NULL,
            AbilityLevel nvarchar(20) NOT NULL,
            EvaluatorName nvarchar(100) NOT NULL,
            AssessmentDate date NOT NULL,
            ValidThrough date NOT NULL,
            CONSTRAINT PK_AbilityAssessment PRIMARY KEY (AssessmentId),
            CONSTRAINT UQ_AbilityAssessment_AssessmentNo UNIQUE (AssessmentNo),
            CONSTRAINT FK_AbilityAssessment_ElderArchive
                FOREIGN KEY (ArchiveNo) REFERENCES dbo.ElderArchive (ArchiveNo),
            CONSTRAINT CK_AbilityAssessment_Scale CHECK (ScaleCode IN ('ADL', 'MMSE')),
            CONSTRAINT CK_AbilityAssessment_Score CHECK (Score >= 0),
            CONSTRAINT CK_AbilityAssessment_Validity CHECK (ValidThrough >= AssessmentDate),
            CONSTRAINT CK_AbilityAssessment_RequiredText
                CHECK (LEN(AssessmentNo) > 0 AND LEN(AbilityLevel) > 0 AND LEN(EvaluatorName) > 0)
        );

        CREATE INDEX IX_AbilityAssessment_ArchiveDate
            ON dbo.AbilityAssessment (ArchiveNo, AssessmentDate DESC, AssessmentId DESC);
    END;

    EXEC sys.sp_executesql N'
        CREATE OR ALTER PROCEDURE dbo.usp_RecordAbilityAssessment
            @AssessmentNo varchar(24),
            @ArchiveNo varchar(20),
            @ScaleCode varchar(8),
            @Score decimal(6, 2),
            @AbilityLevel nvarchar(20),
            @EvaluatorName nvarchar(100),
            @AssessmentDate date,
            @ValidThrough date
        AS
        BEGIN
            SET NOCOUNT ON;

            IF @AssessmentDate > CONVERT(date, SYSDATETIME())
                THROW 51101, N''评估日期不能晚于当天。'', 1;

            INSERT INTO dbo.AbilityAssessment (
                AssessmentNo, ArchiveNo, ScaleCode, Score, AbilityLevel, EvaluatorName, AssessmentDate, ValidThrough
            )
            VALUES (
                @AssessmentNo, @ArchiveNo, @ScaleCode, @Score, @AbilityLevel, @EvaluatorName, @AssessmentDate, @ValidThrough
            );
        END;
    ';

    EXEC sys.sp_executesql N'
        CREATE OR ALTER VIEW dbo.v_AbilityAssessmentHistory
        AS
        SELECT AssessmentId, AssessmentNo, ArchiveNo, ScaleCode, Score, AbilityLevel, EvaluatorName,
               AssessmentDate, ValidThrough
        FROM dbo.AbilityAssessment;
    ';

    -- 先找最新评估，再判断是否到期。过期后应安排复评。
    EXEC sys.sp_executesql N'
        CREATE OR ALTER VIEW dbo.v_CurrentAbilityAssessment
        AS
        SELECT
            archive.ArchiveNo,
            archive.FullName,
            latest.AssessmentId,
            latest.AssessmentNo,
            latest.ScaleCode,
            latest.Score,
            latest.AbilityLevel,
            latest.EvaluatorName,
            latest.AssessmentDate,
            latest.ValidThrough,
            CASE
                WHEN latest.AssessmentId IS NULL THEN N''未评估''
                WHEN latest.ValidThrough >= calendar.Today THEN N''有效''
                ELSE N''已过期''
            END AS AssessmentStatus
        FROM dbo.ElderArchive AS archive
        CROSS JOIN (SELECT CONVERT(date, SYSDATETIME()) AS Today) AS calendar
        OUTER APPLY (
            SELECT TOP (1) assessment.AssessmentId, assessment.AssessmentNo, assessment.ScaleCode,
                   assessment.Score, assessment.AbilityLevel, assessment.EvaluatorName,
                   assessment.AssessmentDate, assessment.ValidThrough
            FROM dbo.AbilityAssessment AS assessment
            WHERE assessment.ArchiveNo = archive.ArchiveNo
              AND assessment.AssessmentDate <= calendar.Today
            ORDER BY assessment.AssessmentDate DESC, assessment.AssessmentId DESC
        ) AS latest;
    ';

    DECLARE @Today date = CONVERT(date, SYSDATETIME());

    INSERT INTO dbo.AbilityAssessment (
        AssessmentNo, ArchiveNo, ScaleCode, Score, AbilityLevel, EvaluatorName, AssessmentDate, ValidThrough
    )
    SELECT demo.AssessmentNo, demo.ArchiveNo, demo.ScaleCode, demo.Score, demo.AbilityLevel, N'演示评估员',
           DATEADD(day, demo.AssessedDays, @Today), DATEADD(day, demo.ValidDays, @Today)
    FROM (VALUES
        ('DEMO-ASMT-01', 'E0001', 'ADL', 88, N'轻度失能', -60, -1),
        ('DEMO-ASMT-02', 'E0001', 'ADL', 80, N'轻度失能', -30, 7),
        ('DEMO-ASMT-03', 'E0002', 'MMSE', 16, N'中度失能', -45, -3)
    ) AS demo (AssessmentNo, ArchiveNo, ScaleCode, Score, AbilityLevel, AssessedDays, ValidDays)
    WHERE NOT EXISTS (
        SELECT 1 FROM dbo.AbilityAssessment AS existing
        WHERE existing.AssessmentNo = demo.AssessmentNo
    );

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;
    THROW;
END CATCH;

PRINT N'能力评估升级完成。';
