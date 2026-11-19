USE [KanglaoCourse];
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
SET XACT_ABORT ON;
BEGIN TRANSACTION;

IF OBJECT_ID(N'dbo.InspectionBatch', N'U') IS NULL
    CREATE TABLE dbo.InspectionBatch (
        BatchId int IDENTITY PRIMARY KEY,
        ReviewDistrict nvarchar(80) NOT NULL,
        PeriodMonth date NOT NULL CHECK (DAY(PeriodMonth)=1),
        SampleRate tinyint NOT NULL CHECK (SampleRate BETWEEN 1 AND 100),
        PopulationCount int NOT NULL,
        TargetCount int NOT NULL,
        CreatedBy int NOT NULL REFERENCES dbo.AppUser(UserId),
        CreatedAt datetime2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT UQ_InspectionBatch_Period UNIQUE (ReviewDistrict,PeriodMonth),
        CONSTRAINT CK_InspectionBatch_Counts CHECK (TargetCount>0 AND TargetCount<=PopulationCount)
    );

IF OBJECT_ID(N'dbo.InspectionBatchOrder', N'U') IS NULL
    CREATE TABLE dbo.InspectionBatchOrder (
        BatchId int NOT NULL REFERENCES dbo.InspectionBatch(BatchId),
        OrderId int NOT NULL REFERENCES dbo.ServiceOrder(OrderId),
        PRIMARY KEY (BatchId,OrderId)
    );

IF OBJECT_ID(N'dbo.InspectionPublication', N'U') IS NULL
    CREATE TABLE dbo.InspectionPublication (
        BatchId int PRIMARY KEY REFERENCES dbo.InspectionBatch(BatchId),
        InspectionCount bigint NOT NULL CHECK (InspectionCount>0),
        ScoreTotal bigint NOT NULL,
        RequiredCount bigint NOT NULL,
        ClosedCount bigint NOT NULL,
        PublishedBy int NOT NULL REFERENCES dbo.AppUser(UserId),
        PublishedAt datetime2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT CK_InspectionPublication_Counts CHECK (
            ClosedCount>=0 AND RequiredCount>=ClosedCount AND InspectionCount>=RequiredCount
            AND ScoreTotal BETWEEN 0 AND 100*InspectionCount
        )
    );

IF OBJECT_ID(N'dbo.AgencyAssessmentSubmission', N'U') IS NULL
    CREATE TABLE dbo.AgencyAssessmentSubmission (
        SubmissionId int IDENTITY PRIMARY KEY,
        AgencyId int NOT NULL REFERENCES dbo.Agency(AgencyId),
        District nvarchar(80) NOT NULL,
        PeriodMonth date NOT NULL CHECK (DAY(PeriodMonth)=1),
        InspectionCount bigint NOT NULL,
        ScoreTotal bigint NOT NULL,
        RequiredCount bigint NOT NULL,
        ClosedCount bigint NOT NULL,
        ComplaintCount bigint NOT NULL CHECK (ComplaintCount>=0),
        EffectiveMinutes bigint NOT NULL CHECK (EffectiveMinutes>=0),
        SubmittedBy int NOT NULL REFERENCES dbo.AppUser(UserId),
        SubmittedAt datetime2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
        ReviewedBy int NULL REFERENCES dbo.AppUser(UserId),
        ReviewedAt datetime2(0) NULL,
        ReviewNote nvarchar(250) NULL,
        CONSTRAINT UQ_AgencyAssessment_Period UNIQUE (AgencyId,PeriodMonth),
        CONSTRAINT CK_AgencyAssessment_Counts CHECK (
            ClosedCount>=0 AND RequiredCount>=ClosedCount AND InspectionCount>=RequiredCount
            AND ScoreTotal BETWEEN 0 AND 100*InspectionCount
        ),
        CONSTRAINT CK_AgencyAssessment_Review CHECK (
            (ReviewedBy IS NULL AND ReviewedAt IS NULL AND ReviewNote IS NULL)
            OR (ReviewedBy IS NOT NULL AND ReviewedAt IS NOT NULL AND ReviewNote IS NOT NULL
                AND LEN(ReviewNote)>0 AND ReviewedAt>=SubmittedAt)
        )
    );

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'dbo.ServiceInspection')
               AND name=N'IX_ServiceInspection_SampledOrder')
    CREATE INDEX IX_ServiceInspection_SampledOrder ON dbo.ServiceInspection(ReviewDistrict,OrderId,InspectionId);
