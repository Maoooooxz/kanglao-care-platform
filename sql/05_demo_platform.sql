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
DECLARE @Samples table (
    n int PRIMARY KEY, CommunityName nvarchar(30), ElderName nvarchar(30), GuardianName nvarchar(30),
    BirthDate date, Address nvarchar(80), Tags nvarchar(50)
);
INSERT @Samples VALUES
    (1, N'清溪里社区', N'周秀兰', N'周敏', '19500101', N'清溪里 3 号楼 2 单元', N'行动缓慢、助餐'),
    (2, N'松荫苑社区', N'刘建民', N'刘晓静', '19480202', N'清溪里 7 号楼 1 单元', N'独居、助浴'),
    (3, N'竹风巷社区', N'沈桂芳', N'沈佳', '19520303', N'松荫苑 2 号楼 3 单元', N'陪诊、听力不便'),
    (4, N'梧桐庭社区', N'梁志远', N'梁悦', '19421211', N'梧桐庭 5 号楼 1 单元', N'失能、低保、家政'),
    (5, N'溪桥北社区', N'杜淑琴', N'杜蕾', '19530508', N'溪桥北 2 号楼 2 单元', N'康复随访'),
    (6, N'柳湾里社区', N'田有福', N'田雪', '19480724', N'柳湾里 6 号楼 1 单元', N'独居、助餐'),
    (7, N'香樟院社区', N'苏玉珍', N'苏琳', '19560817', N'香樟院 4 号楼 3 单元', N'助浴、重点关注'),
    (8, N'青禾街社区', N'许文斌', N'许淼', '19450527', N'青禾街 8 号楼 2 单元', N'失能、低保、陪诊'),
    (9, N'玉兰路社区', N'方桂英', N'方宁', '19520116', N'玉兰路 5 号楼 2 单元', N'居家清洁'),
    (10, N'望山里社区', N'秦德庆', N'秦茹', '19540720', N'望山里 3 号楼 1 单元', N'独居、助行训练'),
    (11, N'榆林小院社区', N'姜素芬', N'姜怡', '19550401', N'榆林小院 2 号楼 2 单元', N'送餐、重点关注'),
    (12, N'丁香园社区', N'何春生', N'何远', '19430804', N'丁香园 9 号楼 1 单元', N'失能、低保、床旁照护'),
    (13, N'枫林东社区', N'邹雪梅', N'邹璇', '19580916', N'枫林东 3 号楼 2 单元', N'陪诊、用药提醒'),
    (14, N'景和里社区', N'程国安', N'程晨', '19501006', N'景和里 1 号楼 3 单元', N'独居、家务整理'),
    (15, N'银杏西社区', N'侯爱莲', N'侯晴', '19511015', N'银杏西 5 号楼 1 单元', N'关节活动训练'),
    (16, N'槐影小区', N'邵明德', N'邵昕', '19411021', N'槐影小区 2 号楼 1 单元', N'失能、低保、送餐'),
    (17, N'晴川里社区', N'郑慧茹', N'郑兰', '19550713', N'晴川里 7 号楼 3 单元', N'助浴、防跌倒'),
    (18, N'月桥南社区', N'邱守义', N'邱杰', '19520219', N'月桥南 1 号楼 2 单元', N'独居、检查陪同'),
    (19, N'听松苑社区', N'潘丽华', N'潘欣', '19570129', N'听松苑 4 号楼 1 单元', N'家务支持'),
    (20, N'春泉里社区', N'袁金福', N'袁媛', '19391102', N'春泉里 6 号楼 2 单元', N'失能、低保、康复随访');

