USE [master];
GO
SET NOCOUNT ON;

DECLARE @Source sysname = N'KanglaoCourse_QA';
IF DB_ID(@Source) IS NULL THROW 51900, N'请先准备独立的 KanglaoCourse_QA 验证库。', 1;

DECLARE @Suffix varchar(12) = RIGHT(REPLACE(CONVERT(varchar(36), NEWID()), '-', ''), 12);
DECLARE @Target sysname = CONCAT(N'KanglaoCourse_Restore_', @Suffix);
DECLARE @BackupPath nvarchar(4000) = CONVERT(nvarchar(4000), SERVERPROPERTY('InstanceDefaultBackupPath'));
DECLARE @DataPath nvarchar(4000) = CONVERT(nvarchar(4000), SERVERPROPERTY('InstanceDefaultDataPath'));
DECLARE @LogPath nvarchar(4000) = CONVERT(nvarchar(4000), SERVERPROPERTY('InstanceDefaultLogPath'));
IF @BackupPath IS NULL OR @DataPath IS NULL OR @LogPath IS NULL
    THROW 51901, N'请检查实例的备份、数据和日志目录。', 1;

DECLARE @Backup nvarchar(4000) = CONCAT(@BackupPath, N'\', @Target, N'.bak');
DECLARE @DataFile nvarchar(4000) = CONCAT(@DataPath, N'\', @Target, N'.mdf');
DECLARE @LogFile nvarchar(4000) = CONCAT(@LogPath, N'\', @Target, N'_log.ldf');
DECLARE @DataName sysname = (SELECT name FROM sys.master_files WHERE database_id = DB_ID(@Source) AND file_id = 1);
DECLARE @LogName sysname = (SELECT name FROM sys.master_files WHERE database_id = DB_ID(@Source) AND type_desc = 'LOG');
DECLARE @StartedAt datetime2 = SYSUTCDATETIME();

BACKUP DATABASE @Source TO DISK = @Backup WITH COPY_ONLY, CHECKSUM;
RESTORE VERIFYONLY FROM DISK = @Backup WITH CHECKSUM;

DECLARE @Restore nvarchar(max) = N'RESTORE DATABASE ' + QUOTENAME(@Target)
    + N' FROM DISK = N''' + REPLACE(@Backup, N'''', N'''''') + N''' WITH CHECKSUM, MOVE '
    + QUOTENAME(@DataName, '''') + N' TO N''' + REPLACE(@DataFile, N'''', N'''''') + N''', MOVE '
    + QUOTENAME(@LogName, '''') + N' TO N''' + REPLACE(@LogFile, N'''', N'''''') + N''';';
EXEC sys.sp_executesql @Restore;

DECLARE @CompareForDb nvarchar(max) = N'
    SELECT N''档案'', COUNT_BIG(*) FROM {db}.dbo.ElderArchive
    UNION ALL SELECT N''能力评估'', COUNT_BIG(*) FROM {db}.dbo.AbilityAssessment
    UNION ALL SELECT N''已完成订单'', COUNT_BIG(*) FROM {db}.dbo.v_SubsidyEligibleOrder
    UNION ALL SELECT N''应急事件'', COUNT_BIG(*) FROM {db}.dbo.HealthEvent
    UNION ALL SELECT N''补贴申报'', COUNT_BIG(*) FROM {db}.dbo.v_SubsidyClaimSummary
    UNION ALL SELECT N''抽查整改'', COUNT_BIG(*) FROM {db}.dbo.ServiceInspection;';
CREATE TABLE #SourceCounts (Domain nvarchar(20), RecordCount bigint);
CREATE TABLE #RestoreCounts (Domain nvarchar(20), RecordCount bigint);

DECLARE @SourceCheck nvarchar(max) = REPLACE(@CompareForDb, N'{db}', QUOTENAME(@Source));
DECLARE @RestoreCheck nvarchar(max) = REPLACE(@CompareForDb, N'{db}', QUOTENAME(@Target));
INSERT #SourceCounts EXEC sys.sp_executesql @SourceCheck;
INSERT #RestoreCounts EXEC sys.sp_executesql @RestoreCheck;
IF EXISTS (SELECT * FROM #SourceCounts EXCEPT SELECT * FROM #RestoreCounts)
   OR EXISTS (SELECT * FROM #RestoreCounts EXCEPT SELECT * FROM #SourceCounts)
    THROW 51902, N'独立恢复库的业务记录数量与备份源不同。', 1;

SELECT Domain, RecordCount FROM #RestoreCounts ORDER BY Domain;
SELECT @Target AS RestoredDatabase, DATEDIFF(second, @StartedAt, SYSUTCDATETIME()) AS ElapsedSeconds;
PRINT N'PASS 完整备份、校验、独立数据库恢复和业务数据对照。';