COMMIT;
GO

CREATE OR ALTER VIEW dbo.v_InspectionSampleOrder AS
SELECT batch.BatchId, batch.ReviewDistrict, batch.PeriodMonth, item.OrderId, orders.OrderNo,
       service.Name AS ServiceName, inspected.InspectionId, inspected.Score, inspected.RestrictionId, inspected.Status
FROM dbo.InspectionBatch batch
JOIN dbo.InspectionBatchOrder item ON item.BatchId=batch.BatchId
JOIN dbo.ServiceOrder orders ON orders.OrderId=item.OrderId
JOIN dbo.ServiceType service ON service.ServiceTypeId=orders.ServiceTypeId
OUTER APPLY (
    SELECT TOP (1) inspection.InspectionId,inspection.Score,inspection.RestrictionId,inspection.Status
    FROM dbo.ServiceInspection inspection
    WHERE inspection.ReviewDistrict=batch.ReviewDistrict AND inspection.OrderId=item.OrderId
    ORDER BY inspection.InspectionId
) inspected;
GO

CREATE OR ALTER VIEW dbo.v_InspectionPublicSummary AS
SELECT batch.ReviewDistrict, batch.PeriodMonth, published.InspectionCount, published.ScoreTotal,
       published.RequiredCount, published.ClosedCount, published.PublishedAt
