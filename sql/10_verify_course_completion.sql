USE [KanglaoCourse];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_WARNINGS ON;
SET ANSI_PADDING ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;

IF DB_NAME()<>N'KanglaoCourse' OR @@TRANCOUNT<>0
    THROW 52130, N'请在独立会话中验证补齐功能。', 1;

DECLARE @Civil int=(SELECT UserId FROM dbo.AppUser WHERE Username='civil'),
        @Street int=(SELECT UserId FROM dbo.AppUser WHERE Username='street'),
        @Agency int=(SELECT UserId FROM dbo.AppUser WHERE Username='agency'),
        @OutsideCivil int=(SELECT UserId FROM dbo.AppUser WHERE Username='civil-course-demo'),
        @Period date=CONVERT(date,DATEADD(month,-1,DATETRUNC(month,DATEADD(hour,8,SYSUTCDATETIME())))),
        @District nvarchar(80), @AgencyId int, @BatchId int, @OrderId int, @SampleId int;
SELECT @District=District FROM dbo.AppUser WHERE UserId=@Civil;
SELECT @AgencyId=AgencyId FROM dbo.AppUser WHERE UserId=@Agency;
IF @Civil IS NULL OR @Street IS NULL OR @Agency IS NULL OR @OutsideCivil IS NULL
    THROW 52130, N'请先生成合成样例和演示账号。', 1;