DECLARE @BeijingCommunities table (n int PRIMARY KEY, Name nvarchar(30));
INSERT @BeijingCommunities VALUES
    (1,N'北京林业大学社区'),(2,N'六道口社区'),(3,N'展春园社区'),(4,N'西王庄社区'),
    (5,N'东王庄社区'),(6,N'志新社区'),(7,N'五道口嘉园社区'),(8,N'二里庄社区'),
    (9,N'学知园社区'),(10,N'健翔园社区'),(11,N'静淑苑社区'),(12,N'建清园社区'),
    (13,N'逸成社区'),(14,N'北语社区'),(15,N'北科大社区'),(16,N'农大社区'),
    (17,N'石科院社区'),(18,N'矿大社区'),(19,N'学清苑社区'),(20,N'城华清枫社区');

BEGIN TRANSACTION;
INSERT dbo.Community(CommunityId, Name, District, Latitude, Longitude, RadiusMeters, CityName, AreaName, StreetName)
SELECT n, Name, N'海淀演示区', 40.008, 116.341, 3000, N'北京市', N'海淀区', N'学院路街道'
FROM @BeijingCommunities sample WHERE NOT EXISTS (SELECT 1 FROM dbo.Community c WHERE c.CommunityId=sample.n);

UPDATE community SET Name=beijing.Name, CityName=N'北京市', AreaName=N'海淀区', StreetName=N'学院路街道'
FROM dbo.Community community JOIN @Samples sample ON sample.n=community.CommunityId
JOIN @BeijingCommunities beijing ON beijing.n=sample.n
WHERE community.District=N'海淀演示区'
  AND (community.Name IN (sample.CommunityName,beijing.Name,CONCAT(N'演示社区 ',sample.n))
       OR (sample.n=1 AND community.Name=N'示例社区甲') OR (sample.n=2 AND community.Name=N'示例社区乙'));

UPDATE account SET DisplayName=CONCAT(community.Name,N'服务台')
FROM dbo.AppUser account
JOIN @Samples sample ON account.Username=CONCAT('community',RIGHT(CONCAT('00',sample.n),2))
JOIN dbo.Community community ON community.CommunityId=sample.n AND community.CityName=N'北京市'
WHERE account.Role='community' AND account.CommunityId=sample.n
  AND account.DisplayName=CONCAT(sample.CommunityName,N'服务台');

INSERT dbo.ElderArchive
    (IdNumber, ArchiveNo, FullName, BirthDate, Address, CommunityId, GuardianName, Tags, SubsidyCategory)
SELECT CONCAT('000000',CONVERT(char(8),s.BirthDate,112),RIGHT(CONCAT('0000', n),4)),
       CONCAT('E', RIGHT(CONCAT('0000', n),4)), s.ElderName,
       s.BirthDate, s.Address, CASE WHEN n<=2 THEN 1 WHEN n=3 THEN 2 ELSE n END, s.GuardianName, s.Tags,
       IIF(n%4=0,'LOW_INCOME','GENERAL')
FROM @Samples s
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.ElderArchive e WHERE e.ArchiveNo=CONCAT('E',RIGHT(CONCAT('0000',s.n),4))
);

UPDATE elder SET FullName=sample.ElderName,
    Address=CASE WHEN elder.Address=CONCAT(N'演示路 ',sample.n,N' 号') THEN sample.Address ELSE elder.Address END,
    GuardianName=CASE WHEN elder.GuardianName IS NULL OR elder.GuardianName=CONCAT(N'演示监护人 ',sample.n)
                      THEN sample.GuardianName ELSE elder.GuardianName END,
    Tags=CASE WHEN elder.Tags IS NULL OR elder.Tags IN (N'独居',N'日常照护') THEN sample.Tags ELSE elder.Tags END
FROM dbo.ElderArchive elder JOIN @Samples sample ON elder.ArchiveNo=CONCAT('E',RIGHT(CONCAT('0000',sample.n),4))
WHERE LEFT(elder.IdNumber,6)='000000'
  AND (elder.FullName=CONCAT(N'演示老人 ',sample.n)
       OR (sample.n<=3 AND elder.FullName=CHOOSE(sample.n,N'示例老人甲',N'示例老人乙',N'示例老人丙')));