FROM dbo.InspectionPublication published JOIN dbo.InspectionBatch batch ON batch.BatchId=published.BatchId;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CreateInspectionBatch @ActorId int, @PeriodMonth date, @SampleRate int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @District nvarchar(80)=(SELECT District FROM dbo.AppUser
        WHERE UserId=@ActorId AND Active=1 AND Role IN ('street','civil'));
    IF @District IS NULL
        THROW 52101, N'仅监管账号可对本辖区生成抽查批次。', 1;
    IF @PeriodMonth IS NULL OR @PeriodMonth<'20000101' OR DAY(@PeriodMonth)<>1
       OR @PeriodMonth>=DATETRUNC(month,DATEADD(hour,8,SYSUTCDATETIME()))
       OR @SampleRate IS NULL OR @SampleRate NOT BETWEEN 1 AND 100
        THROW 52102, N'请选择已结束的月份和 1 至 100 的抽样比例。', 1;

    BEGIN TRANSACTION;
    IF EXISTS (SELECT 1 FROM dbo.InspectionBatch WITH (UPDLOCK,HOLDLOCK)
               WHERE ReviewDistrict=@District AND PeriodMonth=@PeriodMonth)
    BEGIN
        COMMIT;
        RETURN;
    END;

    DECLARE @Start datetime2(0)=DATEADD(hour,-8,CONVERT(datetime2(0),@PeriodMonth));
    DECLARE @End datetime2(0)=DATEADD(month,1,CONVERT(datetime2(0),@PeriodMonth));
    SET @End=DATEADD(hour,-8,@End);
    DECLARE @Candidates table (OrderId int PRIMARY KEY);
    INSERT @Candidates(OrderId)
    SELECT orders.OrderId FROM dbo.ServiceOrder orders
    JOIN dbo.Community community ON community.CommunityId=orders.CommunityId
    JOIN dbo.ServiceVisit visit ON visit.OrderId=orders.OrderId
    WHERE community.District=@District AND orders.Status='COMPLETED'
      AND visit.CheckOutAt>=@Start AND visit.CheckOutAt<@End;

    DECLARE @Population int=(SELECT COUNT(*) FROM @Candidates), @Target int, @BatchId int;
    IF @Population=0 THROW 52102, N'辖区该月没有已完成的订单。', 1;
    SET @Target=CONVERT(int,(CONVERT(bigint,@Population)*@SampleRate+99)/100);
    INSERT dbo.InspectionBatch(ReviewDistrict,PeriodMonth,SampleRate,PopulationCount,TargetCount,CreatedBy)
    VALUES (@District,@PeriodMonth,@SampleRate,@Population,@Target,@ActorId);
    SET @BatchId=CONVERT(int,SCOPE_IDENTITY());
    INSERT dbo.InspectionBatchOrder(BatchId,OrderId)
    SELECT TOP (@Target) @BatchId,OrderId FROM @Candidates ORDER BY NEWID();
    COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RegisterSampleInspection
    @ActorId int, @BatchId int, @OrderId int, @Score int, @Finding nvarchar(250),
    @InspectionMethod varchar(10), @IssueTag nvarchar(60)=NULL, @CorrectionRequirement nvarchar(250)=NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;
    DECLARE @District nvarchar(80);
    SELECT @District=batch.ReviewDistrict FROM dbo.InspectionBatch batch WITH (UPDLOCK,HOLDLOCK)
    JOIN dbo.AppUser actor ON actor.District=batch.ReviewDistrict AND actor.UserId=@ActorId
        AND actor.Active=1 AND actor.Role IN ('street','civil')
    JOIN dbo.InspectionBatchOrder item ON item.BatchId=batch.BatchId AND item.OrderId=@OrderId
    WHERE batch.BatchId=@BatchId;
    IF @District IS NULL
        THROW 52103, N'该订单不在本辖区抽样批次内。', 1;
    IF EXISTS (SELECT 1 FROM dbo.ServiceInspection WITH (UPDLOCK,HOLDLOCK)
               WHERE ReviewDistrict=@District AND OrderId=@OrderId)
        THROW 52103, N'该订单已有检查记录。', 1;
    EXEC dbo.usp_RegisterInspection @ActorId,'order',@OrderId,@Score,@Finding,
        @InspectionMethod,@IssueTag,@CorrectionRequirement;
    COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_PublishInspectionBatch @ActorId int, @BatchId int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Target int;
    BEGIN TRANSACTION;
    SELECT @Target=batch.TargetCount FROM dbo.InspectionBatch batch WITH (UPDLOCK,HOLDLOCK)
    JOIN dbo.AppUser actor ON actor.District=batch.ReviewDistrict AND actor.UserId=@ActorId
        AND actor.Active=1 AND actor.Role='civil'
    WHERE batch.BatchId=@BatchId;
    IF @Target IS NULL THROW 52104, N'仅本辖区民政账号可以公示该批次。', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.InspectionPublication WHERE BatchId=@BatchId)
    BEGIN
        DECLARE @Inspections bigint, @ScoreTotal bigint, @Required bigint, @Closed bigint;
        SELECT @Inspections=COUNT_BIG(*), @ScoreTotal=SUM(CONVERT(bigint,Score)),
               @Required=SUM(CONVERT(bigint,IIF(RestrictionId IS NULL,0,1))),
               @Closed=SUM(CONVERT(bigint,IIF(RestrictionId IS NOT NULL AND Status='CLOSED',1,0)))
        FROM dbo.v_InspectionSampleOrder WHERE BatchId=@BatchId AND InspectionId IS NOT NULL;
        IF @Inspections<>@Target THROW 52104, N'全部样本完成检查后才能公示。', 1;
        INSERT dbo.InspectionPublication(BatchId,InspectionCount,ScoreTotal,RequiredCount,ClosedCount,PublishedBy)
        VALUES (@BatchId,@Inspections,@ScoreTotal,@Required,@Closed,@ActorId);
    END;
    COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_SubmitAgencyAssessment @ActorId int, @PeriodMonth date
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @AgencyId int, @District nvarchar(80);
    SELECT @AgencyId=agency.AgencyId,@District=agency.District FROM dbo.AppUser actor
    JOIN dbo.Agency agency ON agency.AgencyId=actor.AgencyId
    WHERE actor.UserId=@ActorId AND actor.Active=1 AND actor.Role='agency';
    IF @AgencyId IS NULL THROW 52105, N'仅机构账号可提交本机构考核。', 1;
    IF @PeriodMonth IS NULL OR @PeriodMonth<'20000101' OR DAY(@PeriodMonth)<>1
       OR @PeriodMonth>=DATETRUNC(month,DATEADD(hour,8,SYSUTCDATETIME()))
        THROW 52105, N'请选择已结束的月份。', 1;

    BEGIN TRANSACTION;
    IF EXISTS (SELECT 1 FROM dbo.AgencyAssessmentSubmission WITH (UPDLOCK,HOLDLOCK)
               WHERE AgencyId=@AgencyId AND PeriodMonth=@PeriodMonth)
    BEGIN
        COMMIT;
        RETURN;
    END;
    DECLARE @Month char(7)=CONVERT(char(7),@PeriodMonth,126);
    DECLARE @Start datetime2(0)=DATEADD(hour,-8,CONVERT(datetime2(0),@PeriodMonth));
    DECLARE @End datetime2(0)=DATEADD(hour,-8,CONVERT(datetime2(0),DATEADD(month,1,@PeriodMonth)));
    DECLARE @Inspections bigint, @ScoreTotal bigint, @Required bigint, @Closed bigint, @Complaints bigint, @Minutes bigint;
    SELECT @Inspections=COALESCE(SUM(InspectionCount),0), @ScoreTotal=COALESCE(SUM(ScoreTotal),0),
           @Required=COALESCE(SUM(RequiredCount),0), @Closed=COALESCE(SUM(ClosedCount),0)
    FROM dbo.v_MonthlyInspectionResults WHERE AgencyId=@AgencyId AND InspectionMonth=@Month;
    SELECT @Minutes=COALESCE(SUM(EffectiveMinutes),0) FROM dbo.v_WorkerMonthlyHours
    WHERE AgencyId=@AgencyId AND WorkMonth=@Month;
    SELECT @Complaints=COUNT_BIG(*) FROM dbo.ServiceVisit visit JOIN dbo.Worker worker ON worker.WorkerId=visit.WorkerId
    WHERE worker.AgencyId=@AgencyId AND visit.ComplainedAt>=@Start AND visit.ComplainedAt<@End;
    INSERT dbo.AgencyAssessmentSubmission (
        AgencyId,District,PeriodMonth,InspectionCount,ScoreTotal,RequiredCount,ClosedCount,ComplaintCount,EffectiveMinutes,SubmittedBy
    ) VALUES (@AgencyId,@District,@PeriodMonth,@Inspections,@ScoreTotal,@Required,@Closed,@Complaints,@Minutes,@ActorId);
    COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ReviewAgencyAssessment @ActorId int, @SubmissionId int, @Note nvarchar(250)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NULLIF(TRIM(@Note),N'') IS NULL THROW 52106, N'请填写考核意见。', 1;
    UPDATE submission SET ReviewedBy=@ActorId, ReviewedAt=SYSUTCDATETIME(), ReviewNote=TRIM(@Note)
    FROM dbo.AgencyAssessmentSubmission submission JOIN dbo.AppUser actor ON actor.District=submission.District
        AND actor.UserId=@ActorId AND actor.Active=1 AND actor.Role IN ('street','civil')
    WHERE submission.SubmissionId=@SubmissionId AND submission.ReviewedAt IS NULL;
    IF @@ROWCOUNT<>1 THROW 52106, N'材料不在本辖区或已有考核意见。', 1;
END;
GO
