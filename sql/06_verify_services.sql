USE [KanglaoCourse];
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF DB_NAME() <> N'KanglaoCourse' OR @@TRANCOUNT <> 0
    THROW 51270, N'请在独立的新会话中验证。', 1;

DECLARE @Today date = CONVERT(date, DATEADD(hour, 8, SYSUTCDATETIME()));
-- 从同一北京时间日期的 23:15 开始，验证跨日到期及服务中订单。
DECLARE @SimNow datetime2(0) = DATEADD(minute, 915, CONVERT(datetime2(0), @Today));
DECLARE @AfterExpiry datetime2(0) = DATEADD(minute, 50, @SimNow);
DECLARE @ArchiveNo varchar(20) = 'E0001', @WorkerId int, @Order1 int, @Order2 int, @Order3 int, @PlanId int;
DECLARE @FamilyActor int = (SELECT TOP (1) UserId FROM dbo.AppUser WHERE Role = 'family'
                           AND Active = 1 AND ArchiveNo = @ArchiveNo ORDER BY UserId);
IF @FamilyActor IS NULL THROW 51270, N'请先生成该档案对应的模拟家属账号。', 1;
DECLARE @PackageId int = (SELECT PackageId FROM dbo.CarePlan WHERE PlanNo='DEMO-PLAN-001');
DECLARE @ServiceTypeId int = (SELECT ServiceTypeId FROM dbo.ServiceType WHERE Code = 'DEMO-SERVICE-001');
DECLARE @AgencyId int = (SELECT AgencyId FROM dbo.Agency WHERE AgencyNo = 'DEMO-AGENCY-001');
DECLARE @CommunityId int = (SELECT CommunityId FROM dbo.ElderArchive WHERE ArchiveNo = @ArchiveNo);
DECLARE @AbilityLevel nvarchar(20) = (SELECT AbilityLevel FROM dbo.CarePackage WHERE PackageId = @PackageId);
DECLARE @Tomorrow date = DATEADD(day, 1, @Today), @NextWeek date = DATEADD(day, 7, @Today);
DECLARE @ShiftEnd datetime2(0) = DATEADD(hour, 2, @SimNow);
DECLARE @FirstStart datetime2(0) = DATEADD(minute, 10, @SimNow), @FirstEnd datetime2(0) = DATEADD(minute, 20, @SimNow);
DECLARE @SecondStart datetime2(0) = DATEADD(minute, 22, @SimNow), @SecondEnd datetime2(0) = DATEADD(minute, 30, @SimNow);
DECLARE @ThirdStart datetime2(0) = DATEADD(minute, 32, @SimNow), @ThirdEnd datetime2(0) = DATEADD(minute, 36, @SimNow);

