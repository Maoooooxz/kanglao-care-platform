USE [KanglaoCourse];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_WARNINGS ON;
SET ANSI_PADDING ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;

DECLARE @District nvarchar(80)=N'课设抽查演示区', @CommunityId int=21021,
        @ArchiveNo varchar(20)='DEMO-COURSE-ELDER', @AgencyId int, @WorkerId int,
        @Civil int, @Manager int, @Family int, @ServiceTypeId int, @PackageId int, @AbilityLevel nvarchar(20);
SELECT @ServiceTypeId=ServiceTypeId FROM dbo.ServiceType WHERE Code='DEMO-SERVICE-001';
SELECT @PackageId=PackageId,@AbilityLevel=AbilityLevel FROM dbo.CarePackage WHERE Name=N'演示照护包001';
IF @ServiceTypeId IS NULL OR @PackageId IS NULL THROW 52107, N'请先初始化服务项目和照护包示例。', 1;

BEGIN TRANSACTION;
EXEC dbo.usp_ServiceLock 'seed', N'completion';
IF EXISTS (SELECT 1 FROM dbo.Community WHERE CommunityId=@CommunityId AND District<>@District)
   OR EXISTS (SELECT 1 FROM dbo.ElderArchive WHERE ArchiveNo=@ArchiveNo AND IdNumber<>'000000195001019891')
    THROW 52107, N'课设抽查演示编号与现有数据冲突。', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.Community WHERE CommunityId=@CommunityId)
    INSERT dbo.Community(CommunityId,Name,District) VALUES (@CommunityId,N'抽查演示社区',@District);
IF NOT EXISTS (SELECT 1 FROM dbo.ElderArchive WHERE ArchiveNo=@ArchiveNo)
    INSERT dbo.ElderArchive(IdNumber,ArchiveNo,FullName,BirthDate,Address,CommunityId)
    VALUES ('000000195001019891',@ArchiveNo,N'抽查样例老人','19500101',N'抽查演示地址',@CommunityId);
IF NOT EXISTS (SELECT 1 FROM dbo.Agency WHERE AgencyNo='DEMO-COURSE-AGENCY')
    INSERT dbo.Agency(AgencyNo,Name,District) VALUES ('DEMO-COURSE-AGENCY',N'抽查示例机构',@District);
SELECT @AgencyId=AgencyId FROM dbo.Agency WHERE AgencyNo='DEMO-COURSE-AGENCY' AND District=@District;
IF @AgencyId IS NULL THROW 52107, N'抽查示例机构不在演示辖区。', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.Worker WHERE WorkerNo='DEMO-COURSE-WORKER')
    INSERT dbo.Worker(WorkerNo,AgencyId,Name,Grade) VALUES ('DEMO-COURSE-WORKER',@AgencyId,N'抽查样例护工',N'演示护工');
SELECT @WorkerId=WorkerId FROM dbo.Worker WHERE WorkerNo='DEMO-COURSE-WORKER' AND AgencyId=@AgencyId;
IF @WorkerId IS NULL THROW 52107, N'抽查样例护工不在演示机构。', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.WorkerCommunity WHERE WorkerId=@WorkerId AND CommunityId=@CommunityId)
    INSERT dbo.WorkerCommunity(WorkerId,CommunityId) VALUES (@WorkerId,@CommunityId);

INSERT dbo.AppUser(Username,DisplayName,PasswordHash,Role,ArchiveNo,AgencyId,District)
SELECT sample.Username,sample.DisplayName,base.PasswordHash,sample.Role,sample.ArchiveNo,sample.AgencyId,sample.District
FROM (VALUES ('civil-course-demo',N'抽查演示监管员','civil',NULL,NULL,@District),
             ('agency-course-demo',N'抽查演示机构负责人','agency',NULL,@AgencyId,NULL),
             ('family-course-demo',N'抽查演示家属','family',@ArchiveNo,NULL,NULL)
) sample(Username,DisplayName,Role,ArchiveNo,AgencyId,District)
JOIN dbo.AppUser base ON base.Username=sample.Role
WHERE NOT EXISTS (SELECT 1 FROM dbo.AppUser account WHERE account.Username=sample.Username);
SELECT @Civil=UserId FROM dbo.AppUser WHERE Username='civil-course-demo' AND Role='civil' AND Active=1 AND District=@District;
SELECT @Manager=UserId FROM dbo.AppUser WHERE Username='agency-course-demo' AND Role='agency' AND Active=1 AND AgencyId=@AgencyId;
SELECT @Family=UserId FROM dbo.AppUser WHERE Username='family-course-demo' AND Role='family' AND Active=1 AND ArchiveNo=@ArchiveNo;
IF @Civil IS NULL OR @Manager IS NULL OR @Family IS NULL
    THROW 52107, N'请先初始化抽查演示所需账号。', 1;

