USE [KanglaoCourse];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Now datetime2(0)=SYSUTCDATETIME();
DECLARE @Today date=CONVERT(date,DATEADD(hour,8,@Now));
DECLARE @People table (Seq int PRIMARY KEY, FullName nvarchar(30), BirthDate date, GuardianName nvarchar(30));
INSERT @People VALUES
    (21,N'赵淑芬','19490318',N'赵雪'),(22,N'冯德顺','19430729',N'冯立'),
    (23,N'钱桂芝','19551206',N'钱玥'),(24,N'褚和平','19460503',N'褚晨'),
    (25,N'卫玉梅','19540917',N'卫清'),(26,N'蒋文华','19531121',N'蒋宁'),
    (27,N'韩金凤','19420612',N'韩珊'),(28,N'杨承志','19570108',N'杨磊'),
    (29,N'许瑞英','19520823',N'许桐'),(30,N'朱洪林','19471202',N'朱婷'),
    (31,N'秦素云','19560327',N'秦芳'),(32,N'曹世荣','19441115',N'曹然'),
    (33,N'孔春梅','19500518',N'孔琳'),(34,N'严玉清','19490226',N'严辉'),
    (35,N'吕秀珍','19581011',N'吕宁'),(36,N'施正明','19510409',N'施杰'),
    (37,N'张秋菊','19410830',N'张媛'),(38,N'俞建华','19560214',N'俞峰'),
    (39,N'柏玉兰','19530607',N'柏松'),(40,N'窦长林','19451219',N'窦玥'),
    (41,N'苏秀琴','19570205',N'苏禾'),(42,N'章立言','19460528',N'章萱'),
    (43,N'云淑华','19500913',N'云璐'),(44,N'潘德海','19440327',N'潘阳'),
    (45,N'陶雪莲','19570625',N'陶婧'),(46,N'齐文斌','19510802',N'齐慧'),
    (47,N'任慧珍','19401217',N'任安'),(48,N'孔庆祥','19550412',N'孔毅'),
    (49,N'吴巧英','19560222',N'吴菲'),(50,N'洪志安','19470703',N'洪亮'),
    (51,N'韦凤霞','19500926',N'韦丹'),(52,N'马景福','19421230',N'马宁'),
    (53,N'石慧琴','19531204',N'石悦'),(54,N'方德仁','19470521',N'方昕'),
    (55,N'杜彩云','19580902',N'杜鹃'),(56,N'白志诚','19530324',N'白雪'),
    (57,N'汪玉娥','19420908',N'汪茜'),(58,N'孟学清','19560517',N'孟茹'),
    (59,N'郭慧芳','19520206',N'郭琳'),(60,N'宋建平','19540716',N'宋晨');

DECLARE @Samples table (
    ArchiveNo varchar(20) PRIMARY KEY, IdNumber char(18), Seq int, CommunityId int, ServiceSuffix char(3),
    AbilityLevel nvarchar(20), AssessedOn date, ValidThrough date, PackageId int, WorkerId int
);
DECLARE @NewArchives table (ArchiveNo varchar(20) PRIMARY KEY);
DECLARE @NewPlans table (ArchiveNo varchar(20) PRIMARY KEY, PlanId int);

BEGIN TRANSACTION;
EXEC dbo.usp_ServiceLock 'seed', N'more-archives';

INSERT @Samples
SELECT CONCAT('E',RIGHT(CONCAT('0000',person.Seq),4)),
       CONCAT('000000',CONVERT(char(8),person.BirthDate,112),RIGHT(CONCAT('0000',person.Seq),4)),
       person.Seq, community.CommunityId, suffix.Code, COALESCE(package.AbilityLevel,N'轻度失能'),
       CASE WHEN person.Seq%10<>0 THEN DATEADD(day,IIF(person.Seq%5=1,-60,-10),@Today) END,
       CASE WHEN person.Seq%10<>0 THEN DATEADD(day,CHOOSE(person.Seq%5+1,45,-3,7,45,60),@Today) END,
       package.PackageId, worker.WorkerId
FROM @People person
JOIN dbo.Community community ON community.CommunityId=CASE WHEN person.Seq<=32 THEN 1
    WHEN person.Seq<=40 THEN 2 ELSE person.Seq-40 END
    AND community.District=N'海淀演示区' AND community.StreetName=N'学院路街道'
CROSS APPLY (VALUES (RIGHT(CONCAT('000', CASE community.CommunityId
    WHEN 1 THEN 1+person.Seq%2 WHEN 2 THEN 3 WHEN 3 THEN NULL ELSE community.CommunityId END),3))) suffix(Code)
LEFT JOIN dbo.CarePlan template ON template.PlanNo=CONCAT('DEMO-PLAN-',suffix.Code)
LEFT JOIN dbo.CarePackage package ON package.PackageId=template.PackageId
LEFT JOIN dbo.Worker worker ON worker.WorkerId=template.ResponsibleWorkerId AND worker.EmploymentStatus='ON_DUTY';