BEGIN TRY
    BEGIN TRANSACTION;

    UPDATE dbo.CarePlan SET Status = 'ENDED', ChangedReason = N'仅事务内验证'
    WHERE ArchiveNo = @ArchiveNo AND Status <> 'ENDED';
    EXEC dbo.usp_RecordAbilityAssessment 'VERIFY-SERVICES', @ArchiveNo, 'ADL', 75,
        @AbilityLevel, N'模拟测试评估员', @Today, @Today;
    INSERT dbo.Worker(WorkerNo, AgencyId, Name, Grade) VALUES ('VERIFY-WORKER', @AgencyId, N'测试护工', N'测试等级');
    SET @WorkerId = CONVERT(int, SCOPE_IDENTITY());
    INSERT dbo.WorkerCommunity VALUES (@WorkerId, @CommunityId);
    EXEC dbo.usp_SetWorkerCredential @WorkerId, @ServiceTypeId, N'测试资格', @Today, @NextWeek;
    EXEC dbo.usp_CreateWorkerShift @WorkerId, @SimNow, @ShiftEnd, 2;
    EXEC dbo.usp_CreateCarePlan @ArchiveNo, @PackageId, @WorkerId, @Today, @NextWeek;
    SET @PlanId = (SELECT PlanId FROM dbo.CarePlan WHERE ResponsibleWorkerId = @WorkerId);

    EXEC dbo.usp_CreateServiceOrder @ArchiveNo, @ServiceTypeId, @FirstStart, @FirstEnd, NULL, NULL, NULL, 'COMMUNITY', @SimNow;
    EXEC dbo.usp_CreateServiceOrder @ArchiveNo, @ServiceTypeId, @SecondStart, @SecondEnd, NULL, NULL, NULL, 'COMMUNITY', @SimNow;
    EXEC dbo.usp_CreateServiceOrder @ArchiveNo, @ServiceTypeId, @ThirdStart, @ThirdEnd, NULL, NULL, NULL, 'COMMUNITY', @SimNow;
    SELECT @Order1 = MAX(CASE WHEN AppointmentStart = @FirstStart THEN OrderId END),
           @Order2 = MAX(CASE WHEN AppointmentStart = @SecondStart THEN OrderId END),
           @Order3 = MAX(CASE WHEN AppointmentStart = @ThirdStart THEN OrderId END)
    FROM dbo.ServiceOrder WHERE PlanId = @PlanId;

    EXEC dbo.usp_ServiceOrderAction @Order1, 'DISPATCH', @WorkerId, @Now = @SimNow;
    EXEC dbo.usp_ServiceOrderAction @Order2, 'DISPATCH', @WorkerId, @Now = @SimNow;
    EXEC dbo.usp_ServiceOrderAction @Order3, 'DISPATCH', @WorkerId, @Now = @SimNow;
    EXEC dbo.usp_ServiceOrderAction @Order1, 'ACCEPT', @WorkerId, @Now = @SimNow;
    EXEC dbo.usp_ServiceOrderAction @Order2, 'ACCEPT', @WorkerId, @Now = @SimNow;
    IF EXISTS (SELECT 1 FROM dbo.fn_EligibleServiceShifts(@Order3) WHERE WorkerId = @WorkerId)
        THROW 51271, N'班次名额用完后仍可作为接单候选。', 1;

    EXEC dbo.usp_ServiceOrderAction @Order1, 'CHECK_IN', @WorkerId, @Now = @FirstStart;
    EXEC dbo.usp_ProcessServiceTimeouts @AfterExpiry;
    IF NOT EXISTS (SELECT 1 FROM dbo.CarePlan WHERE PlanId = @PlanId AND Status = 'PAUSED')
        THROW 51272, N'评估过期后照护计划未暂停。', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.ServiceOrder WHERE OrderId = @Order2 AND Status = 'REVIEW')
        THROW 51273, N'已接单待上门的订单未进入人工复核。', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.ServiceOrder WHERE OrderId = @Order1 AND Status = 'IN_SERVICE')
        OR NOT EXISTS (SELECT 1 FROM dbo.ServiceVisit WHERE OrderId = @Order1 AND ExpiredDuringVisit = 1)
        THROW 51274, N'进行中服务的状态或评估到期记录有误。', 1;

    EXEC dbo.usp_ServiceOrderAction @Order1, 'CHECK_OUT', @WorkerId, N'测试签退并保存服务记录', @Now = @AfterExpiry;
    IF NOT EXISTS (
        SELECT 1 FROM dbo.ServiceVisit WHERE OrderId = @Order1 AND WorkStatus = 'REVIEW'
            AND EffectiveMinutes IS NULL AND OutFence = 1 AND OutShift = 1 AND ReviewReason LIKE N'%晚于预约%'
    )
        THROW 51275, N'即使仍在班次和围栏内，超时签退也须人工复核。', 1;
    IF EXISTS (SELECT 1 FROM dbo.v_SubsidyEligibleOrder WHERE OrderId = @Order1)
        THROW 51275, N'尚未家属签字的记录不能申报补贴。', 1;
    EXEC dbo.usp_ServiceOrderAction @Order1, 'CONFIRM', @Reason = N'模拟家属签字', @ActorId = @FamilyActor, @Now = @AfterExpiry;
    IF EXISTS (SELECT 1 FROM dbo.v_SubsidyEligibleOrder WHERE OrderId = @Order1)
        THROW 51276, N'签字不能使待复核工时获得补贴资格。', 1;
    EXEC dbo.usp_ServiceOrderAction @Order1, 'WORK_APPROVE', @Reason = N'人工确认超时服务属实', @Now = @AfterExpiry;
    IF NOT EXISTS (SELECT 1 FROM dbo.v_SubsidyEligibleOrder WHERE OrderId = @Order1 AND WorkerId = @WorkerId AND EffectiveMinutes > 0)
        THROW 51276, N'服务签退及家属签字后无法追溯有效工时。', 1;
    EXEC dbo.usp_ServiceOrderAction @Order1, 'COMPLAIN', @Reason = N'验证投诉', @ActorId = @FamilyActor, @Now = @AfterExpiry;
    EXEC dbo.usp_ServiceOrderAction @Order1, 'COMPLAINT_RESOLVE', @Reason = N'验证处理', @ActorId = 2, @Now = @AfterExpiry;
    IF NOT EXISTS (SELECT 1 FROM dbo.ServiceVisit WHERE OrderId = @Order1
                   AND ComplaintText = N'验证投诉' AND ComplaintResolution = N'验证处理')
        THROW 51277, N'投诉和回复未关联至服务订单。', 1;

    ROLLBACK;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    THROW;
END CATCH;

IF EXISTS (SELECT 1 FROM dbo.Worker WHERE WorkerNo = 'VERIFY-WORKER')
    THROW 51278, N'验证数据未回滚。', 1;

DECLARE @DemoWorker int = (SELECT WorkerId FROM dbo.Worker WHERE WorkerNo = 'DEMO-WORKER-001');
DECLARE @ExistingStart datetime2(0), @ExistingEnd datetime2(0);
SELECT TOP (1) @ExistingStart = StartsAt, @ExistingEnd = EndsAt
FROM dbo.WorkerShift WHERE WorkerId = @DemoWorker AND IsOpen = 1 ORDER BY StartsAt DESC;
BEGIN TRY
    BEGIN TRANSACTION;
    EXEC dbo.usp_CreateWorkerShift @DemoWorker, @ExistingStart, @ExistingEnd, 1;
    ROLLBACK;
    THROW 51279, N'同一护工可提交重叠班次。', 1;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    IF ERROR_NUMBER() <> 51207 THROW;
END CATCH;
PRINT N'PASS 照护、班次、评估过期、超时工时复核与家属签字，并回滚。';
GO
