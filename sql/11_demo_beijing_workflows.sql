USE [KanglaoCourse];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Now datetime2(0)=SYSUTCDATETIME(), @ArchiveNo varchar(20)='E0003', @CommunityId int=2;
DECLARE @Today date=CONVERT(date,DATEADD(hour,8,@Now));
DECLARE @OrderNo varchar(30)=CONCAT('DEMO-BJ-REASSIGN-',CONVERT(char(8),@Today,112));
DECLARE @FirstWorker int=(SELECT WorkerId FROM dbo.Worker WHERE WorkerNo='DEMO-WORKER-003' AND EmploymentStatus='ON_DUTY');
DECLARE @SecondWorker int=(SELECT WorkerId FROM dbo.Worker WHERE WorkerNo='DEMO-WORKER-002' AND EmploymentStatus='ON_DUTY');
DECLARE @ServiceId int=(SELECT ServiceTypeId FROM dbo.ServiceType WHERE Code='DEMO-SERVICE-003');
DECLARE @Start datetime2(0)=DATEADD(hour,3,@Now), @End datetime2(0), @ConflictEnd datetime2(0);
SET @End=DATEADD(hour,1,@Start);

BEGIN TRANSACTION;
EXEC dbo.usp_ServiceLock 'seed', N'beijing-workflows';
EXEC dbo.usp_ServiceLock 'archive', @ArchiveNo;
IF EXISTS (SELECT 1 FROM dbo.ServiceOrder WHERE OrderNo=@OrderNo)
   OR @FirstWorker IS NULL OR @SecondWorker IS NULL OR @ServiceId IS NULL
BEGIN
    COMMIT;
    RETURN;
END;

-- 沿用覆盖整个预约的班次，仅在现有班次间补入需要的时段。
WHILE 1=1
BEGIN
    SET @ConflictEnd=(SELECT MAX(EndsAt) FROM dbo.WorkerShift
        WHERE WorkerId IN (@FirstWorker,@SecondWorker) AND IsOpen=1 AND StartsAt<@End AND EndsAt>@Start
          AND (StartsAt>@Start OR EndsAt<@End));
    IF @ConflictEnd IS NULL BREAK;
    SET @Start=DATEADD(minute,5,@ConflictEnd);
    SET @End=DATEADD(hour,1,@Start);
END;

DECLARE @StartOn date=CONVERT(date,DATEADD(hour,8,@Start)), @EndOn date=CONVERT(date,DATEADD(hour,8,@End));
DECLARE @PlanId int;
SELECT @PlanId=planRow.PlanId
FROM dbo.ElderArchive elder
JOIN dbo.CarePlan planRow ON planRow.ArchiveNo=elder.ArchiveNo AND planRow.PlanNo='DEMO-PLAN-003'
JOIN dbo.CarePackage package ON package.PackageId=planRow.PackageId
JOIN dbo.v_CurrentAbilityAssessment assessment ON assessment.ArchiveNo=elder.ArchiveNo
    AND assessment.AbilityLevel=package.AbilityLevel AND assessment.ValidThrough>=@EndOn
WHERE elder.ArchiveNo=@ArchiveNo AND LEFT(elder.IdNumber,6)='000000' AND elder.IsActive=1 AND elder.CommunityId=@CommunityId
  AND planRow.Status='ACTIVE' AND planRow.StartsOn<=@StartOn AND planRow.EndsOn>=@EndOn;
IF @PlanId IS NULL
BEGIN
    COMMIT;
    PRINT N'改派样例未生成：沈桂芳当前的档案或照护计划已变更或到期。';
    RETURN;
END;

IF NOT EXISTS (SELECT 1 FROM dbo.WorkerCommunity WHERE WorkerId=@SecondWorker AND CommunityId=@CommunityId)
    INSERT dbo.WorkerCommunity(WorkerId,CommunityId) VALUES (@SecondWorker,@CommunityId);
IF NOT EXISTS (SELECT 1 FROM dbo.WorkerService WHERE WorkerId=@SecondWorker AND ServiceTypeId=@ServiceId)
    INSERT dbo.WorkerService(WorkerId,ServiceTypeId,CredentialNo,ValidFrom,ValidThrough,CredentialType,CredentialLevel)
    SELECT @SecondWorker,@ServiceId,N'模拟陪诊证书-002',ValidFrom,ValidThrough,CredentialType,CredentialLevel
    FROM dbo.WorkerService WHERE WorkerId=@FirstWorker AND ServiceTypeId=@ServiceId;

IF NOT EXISTS (SELECT 1 FROM dbo.WorkerShift WHERE WorkerId=@FirstWorker AND IsOpen=1 AND StartsAt<=@Start AND EndsAt>=@End)
    EXEC dbo.usp_CreateWorkerShift @FirstWorker,@Start,@End,4;
IF NOT EXISTS (SELECT 1 FROM dbo.WorkerShift WHERE WorkerId=@SecondWorker AND IsOpen=1 AND StartsAt<=@Start AND EndsAt>=@End)
    EXEC dbo.usp_CreateWorkerShift @SecondWorker,@Start,@End,4;

INSERT dbo.ServiceOrder(OrderNo,ArchiveNo,PlanId,ServiceTypeId,CommunityId,Status,Price,AppointmentStart,AppointmentEnd,
                        Address,Latitude,Longitude,Channel,CreatedAt,DispatchDeadline)
SELECT @OrderNo,@ArchiveNo,@PlanId,@ServiceId,@CommunityId,'NEW',service.Rate,@Start,@End,
       elder.Address,elder.Latitude,elder.Longitude,'COMMUNITY',@Now,DATEADD(minute,30,@Now)
FROM dbo.ElderArchive elder CROSS JOIN dbo.ServiceType service
WHERE elder.ArchiveNo=@ArchiveNo AND service.ServiceTypeId=@ServiceId;
DECLARE @OrderId int=CONVERT(int,SCOPE_IDENTITY());
IF (SELECT COUNT(DISTINCT WorkerId) FROM dbo.fn_EligibleServiceShifts(@OrderId)
    WHERE WorkerId IN (@FirstWorker,@SecondWorker))<>2
BEGIN
    ROLLBACK;
    PRINT N'改派样例未生成：两位样例护工当前无共同可接的班次或资质。';
    RETURN;
END;
EXEC dbo.usp_ServiceOrderAction @OrderId,'DISPATCH',@FirstWorker,@Now=@Now;
EXEC dbo.usp_ServiceOrderAction @OrderId,'ACCEPT',@FirstWorker,@Now=@Now;
COMMIT;
PRINT N'六道口社区的改派演示订单已准备。';