INSERT dbo.ElderArchive(IdNumber,ArchiveNo,FullName,BirthDate,Address,CommunityId,GuardianName,Tags,
                        SubsidyCategory,Latitude,Longitude)
OUTPUT inserted.ArchiveNo INTO @NewArchives
SELECT sample.IdNumber,sample.ArchiveNo,person.FullName,person.BirthDate,
       CONCAT(community.CityName,community.AreaName,community.StreetName,community.Name,
              N'（演示住址 ',sample.Seq,N'）'),
       sample.CommunityId,person.GuardianName,
       CHOOSE(sample.Seq%5+1,N'与家人同住',N'重点随访',N'独居',N'出行需陪同',N'行动缓慢'),
       IIF(sample.Seq%6=0,'LOW_INCOME','GENERAL'),community.Latitude,community.Longitude
FROM @Samples sample JOIN @People person ON person.Seq=sample.Seq
JOIN dbo.Community community ON community.CommunityId=sample.CommunityId
WHERE NOT EXISTS (SELECT 1 FROM dbo.ElderArchive elder WITH (UPDLOCK,HOLDLOCK)
                  WHERE elder.ArchiveNo=sample.ArchiveNo OR elder.IdNumber=sample.IdNumber);

INSERT dbo.AbilityAssessment(AssessmentNo,ArchiveNo,ScaleCode,Score,AbilityLevel,EvaluatorName,AssessmentDate,ValidThrough)
SELECT CONCAT('DEMO-MORE-',sample.ArchiveNo),sample.ArchiveNo,'ADL',
       IIF(sample.AbilityLevel=N'重度失能',35,72)+sample.Seq%9,sample.AbilityLevel,
       CHOOSE(sample.Seq%3+1,N'韩春晓',N'顾清仪',N'杨舒'),sample.AssessedOn,sample.ValidThrough
FROM @Samples sample JOIN @NewArchives added ON added.ArchiveNo=sample.ArchiveNo
WHERE sample.AssessedOn IS NOT NULL;

INSERT dbo.CarePlan(PlanNo,ArchiveNo,PackageId,ResponsibleWorkerId,StartsOn,EndsOn,Status,ChangedReason)
OUTPUT inserted.ArchiveNo,inserted.PlanId INTO @NewPlans
SELECT CONCAT('DEMO-MORE-',sample.ArchiveNo),sample.ArchiveNo,sample.PackageId,sample.WorkerId,
       @Today,sample.ValidThrough,'ACTIVE',N'根据评估安排上门服务'
FROM @Samples sample JOIN @NewArchives added ON added.ArchiveNo=sample.ArchiveNo
JOIN dbo.WorkerCommunity coverage ON coverage.WorkerId=sample.WorkerId AND coverage.CommunityId=sample.CommunityId
WHERE sample.ValidThrough>=DATEADD(day,1,@Today);

INSERT dbo.ServiceOrder(OrderNo,ArchiveNo,PlanId,ServiceTypeId,CommunityId,Status,Price,AppointmentStart,
                        AppointmentEnd,Address,Latitude,Longitude,Channel,CreatedAt,DispatchDeadline,ReviewReason)
SELECT CONCAT('DEMO-MORE-',sample.ArchiveNo),sample.ArchiveNo,planRow.PlanId,service.ServiceTypeId,
       sample.CommunityId,IIF(sample.Seq%3=0,'POOL','NEW'),service.Rate*IIF(service.Unit=N'次',1,service.StandardMinutes/60.0),
       timing.StartsAt,DATEADD(minute,service.StandardMinutes,timing.StartsAt),elder.Address,elder.Latitude,
       elder.Longitude,CHOOSE(sample.Seq%3+1,'PHONE','COMMUNITY','FAMILY'),@Now,DATEADD(minute,30,@Now),
       IIF(sample.Seq%3=0,N'需值班员协调上门时段',NULL)
FROM @Samples sample JOIN @NewPlans planRow ON planRow.ArchiveNo=sample.ArchiveNo
JOIN dbo.ElderArchive elder ON elder.ArchiveNo=sample.ArchiveNo
JOIN dbo.ServiceType service ON service.Code=CONCAT('DEMO-SERVICE-',sample.ServiceSuffix)
JOIN dbo.CarePackageService packageService ON packageService.PackageId=sample.PackageId
    AND packageService.ServiceTypeId=service.ServiceTypeId
CROSS APPLY (VALUES (DATEADD(hour,2+sample.Seq%5,@Now))) timing(StartsAt);

DECLARE @ArchiveCount int=(SELECT COUNT(*) FROM @NewArchives);
DECLARE @PlanCount int=(SELECT COUNT(*) FROM @NewPlans);
COMMIT;
PRINT CONCAT(N'本次补充演示档案 ',@ArchiveCount,N' 份、照护计划 ',@PlanCount,N' 份。');
