USE [KanglaoCourse];
GO

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET ARITHABORT ON;
SET NUMERIC_ROUNDABORT OFF;

IF DB_NAME() <> N'KanglaoCourse' OR @@TRANCOUNT <> 0
    THROW 51720, N'请在项目数据库的独立会话中执行健康验证。', 1;

DECLARE @FirstArchive varchar(20) = 'E0001', @SecondArchive varchar(20) = 'E0002';
DECLARE @DutyUser int;
SELECT @DutyUser = MIN(account.UserId)
FROM dbo.ElderArchive AS elder
JOIN dbo.AppUser AS account ON account.CommunityId = elder.CommunityId AND account.Role = 'community' AND account.Active = 1
WHERE elder.ArchiveNo = @SecondArchive;
IF @DutyUser IS NULL THROW 51720, N'请先生成演示档案和社区账号。', 1;

DECLARE @Base datetime2(0) = DATEADD(day, -2, SYSUTCDATETIME());
DECLARE @FirstReadingAt datetime2(0) = DATEADD(minute, 5, @Base);
DECLARE @RebindAt datetime2(0) = DATEADD(minute, 10, @Base);
DECLARE @OpenAt datetime2(0) = DATEADD(minute, 20, @Base);
DECLARE @ReviewAt datetime2(0) = DATEADD(minute, 1, @OpenAt);
DECLARE @DueAt datetime2(0) = DATEADD(minute, 2, @OpenAt);
DECLARE @ArriveAt datetime2(0) = DATEADD(minute, 1, @ReviewAt);
DECLARE @CloseAt datetime2(0) = DATEADD(minute, 1, @ArriveAt);
DECLARE @EscalateAt datetime2(0) = DATEADD(minute, 180, @OpenAt);
DECLARE @Device varchar(24) = 'VERIFY-HEALTH-DEVICE';
DECLARE @Metric varchar(24) = 'VERIFY-HEALTH-METRIC';
DECLARE @FalseAlert int, @ConfirmedAlert int, @DueAlert int, @ConfirmedEvent int, @DueEvent int, @SosEvent int;