DECLARE @Months table (PeriodMonth date PRIMARY KEY, PlanNo varchar(30), OrderNo varchar(30),
                       StartsAt datetime2(0), EndsAt datetime2(0));
INSERT @Months(PeriodMonth,PlanNo,OrderNo,StartsAt,EndsAt)
SELECT months.PeriodMonth,CONCAT('DEMO-COURSE-PLAN-',stamp.Code),CONCAT('DEMO-COURSE-',stamp.Code),
       times.StartsAt,DATEADD(hour,1,times.StartsAt)
FROM (VALUES(3),(4),(5),(6),(7),(8),(9),(10),(11),(12),(13),(14),(15),(16),(17),(18),(19),(20),(21),(22)) seq(MonthOffset)
CROSS APPLY (VALUES(CONVERT(date,DATEADD(month,-seq.MonthOffset,DATETRUNC(month,DATEADD(hour,8,SYSUTCDATETIME())))))) months(PeriodMonth)
CROSS APPLY (VALUES(LEFT(CONVERT(char(8),months.PeriodMonth,112),6))) stamp(Code)
CROSS APPLY (VALUES(DATEADD(hour,2,CONVERT(datetime2(0),DATEADD(day,7,months.PeriodMonth))))) times(StartsAt);

INSERT dbo.CarePlan(PlanNo,ArchiveNo,PackageId,ResponsibleWorkerId,StartsOn,EndsOn,Status,ChangedReason)
SELECT monthRow.PlanNo,@ArchiveNo,@PackageId,@WorkerId,monthRow.PeriodMonth,EOMONTH(monthRow.PeriodMonth),
       'ENDED',N'已归档的合成历史照护'
FROM @Months monthRow WHERE NOT EXISTS (SELECT 1 FROM dbo.CarePlan planRow WHERE planRow.PlanNo=monthRow.PlanNo);

INSERT dbo.WorkerShift(WorkerId,StartsAt,EndsAt,Capacity)
SELECT @WorkerId,monthRow.StartsAt,monthRow.EndsAt,1 FROM @Months monthRow
WHERE NOT EXISTS (SELECT 1 FROM dbo.WorkerShift shift WHERE shift.WorkerId=@WorkerId AND shift.StartsAt=monthRow.StartsAt);

INSERT dbo.ServiceOrder(OrderNo,ArchiveNo,PlanId,ServiceTypeId,CommunityId,Status,Price,AppointmentStart,AppointmentEnd,
                        Address,Latitude,Longitude,Channel,CreatedAt,DispatchDeadline)
SELECT monthRow.OrderNo,@ArchiveNo,planRow.PlanId,@ServiceTypeId,@CommunityId,'COMPLETED',40.00,
       monthRow.StartsAt,monthRow.EndsAt,elder.Address,elder.Latitude,elder.Longitude,'COMMUNITY',
       DATEADD(hour,-2,monthRow.StartsAt),DATEADD(hour,-1,monthRow.StartsAt)
FROM @Months monthRow JOIN dbo.CarePlan planRow ON planRow.PlanNo=monthRow.PlanNo
JOIN dbo.ElderArchive elder ON elder.ArchiveNo=@ArchiveNo
WHERE NOT EXISTS (SELECT 1 FROM dbo.ServiceOrder orders WHERE orders.OrderNo=monthRow.OrderNo);

INSERT dbo.ServiceDispatch(OrderId,WorkerId,ShiftId,OfferedAt,OfferExpiresAt,AcceptedAt,ClosedAt,CloseReason)
SELECT orders.OrderId,@WorkerId,shift.ShiftId,DATEADD(hour,-2,monthRow.StartsAt),DATEADD(hour,-1,monthRow.StartsAt),
       DATEADD(minute,-90,monthRow.StartsAt),monthRow.EndsAt,N'服务完成'
FROM @Months monthRow JOIN dbo.ServiceOrder orders ON orders.OrderNo=monthRow.OrderNo
JOIN dbo.WorkerShift shift ON shift.WorkerId=@WorkerId AND shift.StartsAt=monthRow.StartsAt
WHERE NOT EXISTS (SELECT 1 FROM dbo.ServiceDispatch dispatch WHERE dispatch.OrderId=orders.OrderId);

