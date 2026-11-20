USE [KanglaoCourse];
GO

SET NOCOUNT ON;
SET XACT_ABORT OFF;

IF DB_NAME() <> N'KanglaoCourse' OR @@TRANCOUNT <> 0
    THROW 51200, N'请在 KanglaoCourse 数据库的无活动事务会话中运行验证。', 1;

DECLARE @ArchiveNo varchar(20) = 'VERIFY-ASSESS-01';
DECLARE @Today date = CONVERT(date,DATEADD(hour,8,SYSUTCDATETIME()));
DECLARE @Yesterday date = DATEADD(day, -1, @Today);
DECLARE @TwoDaysAgo date = DATEADD(day, -2, @Today);
DECLARE @Tomorrow date = DATEADD(day, 1, @Today);

BEGIN TRY
    BEGIN TRANSACTION;

    INSERT INTO dbo.ElderArchive (IdNumber, ArchiveNo, FullName, BirthDate, Address, CommunityId)
    VALUES ('000000195001019996', @ArchiveNo, N'评估验证用老人', '19500101', N'验证路 1 号', 1);

    IF NOT EXISTS (
        SELECT 1 FROM dbo.v_CurrentAbilityAssessment
        WHERE ArchiveNo = @ArchiveNo AND AssessmentId IS NULL AND AssessmentStatus = N'未评估'
    )
        THROW 51201, N'未评估档案的状态异常。', 1;

    EXEC dbo.usp_RecordAbilityAssessment
        'VERIFY-ASSESS-OLD', @ArchiveNo, 'ADL', 65, N'轻度失能', N'验证评估员', @TwoDaysAgo, @Tomorrow;

    IF NOT EXISTS (
        SELECT 1 FROM dbo.v_CurrentAbilityAssessment
        WHERE ArchiveNo = @ArchiveNo AND AssessmentNo = 'VERIFY-ASSESS-OLD' AND AssessmentStatus = N'有效'
    )
        THROW 51202, N'有效的首次评估未显示为当前评估。', 1;

    EXEC dbo.usp_RecordAbilityAssessment
        'VERIFY-ASSESS-EXPIRED', @ArchiveNo, 'MMSE', 20, N'中度失能', N'验证评估员', @Yesterday, @Yesterday;

    IF NOT EXISTS (
        SELECT 1 FROM dbo.v_CurrentAbilityAssessment
        WHERE ArchiveNo = @ArchiveNo AND AssessmentNo = 'VERIFY-ASSESS-EXPIRED' AND AssessmentStatus = N'已过期'
    )
        THROW 51203, N'最新评估过期后应保留其状态。', 1;

    EXEC dbo.usp_RecordAbilityAssessment
        'VERIFY-ASSESS-TIE-Z', @ArchiveNo, 'ADL', 70, N'轻度失能', N'验证评估员', @Today, @Today;

    IF NOT EXISTS (
        SELECT 1 FROM dbo.v_CurrentAbilityAssessment
        WHERE ArchiveNo = @ArchiveNo AND AssessmentNo = 'VERIFY-ASSESS-TIE-Z' AND AssessmentStatus = N'有效'
    )
        THROW 51204, N'截止日当天应为有效。', 1;

    EXEC dbo.usp_RecordAbilityAssessment
        'VERIFY-ASSESS-TIE-A', @ArchiveNo, 'ADL', 71, N'轻度失能', N'验证评估员', @Today, @Tomorrow;

    IF NOT EXISTS (
        SELECT 1 FROM dbo.v_CurrentAbilityAssessment
        WHERE ArchiveNo = @ArchiveNo AND AssessmentNo = 'VERIFY-ASSESS-TIE-A' AND AssessmentStatus = N'有效'
    )
        THROW 51205, N'同日有多条评估时应选取后录入的一条。', 1;

    IF (SELECT COUNT(*) FROM dbo.v_AbilityAssessmentHistory WHERE ArchiveNo = @ArchiveNo) <> 4
        THROW 51206, N'评估历史未完整保留。', 1;

    -- 模拟直接导入的未来评估，验证当前状态查询仍以当天为准。
    INSERT INTO dbo.AbilityAssessment (
        AssessmentNo, ArchiveNo, ScaleCode, Score, AbilityLevel, EvaluatorName, AssessmentDate, ValidThrough
    )
    VALUES ('VERIFY-ASSESS-IMPORTED', @ArchiveNo, 'ADL', 72, N'轻度失能', N'验证评估员', @Tomorrow, @Tomorrow);

    IF NOT EXISTS (
        SELECT 1 FROM dbo.v_CurrentAbilityAssessment
        WHERE ArchiveNo = @ArchiveNo AND AssessmentNo = 'VERIFY-ASSESS-TIE-A'
    )
        THROW 51207, N'未来评估不能取代当天的当前评估。', 1;

    UPDATE dbo.ElderArchive SET BirthDate=DATEADD(year,-80,@Today) WHERE ArchiveNo=@ArchiveNo;
    EXEC dbo.usp_RecordAbilityAssessment
        'VERIFY-ASSESS-AGE-BEFORE', @ArchiveNo, 'ADL', 75, N'轻度失能', N'验证评估员', @Yesterday;
    EXEC dbo.usp_RecordAbilityAssessment
        'VERIFY-ASSESS-AGE-80', @ArchiveNo, 'ADL', 75, N'轻度失能', N'验证评估员', @Today;
    IF NOT EXISTS (
        SELECT 1 FROM dbo.AbilityAssessment WHERE AssessmentNo='VERIFY-ASSESS-AGE-BEFORE'
            AND ValidThrough=DATEADD(day,180,@Yesterday)
    ) OR NOT EXISTS (
        SELECT 1 FROM dbo.AbilityAssessment WHERE AssessmentNo='VERIFY-ASSESS-AGE-80'
            AND ValidThrough=DATEADD(day,90,@Today)
    ) OR NOT EXISTS (
        SELECT 1 FROM dbo.AbilityAssessment WHERE AssessmentNo='VERIFY-ASSESS-TIE-A' AND ValidThrough=@Tomorrow
    ) THROW 51207, N'80 岁前后默认期限有误，或已有评估截止日被修改。', 1;

    DECLARE @InvalidCases TABLE (
        CaseName nvarchar(30),
        AssessmentNo varchar(24),
        ArchiveNo varchar(20),
        ScaleCode varchar(8),
        Score decimal(6,2),
        AssessmentDate date,
        ValidThrough date,
        ExpectedError int
    );

    INSERT INTO @InvalidCases
    VALUES
        (N'无对应档案', 'VERIFY-ASSESS-FK', 'VERIFY-ASSESS-MISS', 'ADL', 60, @Today, @Tomorrow, 51102),
        (N'无效量表', 'VERIFY-ASSESS-SCALE', @ArchiveNo, 'INVALID', 60, @Today, @Tomorrow, 547),
        (N'负数得分', 'VERIFY-ASSESS-SCORE', @ArchiveNo, 'ADL', -1, @Today, @Tomorrow, 547),
        (N'截止日早于评估日', 'VERIFY-ASSESS-PERIOD', @ArchiveNo, 'ADL', 60, @Today, @Yesterday, 51103),
        (N'截止日超过年龄上限', 'VERIFY-ASSESS-TOO-LONG', @ArchiveNo, 'ADL', 60, @Today, DATEADD(day,91,@Today), 51103),
        (N'重复评估编号', 'VERIFY-ASSESS-OLD', @ArchiveNo, 'ADL', 60, @Today, @Tomorrow, 2627),
        (N'未来评估', 'VERIFY-ASSESS-FUTURE', @ArchiveNo, 'ADL', 60, @Tomorrow, @Tomorrow, 51101);

    DECLARE @CaseName nvarchar(30), @CaseAssessmentNo varchar(24), @CaseArchiveNo varchar(20),
            @CaseScaleCode varchar(8), @CaseScore decimal(6,2), @CaseAssessmentDate date,
            @CaseValidThrough date, @ExpectedError int, @FailureMessage nvarchar(2048);

    DECLARE InvalidAssessmentCases CURSOR LOCAL FAST_FORWARD FOR
        SELECT CaseName, AssessmentNo, ArchiveNo, ScaleCode, Score, AssessmentDate, ValidThrough, ExpectedError
        FROM @InvalidCases;

    OPEN InvalidAssessmentCases;
    FETCH NEXT FROM InvalidAssessmentCases INTO @CaseName, @CaseAssessmentNo, @CaseArchiveNo,
        @CaseScaleCode, @CaseScore, @CaseAssessmentDate, @CaseValidThrough, @ExpectedError;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            EXEC dbo.usp_RecordAbilityAssessment
                @CaseAssessmentNo, @CaseArchiveNo, @CaseScaleCode, @CaseScore,
                N'轻度失能', N'验证评估员', @CaseAssessmentDate, @CaseValidThrough;

            SET @FailureMessage = CONCAT(@CaseName, N'测试失败，数据库接受了该评估。');
            THROW 51208, @FailureMessage, 1;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() <> @ExpectedError
                THROW;
        END CATCH;

        FETCH NEXT FROM InvalidAssessmentCases INTO @CaseName, @CaseAssessmentNo, @CaseArchiveNo,
            @CaseScaleCode, @CaseScore, @CaseAssessmentDate, @CaseValidThrough, @ExpectedError;
    END;

    CLOSE InvalidAssessmentCases;
    DEALLOCATE InvalidAssessmentCases;
    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;
    THROW;
END CATCH;

IF EXISTS (SELECT 1 FROM dbo.ElderArchive WHERE ArchiveNo = @ArchiveNo)
    OR EXISTS (SELECT 1 FROM dbo.AbilityAssessment WHERE ArchiveNo = @ArchiveNo)
    THROW 51209, N'验证用档案或评估未回滚。', 1;

PRINT N'PASS 评估录入、历史、有效期、同日排序、输入约束及验证数据回滚。';
