USE [KanglaoCourse];
GO

IF COL_LENGTH(N'dbo.Community', N'CityName') IS NULL
    ALTER TABLE dbo.Community ADD CityName nvarchar(30) NULL;
IF COL_LENGTH(N'dbo.Community', N'AreaName') IS NULL
    ALTER TABLE dbo.Community ADD AreaName nvarchar(80) NULL;
IF COL_LENGTH(N'dbo.Community', N'StreetName') IS NULL
    ALTER TABLE dbo.Community ADD StreetName nvarchar(80) NULL;
IF COL_LENGTH(N'dbo.ArchiveAudit', N'TransferReason') IS NULL
    ALTER TABLE dbo.ArchiveAudit ADD TransferReason nvarchar(250) NULL;
GO

CREATE OR ALTER VIEW dbo.v_ElderTransferHistory AS
SELECT audit.AuditId, audit.ArchiveNo, audit.BeforeCommunityId, previous.Name AS FromCommunityName,
       audit.AfterCommunityId, destination.Name AS ToCommunityName, audit.OccurredAt, audit.TransferReason,
       actor.DisplayName AS OperatorName
FROM dbo.ArchiveAudit audit
JOIN dbo.Community previous ON previous.CommunityId=audit.BeforeCommunityId
JOIN dbo.Community destination ON destination.CommunityId=audit.AfterCommunityId
LEFT JOIN dbo.AppUser actor ON actor.UserId=audit.ActorUserId
WHERE audit.EventType='transferred';
GO

CREATE OR ALTER VIEW dbo.v_ReassessmentQueue AS
SELECT elder.CommunityId, elder.ArchiveNo, elder.FullName, assessment.AbilityLevel,
       assessment.ValidThrough, DATEDIFF(day, calendar.Today, assessment.ValidThrough) AS DaysRemaining,
       CASE WHEN assessment.ValidThrough<calendar.Today THEN 'OVERDUE' ELSE 'DUE_SOON' END AS QueueStatus
FROM dbo.ElderArchive elder
JOIN dbo.v_CurrentAbilityAssessment assessment ON assessment.ArchiveNo=elder.ArchiveNo
CROSS APPLY (VALUES (CONVERT(date,DATEADD(hour,8,SYSUTCDATETIME())))) calendar(Today)
WHERE elder.IsActive=1 AND assessment.ValidThrough<=DATEADD(day,14,calendar.Today);
GO

CREATE OR ALTER PROCEDURE dbo.usp_TransferElderArchive
    @ArchiveNo varchar(20), @ActorId int, @ToCommunityId int,
    @NewAddress nvarchar(200), @Latitude decimal(9,6), @Longitude decimal(9,6), @Reason nvarchar(250)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @NewAddress=NULLIF(TRIM(@NewAddress),N'');
    SET @Reason=NULLIF(TRIM(@Reason),N'');
    IF @NewAddress IS NULL OR @Reason IS NULL OR @Latitude IS NULL OR @Longitude IS NULL
       OR @Latitude NOT BETWEEN -90 AND 90 OR @Longitude NOT BETWEEN -180 AND 180
        THROW 52201, N'请填写新住址、有效坐标和迁移原因。', 1;

    DECLARE @FromCommunityId int, @LastAuditId bigint, @CenterLatitude decimal(9,6),
            @CenterLongitude decimal(9,6), @Radius int;
    BEGIN TRANSACTION;
    SELECT @ArchiveNo=ArchiveNo FROM dbo.ElderArchive WHERE ArchiveNo=@ArchiveNo;
    EXEC dbo.usp_ServiceLock 'archive', @ArchiveNo;
    SELECT @FromCommunityId=elder.CommunityId
    FROM dbo.ElderArchive elder WITH (UPDLOCK,HOLDLOCK)
    JOIN dbo.AppUser actor ON actor.UserId=@ActorId AND actor.Role='community'
        AND actor.Active=1 AND actor.CommunityId=elder.CommunityId
    WHERE elder.ArchiveNo=@ArchiveNo AND elder.IsActive=1;
    IF @FromCommunityId IS NULL OR @ToCommunityId IS NULL OR @FromCommunityId=@ToCommunityId
        THROW 52202, N'只能迁移本社区在册档案，且迁入社区必须不同。', 1;
    SELECT @CenterLatitude=Latitude, @CenterLongitude=Longitude, @Radius=RadiusMeters
    FROM dbo.Community WHERE CommunityId=@ToCommunityId;
    IF @Radius IS NULL
        THROW 52203, N'迁入社区不存在或未配置服务范围。', 1;
    IF geography::Point(@Latitude,@Longitude,4326).STDistance(geography::Point(@CenterLatitude,@CenterLongitude,4326))>@Radius
        THROW 52203, N'新住址坐标未落在迁入社区的模拟服务范围。', 1;

    SELECT @LastAuditId=ISNULL(MAX(AuditId),0) FROM dbo.ArchiveAudit WHERE ArchiveNo=@ArchiveNo;
    UPDATE dbo.ElderArchive SET CommunityId=@ToCommunityId, Address=@NewAddress, Latitude=@Latitude, Longitude=@Longitude
    WHERE ArchiveNo=@ArchiveNo;
    UPDATE dbo.ArchiveAudit SET ActorUserId=@ActorId, TransferReason=@Reason
    WHERE ArchiveNo=@ArchiveNo AND EventType='transferred' AND AuditId>@LastAuditId;
    IF @@ROWCOUNT<>1 THROW 52204, N'迁移历史未完整保存。', 1;

    UPDATE dbo.CarePlan SET Status='PAUSED', ChangedReason=N'档案迁移，待新社区复核'
    WHERE ArchiveNo=@ArchiveNo AND Status='ACTIVE';

    DECLARE @Cancelled TABLE (OrderId int PRIMARY KEY);
    UPDATE orders SET Status='CANCELLED', ReviewReason=N'老人已迁居，请在新社区重新预约'
    OUTPUT inserted.OrderId INTO @Cancelled
    FROM dbo.ServiceOrder orders
    WHERE orders.ArchiveNo=@ArchiveNo AND orders.CommunityId=@FromCommunityId
      AND orders.Status IN ('NEW','POOL','OFFERED','ACCEPTED','REVIEW','RESCHEDULE')
      AND NOT EXISTS (SELECT 1 FROM dbo.ServiceVisit visit WHERE visit.OrderId=orders.OrderId);

    DECLARE @Now datetime2(0)=SYSUTCDATETIME();
    UPDATE dispatch SET ClosedAt=IIF(dispatch.OfferedAt>@Now,dispatch.OfferedAt,@Now),
        CloseReason=N'老人已迁居，请在新社区重新预约'
    FROM dbo.ServiceDispatch dispatch JOIN @Cancelled cancelled ON cancelled.OrderId=dispatch.OrderId
    WHERE dispatch.ClosedAt IS NULL;
    COMMIT;
END;
GO
