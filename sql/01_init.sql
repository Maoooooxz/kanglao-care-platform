USE [master];
GO

IF @@TRANCOUNT <> 0
    THROW 51000, N'请在没有活动事务的会话中运行初始化脚本。', 1;

IF DB_ID(N'KanglaoCourse') IS NULL
    EXEC sys.sp_executesql N'CREATE DATABASE [KanglaoCourse];';
GO

USE [KanglaoCourse];
GO

SET NOCOUNT ON;

IF DB_NAME() <> N'KanglaoCourse' OR @@TRANCOUNT <> 0
    THROW 51000, N'请在 KanglaoCourse 数据库的无活动事务会话中初始化。', 1;

SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    IF OBJECT_ID(N'dbo.Community', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.Community (
            CommunityId int NOT NULL,
            Name nvarchar(100) NOT NULL,
            CONSTRAINT PK_Community PRIMARY KEY (CommunityId)
        );
    END;

    IF OBJECT_ID(N'dbo.ElderArchive', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.ElderArchive (
            IdNumber char(18) NOT NULL,
            ArchiveNo varchar(20) NOT NULL,
            FullName nvarchar(100) NOT NULL,
            BirthDate date NOT NULL,
            Address nvarchar(200) NOT NULL,
            CommunityId int NOT NULL,
            CONSTRAINT PK_ElderArchive PRIMARY KEY (IdNumber),
            CONSTRAINT UQ_ElderArchive_ArchiveNo UNIQUE (ArchiveNo),
            CONSTRAINT FK_ElderArchive_Community
                FOREIGN KEY (CommunityId) REFERENCES dbo.Community (CommunityId)
        );
    END;

    -- 视图定义放在独立批次中执行，使它和建表、样例数据一起提交。
    EXEC sys.sp_executesql N'
        CREATE OR ALTER VIEW dbo.v_ElderArchiveSummary
        AS
        SELECT
            archive.ArchiveNo,
            archive.FullName,
            community.Name AS CommunityName,
            CAST(REPLICATE(''*'', 14) + RIGHT(archive.IdNumber, 4) AS char(18)) AS MaskedIdNumber
        FROM dbo.ElderArchive AS archive
        INNER JOIN dbo.Community AS community
            ON community.CommunityId = archive.CommunityId;
    ';

    INSERT INTO dbo.Community (CommunityId, Name)
    SELECT demo.CommunityId, demo.Name
    FROM (VALUES
        (1, N'示例社区甲'),
        (2, N'示例社区乙')
    ) AS demo (CommunityId, Name)
    WHERE NOT EXISTS (
        SELECT 1 FROM dbo.Community AS existing
        WHERE existing.CommunityId = demo.CommunityId
    );

    -- 样例证件号使用无效的地区码 000000。
    INSERT INTO dbo.ElderArchive (IdNumber, ArchiveNo, FullName, BirthDate, Address, CommunityId)
    SELECT demo.IdNumber, demo.ArchiveNo, demo.FullName, demo.BirthDate, demo.Address, demo.CommunityId
    FROM (VALUES
        ('000000195001010001', 'E0001', N'示例老人甲', DATEFROMPARTS(1950, 1, 1), N'演示路 1 号', 1),
        ('000000194802020002', 'E0002', N'示例老人乙', DATEFROMPARTS(1948, 2, 2), N'演示路 2 号', 1),
        ('000000195203030003', 'E0003', N'示例老人丙', DATEFROMPARTS(1952, 3, 3), N'演示路 3 号', 2)
    ) AS demo (IdNumber, ArchiveNo, FullName, BirthDate, Address, CommunityId)
    WHERE NOT EXISTS (
        SELECT 1 FROM dbo.ElderArchive AS existing
        WHERE existing.IdNumber = demo.IdNumber
    );

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;
    THROW;
END CATCH;

PRINT N'初始化完成。';
