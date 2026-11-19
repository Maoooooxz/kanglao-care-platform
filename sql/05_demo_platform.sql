USE [KanglaoCourse];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF DB_NAME() <> N'KanglaoCourse'
    THROW 52000, N'请在项目数据库中生成样例。', 1;
IF EXISTS (SELECT 1 FROM dbo.ElderArchive
    WHERE ArchiveNo BETWEEN 'E0001' AND 'E0020' AND LEFT(IdNumber,6)<>'000000')
    THROW 52003, N'演示档案编号与现有档案冲突，请使用独立的演示数据库。', 1;

DECLARE @Today date = CONVERT(date,DATEADD(hour,8,SYSUTCDATETIME()));
DECLARE @Samples table (n int PRIMARY KEY);
INSERT @Samples(n) VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9),(10),
    (11),(12),(13),(14),(15),(16),(17),(18),(19),(20);

BEGIN TRANSACTION;
INSERT dbo.Community(CommunityId, Name, District, Latitude, Longitude, RadiusMeters)
SELECT n, CONCAT(N'演示社区 ', n), N'海淀演示区', 40.008, 116.341, 3000
FROM @Samples s WHERE NOT EXISTS (SELECT 1 FROM dbo.Community c WHERE c.CommunityId=s.n);

INSERT dbo.ElderArchive
    (IdNumber, ArchiveNo, FullName, BirthDate, Address, CommunityId, GuardianName, Tags)
SELECT CONCAT('00000019500101', RIGHT(CONCAT('0000', n),4)),
       CONCAT('E', RIGHT(CONCAT('0000', n),4)), CONCAT(N'演示老人 ', n),
       DATEFROMPARTS(1950,1,1), CONCAT(N'演示路 ', n, N' 号'), n, CONCAT(N'演示监护人 ', n),
       CASE WHEN n%2=0 THEN N'独居' ELSE N'日常照护' END
FROM @Samples s
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.ElderArchive e WHERE e.ArchiveNo=CONCAT('E',RIGHT(CONCAT('0000',s.n),4))
);

INSERT dbo.AbilityAssessment
    (AssessmentNo, ArchiveNo, ScaleCode, Score, AbilityLevel, EvaluatorName, AssessmentDate, ValidThrough)
SELECT CONCAT('V1-DEMO-ASMT-', n), e.ArchiveNo, 'ADL', 75, N'轻度失能', N'演示评估员',
       @Today, DATEADD(day, CASE WHEN n % 5=0 THEN 7 ELSE 60 END, @Today)
FROM @Samples s JOIN dbo.ElderArchive e
    ON e.ArchiveNo=CONCAT('E',RIGHT(CONCAT('0000',s.n),4))
WHERE LEFT(e.IdNumber,6)='000000'
  AND NOT EXISTS (SELECT 1 FROM dbo.AbilityAssessment a WHERE a.AssessmentNo=CONCAT('V1-DEMO-ASMT-',s.n));

INSERT dbo.ArchiveAudit(ArchiveNo, EventType, AfterCommunityId)
SELECT e.ArchiveNo, 'created', e.CommunityId
FROM dbo.ElderArchive e
WHERE LEFT(e.IdNumber,6)='000000'
  AND NOT EXISTS (SELECT 1 FROM dbo.ArchiveAudit a WHERE a.ArchiveNo=e.ArchiveNo);
COMMIT;