UPDATE elder SET Address=CONCAT(N'北京市海淀区学院路街道',community.Name,N'（演示住址 ',sample.n,N'）')
FROM dbo.ElderArchive elder
JOIN @Samples sample ON elder.ArchiveNo=CONCAT('E',RIGHT(CONCAT('0000',sample.n),4))
JOIN dbo.Community community ON community.CommunityId=elder.CommunityId
    AND community.CommunityId=CASE WHEN sample.n<=2 THEN 1 WHEN sample.n=3 THEN 2 ELSE sample.n END
WHERE LEFT(elder.IdNumber,6)='000000' AND community.CityName=N'北京市' AND community.StreetName=N'学院路街道'
  AND elder.Address IN (sample.Address,CONCAT(N'演示路 ',sample.n,N' 号'))
  AND NOT EXISTS (SELECT 1 FROM dbo.ArchiveAudit audit
                  WHERE audit.ArchiveNo=elder.ArchiveNo AND audit.EventType='transferred');

INSERT dbo.AbilityAssessment
    (AssessmentNo, ArchiveNo, ScaleCode, Score, AbilityLevel, EvaluatorName, AssessmentDate, ValidThrough)
SELECT CONCAT('V1-DEMO-ASMT-', n), e.ArchiveNo, 'ADL', IIF(n%4=0,40,75),
       IIF(n%4=0,N'重度失能',N'轻度失能'), CHOOSE((n-1)%3+1,N'韩春晓',N'顾清仪',N'杨舒'),
       DATEADD(day,IIF(n=2,-30,0),@Today),
       DATEADD(day, CASE WHEN n=2 THEN -1 WHEN n % 5=0 THEN 7 WHEN n=1 THEN 12 ELSE 60 END, @Today)
FROM @Samples s JOIN dbo.ElderArchive e
    ON e.ArchiveNo=CONCAT('E',RIGHT(CONCAT('0000',s.n),4))
WHERE LEFT(e.IdNumber,6)='000000'
  AND NOT EXISTS (SELECT 1 FROM dbo.AbilityAssessment a WHERE a.AssessmentNo=CONCAT('V1-DEMO-ASMT-',s.n));

UPDATE assessment SET EvaluatorName=CHOOSE((sample.n-1)%3+1,N'韩春晓',N'顾清仪',N'杨舒')
FROM dbo.AbilityAssessment assessment
JOIN @Samples sample ON assessment.AssessmentNo=CONCAT('V1-DEMO-ASMT-',sample.n)
    AND assessment.ArchiveNo=CONCAT('E',RIGHT(CONCAT('0000',sample.n),4))
WHERE assessment.EvaluatorName=N'演示评估员';

-- 只调整旧版预置的结果，保留用户实际登记的复评。
UPDATE seeded SET AssessmentDate=DATEADD(day,-30,seeded.AssessmentDate),
    ValidThrough=DATEADD(day,-1,seeded.AssessmentDate)
FROM dbo.AbilityAssessment seeded JOIN dbo.ElderArchive elder ON elder.ArchiveNo=seeded.ArchiveNo
WHERE seeded.ArchiveNo='E0002' AND LEFT(elder.IdNumber,6)='000000'
  AND seeded.AssessmentNo='V1-DEMO-ASMT-2' AND seeded.ValidThrough=DATEADD(day,60,seeded.AssessmentDate)
  AND NOT EXISTS (
      SELECT 1 FROM dbo.AbilityAssessment other
      WHERE other.ArchiveNo=seeded.ArchiveNo AND other.AssessmentNo NOT IN ('DEMO-ASMT-03','V1-DEMO-ASMT-2')
  );

INSERT dbo.ArchiveAudit(ArchiveNo, EventType, AfterCommunityId)
SELECT e.ArchiveNo, 'created', e.CommunityId
FROM dbo.ElderArchive e
WHERE LEFT(e.IdNumber,6)='000000'
  AND NOT EXISTS (SELECT 1 FROM dbo.ArchiveAudit a WHERE a.ArchiveNo=e.ArchiveNo);
COMMIT;