BEGIN TRY
    BEGIN TRANSACTION;

    INSERT dbo.HealthDevice (DeviceCode, DeviceType) VALUES (@Device, 'VITALS');
    INSERT dbo.HealthThreshold (MetricCode, MetricName, UnitLabel, MinimumValue, MaximumValue, TriageMinutes, Severity)
    VALUES (@Metric, N'验证指标', N'模拟单位', 0, 100, 2, 2);

    EXEC dbo.usp_BindHealthDevice @Device, @FirstArchive, @At = @Base;
    EXEC dbo.usp_RecordHealthReading @Device, 'VERIFY-HEALTH-OLD', @Metric, 100, @FirstReadingAt, @Now = @FirstReadingAt;
    EXEC dbo.usp_UnbindHealthDevice @Device, @At = @RebindAt;
    EXEC dbo.usp_BindHealthDevice @Device, @SecondArchive, @At = @RebindAt;
    EXEC dbo.usp_RecordHealthReading @Device, 'VERIFY-HEALTH-OLD', @Metric, 100, @FirstReadingAt, @Now = @RebindAt;

    IF NOT EXISTS (SELECT 1 FROM dbo.v_HealthReadingHistory
         WHERE PacketKey = 'VERIFY-HEALTH-OLD' AND ArchiveNo = @FirstArchive AND IsAbnormal = 0)
        OR (SELECT COUNT(*) FROM dbo.HealthReading WHERE PacketKey = 'VERIFY-HEALTH-OLD') <> 1
        THROW 51721, N'历史归属、阈值边界或读数重试验证失败。', 1;

    EXEC dbo.usp_RecordHealthReading @Device, 'VERIFY-HEALTH-FALSE', @Metric, 101, @RebindAt, @Now = @OpenAt;
    EXEC dbo.usp_RecordHealthReading @Device, 'VERIFY-HEALTH-CONFIRMED', @Metric, 110, @OpenAt, @Now = @OpenAt;
    EXEC dbo.usp_RecordHealthReading @Device, 'VERIFY-HEALTH-TIMEOUT', @Metric, 120, @OpenAt, @Now = @OpenAt;

    SELECT @FalseAlert = a.AlertId FROM dbo.v_HealthAlertQueue AS a
    JOIN dbo.HealthReading AS r ON r.ReadingId = a.ReadingId WHERE r.PacketKey = 'VERIFY-HEALTH-FALSE';
    SELECT @ConfirmedAlert = a.AlertId FROM dbo.v_HealthAlertQueue AS a
    JOIN dbo.HealthReading AS r ON r.ReadingId = a.ReadingId WHERE r.PacketKey = 'VERIFY-HEALTH-CONFIRMED';
    SELECT @DueAlert = a.AlertId FROM dbo.v_HealthAlertQueue AS a
    JOIN dbo.HealthReading AS r ON r.ReadingId = a.ReadingId WHERE r.PacketKey = 'VERIFY-HEALTH-TIMEOUT';

    IF NOT EXISTS (SELECT 1 FROM dbo.v_HealthAlertQueue
         WHERE AlertId = @FalseAlert AND ArchiveNo = @SecondArchive AND State = 'PENDING' AND EventId IS NULL)
        OR NOT EXISTS (SELECT 1 FROM dbo.HealthNotice WHERE AlertId = @FalseAlert AND RecipientUserId = @DutyUser AND Kind = 'TRIAGE')
        THROW 51722, N'普通告警应先进入当前绑定老人的待确认队列并提醒值班员。', 1;

    EXEC dbo.usp_ReviewHealthAlert @FalseAlert, @DutyUser, 'FALSE_ALARM', @ReviewAt;
    EXEC dbo.usp_ReviewHealthAlert @ConfirmedAlert, @DutyUser, 'CONFIRMED', @ReviewAt;
    IF NOT EXISTS (SELECT 1 FROM dbo.v_HealthAlertQueue WHERE AlertId = @FalseAlert AND State = 'FALSE_ALARM' AND EventId IS NULL)
        THROW 51723, N'误报关闭后产生了应急事件，或状态未写入。', 1;

    SELECT @ConfirmedEvent = EventId FROM dbo.HealthEvent WHERE AlertId = @ConfirmedAlert AND Origin = 'REVIEW';
    IF @ConfirmedEvent IS NULL THROW 51724, N'人工确认未立即建立应急事件。', 1;

    EXEC dbo.usp_ProcessHealthTimeouts @DueAt;
    EXEC dbo.usp_ProcessHealthTimeouts @DueAt;
    SELECT @DueEvent = EventId FROM dbo.HealthEvent WHERE AlertId = @DueAlert AND Origin = 'TRIAGE_TIMEOUT';
    IF @DueEvent IS NULL OR (SELECT COUNT(*) FROM dbo.HealthEvent WHERE AlertId = @DueAlert) <> 1
        THROW 51725, N'超时应急事件未创建或被重复创建。', 1;

    EXEC dbo.usp_OpenHealthEvent @SecondArchive, 'VERIFY-HEALTH-SOS', 'SOS', @DutyUser, @OpenAt;
    EXEC dbo.usp_OpenHealthEvent @SecondArchive, 'VERIFY-HEALTH-SOS', 'SOS', @DutyUser, @OpenAt;
    SELECT @SosEvent = EventId FROM dbo.HealthEvent WHERE RequestKey = 'VERIFY-HEALTH-SOS' AND SourceType = 'SOS' AND AlertId IS NULL;
    IF @SosEvent IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.HealthNotice WHERE EventId = @SosEvent AND RecipientUserId = @DutyUser AND Kind = 'EVENT')
        THROW 51726, N'一键呼救未直接生成应急事件和通知。', 1;

    EXEC dbo.usp_UpdateHealthEvent @ConfirmedEvent, @DutyUser, 'RESPOND', @Now = @ReviewAt;
    EXEC dbo.usp_UpdateHealthEvent @ConfirmedEvent, @DutyUser, 'ARRIVE', @Now = @ArriveAt;
    EXEC dbo.usp_UpdateHealthEvent @ConfirmedEvent, @DutyUser, 'CLOSE', N'验证处置已完成', @CloseAt;
    EXEC dbo.usp_ProcessHealthTimeouts @EscalateAt;
    EXEC dbo.usp_ProcessHealthTimeouts @EscalateAt;

    IF NOT EXISTS (SELECT 1 FROM dbo.v_HealthEventOverview WHERE EventId = @ConfirmedEvent AND State = 'CLOSED'
         AND RespondedBy = @DutyUser AND ArrivedAt = @ArriveAt AND ClosedAt = @CloseAt AND EscalatedAt IS NULL)
        OR (SELECT COUNT(*) FROM dbo.HealthEventAudit WHERE EventId = @ConfirmedEvent) <> 4
        THROW 51727, N'已响应事件的到场、处置和审计记录不正确。', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.v_HealthEventOverview WHERE EventId = @DueEvent AND State = 'ESCALATED')
        OR (SELECT COUNT(*) FROM dbo.HealthEventAudit WHERE EventId = @DueEvent AND ActionCode = 'ESCALATED') <> 1
        THROW 51728, N'未及时响应的事件应只升级一次。', 1;

    -- 预期约束错误会使验证事务不可提交，因此放在最后。
    BEGIN TRY
        EXEC dbo.usp_BindHealthDevice @Device, @FirstArchive, @At = @OpenAt;
        THROW 51729, N'重叠绑定未被拒绝。', 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() <> 51703 THROW;
    END CATCH;

    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;

IF EXISTS (SELECT 1 FROM dbo.HealthDevice WHERE DeviceCode = @Device)
    THROW 51730, N'健康验证样例未回滚。', 1;
PRINT N'健康验证通过。';
