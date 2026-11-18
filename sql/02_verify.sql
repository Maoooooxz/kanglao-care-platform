USE [KanglaoCourse];
GO

SET NOCOUNT ON;
SET XACT_ABORT OFF;

IF DB_NAME() <> N'KanglaoCourse' OR @@TRANCOUNT <> 0
    THROW 51000, N'请在 KanglaoCourse 数据库的无活动事务会话中运行验证。', 1;

IF (SELECT COUNT(*) FROM dbo.Community WHERE CommunityId IN (1, 2)) <> 2
    THROW 51001, N'缺少样例社区。', 1;

IF (SELECT COUNT(*) FROM dbo.v_ElderArchiveSummary WHERE ArchiveNo IN ('E0001', 'E0002', 'E0003')) <> 3
    THROW 51002, N'未能从视图查到 3 份样例档案。', 1;

DECLARE @ArchiveNo varchar(20) = 'VERIFY-0001';
DECLARE @IdNumber char(18) = '000000195001019999';
DECLARE @BirthDate date = DATEFROMPARTS(1950, 1, 1);

BEGIN TRY
    BEGIN TRANSACTION;

    INSERT INTO dbo.ElderArchive (IdNumber, ArchiveNo, FullName, BirthDate, Address, CommunityId)
    VALUES (@IdNumber, @ArchiveNo, N'验证用老人', @BirthDate, N'验证路 1 号', 1);

    IF NOT EXISTS (
        SELECT 1 FROM dbo.v_ElderArchiveSummary AS summary
        INNER JOIN dbo.Community AS community ON community.CommunityId = 1
        WHERE summary.ArchiveNo = @ArchiveNo
          AND summary.FullName = N'验证用老人'
          AND summary.CommunityName = community.Name
          AND summary.MaskedIdNumber = '**************9999'
    )
        THROW 51003, N'未查到新档案及其正确的脱敏证件号。', 1;

    -- 预期的约束错误只撤销当前 INSERT，验证结束时统一回滚。
    BEGIN TRY
        INSERT INTO dbo.ElderArchive (IdNumber, ArchiveNo, FullName, BirthDate, Address, CommunityId)
        VALUES (@IdNumber, 'VERIFY-ID', N'重复证件号', @BirthDate, N'验证路 1 号', 1);
        THROW 51004, N'数据库接受了重复的证件号。', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() <> 2627
            THROW;
    END CATCH;

    BEGIN TRY
        INSERT INTO dbo.ElderArchive (IdNumber, ArchiveNo, FullName, BirthDate, Address, CommunityId)
        VALUES ('000000195001019998', @ArchiveNo, N'重复档案编号', @BirthDate, N'验证路 1 号', 1);
        THROW 51005, N'数据库接受了重复的档案编号。', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() <> 2627
            THROW;
    END CATCH;

    BEGIN TRY
        INSERT INTO dbo.ElderArchive (IdNumber, ArchiveNo, FullName, BirthDate, Address, CommunityId)
        VALUES ('000000195001019997', 'VERIFY-FK', N'未知社区', @BirthDate, N'验证路 1 号', -1);
        THROW 51006, N'数据库接受了不存在的社区。', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() <> 547
            THROW;
    END CATCH;

    UPDATE dbo.ElderArchive
    SET CommunityId = 2
    WHERE ArchiveNo = @ArchiveNo;

    IF @@ROWCOUNT <> 1
        THROW 51007, N'社区迁移应更新一份已有档案。', 1;

    IF NOT EXISTS (
        SELECT 1 FROM dbo.ElderArchive
        WHERE IdNumber = @IdNumber AND ArchiveNo = @ArchiveNo AND CommunityId = 2
    ) OR NOT EXISTS (
        SELECT 1 FROM dbo.v_ElderArchiveSummary AS summary
        INNER JOIN dbo.Community AS community ON community.CommunityId = 2
        WHERE summary.ArchiveNo = @ArchiveNo AND summary.CommunityName = community.Name
    )
        THROW 51008, N'迁移后未查到原档案及其新的社区。', 1;

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;
    THROW;
END CATCH;

IF EXISTS (SELECT 1 FROM dbo.ElderArchive WHERE ArchiveNo = @ArchiveNo)
    THROW 51009, N'验证用档案未回滚。', 1;

PRINT N'PASS 建档和脱敏查询、主键与唯一约束、社区外键、社区迁移及验证数据回滚。';

SELECT ArchiveNo, FullName, CommunityName, MaskedIdNumber
FROM dbo.v_ElderArchiveSummary
WHERE ArchiveNo IN ('E0001', 'E0002', 'E0003')
ORDER BY ArchiveNo;