BEGIN TRY
    BEGIN TRANSACTION;
    DECLARE @Device int=(SELECT DeviceId FROM dbo.HealthDevice WHERE DeviceCode='DEMO-HEALTH-1' AND IsDemo=1);
    IF @Device IS NULL THROW 52131, N'缺少可用于定时上报的合成设备。', 1;
    DECLARE @Minute int=DATEDIFF(minute,'20000101',SYSUTCDATETIME())+5;
    SET @Minute=@Minute+(5-(@Minute+@Device)%5)%5;
    DECLARE @SimAt datetime2(0)=DATEADD(minute,@Minute,CONVERT(datetime2(0),'20000101'));
    DECLARE @Packet varchar(64)=CONCAT('SIM-',@Device,'-',@Minute), @AlertId int;
    EXEC dbo.usp_SimulateHealthReadings @SimAt;
    EXEC dbo.usp_SimulateHealthReadings @SimAt;
    SELECT @AlertId=alert.AlertId FROM dbo.HealthReading reading JOIN dbo.HealthAlert alert ON alert.ReadingId=reading.ReadingId
    WHERE reading.PacketKey=@Packet AND reading.SourceType='DEVICE' AND alert.State='PENDING';
    IF @AlertId IS NULL OR EXISTS (
        SELECT Username FROM (VALUES ('community'),('family'),('caregiver')) expected(Username)
        EXCEPT
        SELECT account.Username FROM dbo.HealthNotice notice JOIN dbo.AppUser account ON account.UserId=notice.RecipientUserId
        WHERE notice.AlertId=@AlertId AND notice.Kind='TRIAGE'
    ) OR EXISTS (
        SELECT 1 FROM dbo.HealthNotice notice JOIN dbo.AppUser account ON account.UserId=notice.RecipientUserId
        WHERE notice.AlertId=@AlertId AND account.Username='family0019'
    ) THROW 52131, N'待确认告警应通知关联的三方，而非无关家属。', 1;
    IF (SELECT COUNT(*) FROM dbo.HealthReading WHERE PacketKey=@Packet)<>1
        THROW 52131, N'同分钟模拟设备读数重复。', 1;
    DECLARE @UnbindAt datetime2(0)=DATEADD(second,1,@SimAt), @NextAt datetime2(0)=DATEADD(minute,1,@SimAt);
    EXEC dbo.usp_UnbindHealthDevice 'DEMO-HEALTH-1', @At=@UnbindAt;
    EXEC dbo.usp_SimulateHealthReadings @NextAt;
    IF EXISTS (SELECT 1 FROM dbo.HealthReading WHERE PacketKey=CONCAT('SIM-',@Device,'-',@Minute+1))
        THROW 52131, N'解绑后不应继续上报。', 1;

    EXEC dbo.usp_CreateInspectionBatch @Street,@Period,23;
    SELECT @BatchId=BatchId FROM dbo.InspectionBatch WHERE PeriodMonth=@Period AND ReviewDistrict=@District;
    SELECT OrderId INTO #InitialSample FROM dbo.InspectionBatchOrder WHERE BatchId=@BatchId;
    IF NOT EXISTS (
        SELECT 1 FROM dbo.InspectionBatch batch WHERE batch.BatchId=@BatchId
            AND batch.TargetCount=(SELECT COUNT(*) FROM #InitialSample)
            AND batch.TargetCount=CEILING(batch.PopulationCount*23.0/100)
    ) THROW 52132, N'样本数应按比例向上取整。', 1;
    EXEC dbo.usp_CreateInspectionBatch @Civil,@Period,100;
    IF EXISTS (SELECT OrderId FROM dbo.InspectionBatchOrder WHERE BatchId=@BatchId EXCEPT SELECT OrderId FROM #InitialSample)
       OR EXISTS (SELECT OrderId FROM #InitialSample EXCEPT SELECT OrderId FROM dbo.InspectionBatchOrder WHERE BatchId=@BatchId)
        THROW 52132, N'重复生成不应改变原样本。', 1;
    IF EXISTS (SELECT 1 FROM dbo.v_InspectionPublicSummary WHERE ReviewDistrict=@District AND PeriodMonth=@Period)
        THROW 52133, N'未发布批次不能出现在公示中。', 1;

    DECLARE missing_checks CURSOR LOCAL FAST_FORWARD FOR SELECT OrderId FROM dbo.v_InspectionSampleOrder
        WHERE BatchId=@BatchId AND InspectionId IS NULL;
    OPEN missing_checks;
    FETCH NEXT FROM missing_checks INTO @OrderId;
    WHILE @@FETCH_STATUS=0
    BEGIN
        EXEC dbo.usp_RegisterSampleInspection @Street,@BatchId,@OrderId,88,N'核查验证用订单','PHONE';
        FETCH NEXT FROM missing_checks INTO @OrderId;
    END;
    CLOSE missing_checks;
    DEALLOCATE missing_checks;
    EXEC dbo.usp_PublishInspectionBatch @Civil,@BatchId;
    DECLARE @PublishedTotal bigint=(SELECT ScoreTotal FROM dbo.InspectionPublication WHERE BatchId=@BatchId);
    SELECT TOP (1) @SampleId=InspectionId FROM dbo.v_InspectionSampleOrder WHERE BatchId=@BatchId;
    UPDATE dbo.ServiceInspection SET Score=IIF(Score=100,99,100) WHERE InspectionId=@SampleId;
    EXEC dbo.usp_PublishInspectionBatch @Civil,@BatchId;
    IF @PublishedTotal IS NULL OR NOT EXISTS (
        SELECT 1 FROM dbo.v_InspectionPublicSummary
        WHERE ReviewDistrict=@District AND PeriodMonth=@Period AND ScoreTotal=@PublishedTotal
    ) THROW 52133, N'公示必须保留首次发布的快照。', 1;

    EXEC dbo.usp_SubmitAgencyAssessment @Agency,@Period;
    DECLARE @Submission int, @Minutes bigint;
    SELECT @Submission=SubmissionId,@Minutes=EffectiveMinutes FROM dbo.AgencyAssessmentSubmission
    WHERE AgencyId=@AgencyId AND PeriodMonth=@Period;
    SELECT TOP (1) @OrderId=visit.OrderId FROM dbo.ServiceVisit visit JOIN dbo.Worker worker ON worker.WorkerId=visit.WorkerId
    WHERE worker.AgencyId=@AgencyId AND visit.WorkStatus='VALID'
      AND CONVERT(date,DATETRUNC(month,DATEADD(hour,8,visit.CheckOutAt)))=@Period;
    UPDATE dbo.ServiceVisit SET EffectiveMinutes=EffectiveMinutes+5 WHERE OrderId=@OrderId;
    EXEC dbo.usp_SubmitAgencyAssessment @Agency,@Period;
    EXEC dbo.usp_ReviewAgencyAssessment @Civil,@Submission,N'验证审阅意见';
    IF @Submission IS NULL OR NOT EXISTS (
        SELECT 1 FROM dbo.AgencyAssessmentSubmission WHERE SubmissionId=@Submission
        AND EffectiveMinutes=@Minutes AND ReviewedBy=@Civil AND ReviewNote=N'验证审阅意见'
    ) THROW 52134, N'机构材料应冻结一次，审阅意见应单独留存。', 1;

    DECLARE @DispatchId int;
    INSERT dbo.ServiceDispatch(OrderId,WorkerId,ShiftId,OfferedAt,OfferExpiresAt,ClosedAt,CloseReason)
    SELECT TOP (1) dispatch.OrderId,dispatch.WorkerId,dispatch.ShiftId,'20200101','20200101 01:00','20200101 01:05',N'派单超过接单时限'
    FROM dbo.ServiceDispatch dispatch JOIN dbo.Worker worker ON worker.WorkerId=dispatch.WorkerId
    WHERE worker.AgencyId=@AgencyId;
    SET @DispatchId=CONVERT(int,SCOPE_IDENTITY());
    EXEC dbo.usp_FollowUpDispatchTimeout @Agency,@DispatchId,N'已联系本机构护工，待社区调度';
    IF NOT EXISTS (SELECT 1 FROM dbo.ServiceDispatch WHERE DispatchId=@DispatchId AND TimeoutFollowedUpBy=@Agency)
        THROW 52135, N'本机构超时派单应保留跟进说明。', 1;
    ROLLBACK;
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK;
    THROW;
END CATCH;

BEGIN TRY
    DECLARE @PublishedDemo int=(SELECT TOP (1) BatchId FROM dbo.InspectionBatch WHERE ReviewDistrict=N'课设抽查演示区');
    EXEC dbo.usp_PublishInspectionBatch @Civil,@PublishedDemo;
    THROW 52136, N'民政不能发布其他辖区的结果。', 1;
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK;
    IF ERROR_NUMBER()<>52104 THROW;
END CATCH;

BEGIN TRY
    DECLARE @CourseSubmission int=(SELECT TOP (1) SubmissionId FROM dbo.AgencyAssessmentSubmission
                                    WHERE District=N'课设抽查演示区');
    EXEC dbo.usp_ReviewAgencyAssessment @Civil,@CourseSubmission,N'越权验证';
    THROW 52136, N'监管账号不能审阅其他辖区的材料。', 1;
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK;
    IF ERROR_NUMBER()<>52106 THROW;
END CATCH;

PRINT N'PASS 定时上报、三方告警、固定抽样、脱敏发布快照、机构考核及跟进权限。';
GO