INSERT dbo.ServiceVisit(OrderId,DispatchId,WorkerId,CheckInAt,CheckOutAt,InLatitude,InLongitude,OutLatitude,OutLongitude,
    InFence,OutFence,InShift,OutShift,ServiceRecord,WorkStatus,EffectiveMinutes,ConfirmedAt,ConfirmedBy,ConfirmationText,
    ConfirmationHash,SubsidyCategory,SubsidyAbilityLevel)
SELECT orders.OrderId,dispatch.DispatchId,@WorkerId,monthRow.StartsAt,monthRow.EndsAt,orders.Latitude,orders.Longitude,
       orders.Latitude,orders.Longitude,1,1,1,1,N'按照护计划完成合成上门服务。','VALID',60,monthRow.EndsAt,
       @Family,N'合成家属确认',dbo.fn_ServiceConfirmationHash(orders.OrderId,@Family,monthRow.EndsAt,N'合成家属确认'),
       'GENERAL',@AbilityLevel
FROM @Months monthRow JOIN dbo.ServiceOrder orders ON orders.OrderNo=monthRow.OrderNo
JOIN dbo.ServiceDispatch dispatch ON dispatch.OrderId=orders.OrderId
WHERE NOT EXISTS (SELECT 1 FROM dbo.ServiceVisit visit WHERE visit.OrderId=orders.OrderId);
COMMIT;

DECLARE @Month date, @BatchId int, @OrderId int;
DECLARE demo_months CURSOR LOCAL FAST_FORWARD FOR SELECT PeriodMonth FROM @Months ORDER BY PeriodMonth;
OPEN demo_months;
FETCH NEXT FROM demo_months INTO @Month;
WHILE @@FETCH_STATUS=0
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM dbo.ServiceOrder orders JOIN dbo.ServiceVisit visit ON visit.OrderId=orders.OrderId
        JOIN dbo.Community community ON community.CommunityId=orders.CommunityId
        WHERE community.District=@District AND orders.Status='COMPLETED'
          AND DATEFROMPARTS(YEAR(DATEADD(hour,8,visit.CheckOutAt)),MONTH(DATEADD(hour,8,visit.CheckOutAt)),1)=@Month
          AND NOT EXISTS (SELECT 1 FROM @Months monthRow WHERE monthRow.OrderNo=orders.OrderNo)
    )
    BEGIN
        EXEC dbo.usp_CreateInspectionBatch @Civil,@Month,10;
        SELECT @BatchId=batch.BatchId,@OrderId=orders.OrderId
        FROM dbo.InspectionBatch batch JOIN @Months monthRow ON monthRow.PeriodMonth=batch.PeriodMonth
        JOIN dbo.ServiceOrder orders ON orders.OrderNo=monthRow.OrderNo
        JOIN dbo.InspectionBatchOrder item ON item.BatchId=batch.BatchId AND item.OrderId=orders.OrderId
        WHERE batch.ReviewDistrict=@District AND batch.PeriodMonth=@Month AND batch.TargetCount=1 AND batch.PopulationCount=1;
        IF @@ROWCOUNT=1
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM dbo.ServiceInspection WHERE OrderId=@OrderId AND ReviewDistrict=@District)
            BEGIN
                EXEC dbo.usp_RegisterSampleInspection @Civil,@BatchId,@OrderId,85,N'合成服务记录核查通过','PHONE';
                UPDATE inspection SET InspectedAt=DATEADD(day,1,visit.CheckOutAt), ClosedAt=DATEADD(day,1,visit.CheckOutAt)
                FROM dbo.ServiceInspection inspection JOIN dbo.ServiceVisit visit ON visit.OrderId=inspection.OrderId
                WHERE inspection.OrderId=@OrderId AND inspection.ReviewDistrict=@District
                  AND inspection.Finding=N'合成服务记录核查通过';
            END;
            EXEC dbo.usp_PublishInspectionBatch @Civil,@BatchId;
            EXEC dbo.usp_SubmitAgencyAssessment @Manager,@Month;
        END;
    END;
    FETCH NEXT FROM demo_months INTO @Month;
END;
CLOSE demo_months;
DEALLOCATE demo_months;
PRINT N'抽查、公示及机构考核合成样例已就绪。';
GO
