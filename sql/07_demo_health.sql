USE [KanglaoCourse];
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET ARITHABORT ON;
SET NUMERIC_ROUNDABORT OFF;
GO

CREATE OR ALTER PROCEDURE dbo.usp_SeedHealth
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now datetime2(0) = SYSUTCDATETIME();
    DECLARE @Elders TABLE (RowNo int PRIMARY KEY, ArchiveNo varchar(20), CommunityId int, CommunityUserId int);
    INSERT @Elders (RowNo, ArchiveNo, CommunityId, CommunityUserId)
    SELECT ROW_NUMBER() OVER (ORDER BY elder.ArchiveNo), elder.ArchiveNo, elder.CommunityId, MIN(account.UserId)
    FROM dbo.ElderArchive AS elder
    JOIN dbo.AppUser AS account ON account.Role = 'community' AND account.CommunityId = elder.CommunityId AND account.Active = 1
    WHERE elder.IsActive = 1 AND LEFT(elder.IdNumber, 6) = '000000'
    GROUP BY elder.ArchiveNo, elder.CommunityId;

    DECLARE @ElderCount int = (SELECT COUNT(*) FROM @Elders);
    IF @ElderCount = 0 THROW 51710, N'请先创建有社区值班账号的模拟老人档案。', 1;

    DECLARE @Demo TABLE (
        RowNo int PRIMARY KEY, DeviceCode varchar(24), MetricCode varchar(24),
        PacketKey varchar(64), RequestKey varchar(64), ArchiveNo varchar(20), CommunityUserId int
    );
    WITH numbers AS (
        SELECT n FROM (VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12),
                              (13),(14),(15),(16),(17),(18),(19),(20),(21),(22),(23),(24)) AS value_list(n)
    )
    INSERT @Demo (RowNo, DeviceCode, MetricCode, PacketKey, RequestKey, ArchiveNo, CommunityUserId)
    SELECT n, CONCAT('DEMO-HEALTH-', n), CONCAT('DEMO-METRIC-', n), CONCAT('DEMO-PACKET-', n),
           CONCAT('DEMO-HEALTH-EVENT-', n), elder.ArchiveNo, elder.CommunityUserId
    FROM numbers
    JOIN @Elders AS elder ON elder.RowNo = (numbers.n - 1) % @ElderCount + 1;

    BEGIN TRANSACTION;

    DECLARE @SignalNames table (MetricCode varchar(24) PRIMARY KEY, MetricName nvarchar(60), LegacyName nvarchar(60));
    INSERT @SignalNames
    SELECT demo.MetricCode, CHOOSE((demo.RowNo-1)%6+1,N'脉搏监测',N'体温监测',N'血压监测',N'血氧监测',N'呼吸监测',N'活动监测'),
           CASE demo.RowNo WHEN 1 THEN N'心率演示' WHEN 2 THEN N'体温演示'
           WHEN 3 THEN N'血压演示' WHEN 4 THEN N'血氧演示' ELSE CONCAT(N'模拟指标 ', demo.RowNo) END
    FROM @Demo AS demo;
    INSERT @SignalNames VALUES ('DEMO-SYSTOLIC',N'收缩压监测',N'血压演示'),
                               ('DEMO-ECG-RATE',N'心电贴心率',N'心电演示'), ('DEMO-FALL',N'跌倒雷达信号',N'跌倒事件演示');

    INSERT dbo.HealthThreshold (MetricCode, MetricName, UnitLabel, MinimumValue, MaximumValue, TriageMinutes, Severity)
    SELECT demo.MetricCode, signal.MetricName, N'模拟单位', 0, 100, 5, (demo.RowNo - 1) % 3 + 1
    FROM @Demo AS demo JOIN @SignalNames signal ON signal.MetricCode=demo.MetricCode
    WHERE NOT EXISTS (SELECT 1 FROM dbo.HealthThreshold AS t WHERE t.MetricCode=demo.MetricCode);

    INSERT dbo.HealthThreshold (MetricCode, MetricName, UnitLabel, MinimumValue, MaximumValue, TriageMinutes, Severity)
    SELECT metric.Code, signal.MetricName, N'模拟单位', 0, metric.NormalMax, 5, metric.Severity
    FROM (VALUES ('DEMO-SYSTOLIC',100,1), ('DEMO-ECG-RATE',100,2), ('DEMO-FALL',0,3)) metric(Code,NormalMax,Severity)
    JOIN @SignalNames signal ON signal.MetricCode=metric.Code
    WHERE NOT EXISTS (SELECT 1 FROM dbo.HealthThreshold threshold WHERE threshold.MetricCode=metric.Code);

    UPDATE threshold SET MetricName=signal.MetricName
    FROM dbo.HealthThreshold threshold JOIN @SignalNames signal ON signal.MetricCode=threshold.MetricCode
    WHERE threshold.MetricName=signal.LegacyName AND threshold.UnitLabel=N'模拟单位'
      AND threshold.MetricName<>signal.MetricName;

    INSERT dbo.HealthResponseRule (CommunityId, Severity, ResponseMinutes)
    SELECT c.CommunityId, levels.Severity, levels.ResponseMinutes
    FROM (SELECT DISTINCT CommunityId FROM @Elders) AS c
    CROSS JOIN (VALUES (1, 30), (2, 15), (3, 5)) AS levels(Severity, ResponseMinutes)
    WHERE NOT EXISTS (SELECT 1 FROM dbo.HealthResponseRule AS r
                      WHERE r.CommunityId = c.CommunityId AND r.Severity = levels.Severity);

    INSERT dbo.HealthDevice (DeviceCode, DeviceType, IsDemo)
    SELECT demo.DeviceCode, CASE demo.RowNo%4 WHEN 0 THEN 'FALL_RADAR' WHEN 2 THEN 'ECG_PATCH'
           WHEN 3 THEN 'BP_MONITOR' ELSE 'VITALS' END, 1 FROM @Demo AS demo
    WHERE NOT EXISTS (SELECT 1 FROM dbo.HealthDevice AS d WHERE d.DeviceCode = demo.DeviceCode);

    INSERT dbo.HealthBinding (DeviceId, ArchiveNo, StartsAt, InstallationLocation)
    SELECT device.DeviceId, demo.ArchiveNo, DATEADD(day, -30, @Now),
           CHOOSE((demo.RowNo-1)%3+1,N'客厅电视柜旁',N'卧室床头',N'入户走廊')
    FROM @Demo AS demo JOIN dbo.HealthDevice AS device ON device.DeviceCode = demo.DeviceCode
    WHERE NOT EXISTS (SELECT 1 FROM dbo.HealthBinding AS b WHERE b.DeviceId = device.DeviceId);

    INSERT dbo.HealthDevice(DeviceCode,DeviceType,IsDemo)
    SELECT model.DeviceCode,model.DeviceType,1
    FROM (VALUES ('DEMO-MODEL-BP','BP_MONITOR'),('DEMO-MODEL-ECG','ECG_PATCH'),
                 ('DEMO-MODEL-FALL','FALL_RADAR'),('DEMO-MODEL-SOS','SOS')) model(DeviceCode,DeviceType)
    WHERE NOT EXISTS (SELECT 1 FROM dbo.HealthDevice device WHERE device.DeviceCode=model.DeviceCode);
    INSERT dbo.HealthBinding(DeviceId,ArchiveNo,StartsAt,InstallationLocation)
    SELECT device.DeviceId,elder.ArchiveNo,DATEADD(day,-30,@Now),
           CASE device.DeviceType WHEN 'SOS' THEN N'卧室床头' WHEN 'FALL_RADAR' THEN N'入户走廊' ELSE N'客厅电视柜旁' END
    FROM dbo.HealthDevice device CROSS JOIN @Elders elder
    WHERE elder.RowNo=1 AND device.IsDemo=1
      AND device.DeviceCode IN ('DEMO-MODEL-BP','DEMO-MODEL-ECG','DEMO-MODEL-FALL','DEMO-MODEL-SOS')
      AND NOT EXISTS (SELECT 1 FROM dbo.HealthBinding binding WHERE binding.DeviceId=device.DeviceId);

    UPDATE binding SET InstallationLocation=CHOOSE((demo.RowNo-1)%3+1,N'客厅电视柜旁',N'卧室床头',N'入户走廊')
    FROM dbo.HealthBinding binding JOIN dbo.HealthDevice device ON device.DeviceId=binding.DeviceId
    JOIN @Demo demo ON demo.DeviceCode=device.DeviceCode AND demo.ArchiveNo=binding.ArchiveNo
    WHERE binding.InstallationLocation=N'演示居所' AND device.IsDemo=1;

    UPDATE device SET IsDemo=1
    FROM dbo.HealthDevice device JOIN @Demo demo ON demo.DeviceCode=device.DeviceCode
    WHERE device.IsDemo=0 AND EXISTS (
        SELECT 1 FROM dbo.HealthBinding binding JOIN dbo.ElderArchive elder ON elder.ArchiveNo=binding.ArchiveNo
        WHERE binding.DeviceId=device.DeviceId AND binding.EndsAt IS NULL
          AND elder.ArchiveNo=demo.ArchiveNo AND LEFT(elder.IdNumber,6)='000000'
    );

    INSERT dbo.HealthReading (BindingId, PacketKey, MetricCode, MeasuredValue, CapturedAt, ReceivedAt, SourceType, IsAbnormal)
    SELECT binding.BindingId, packet.PacketKey, demo.MetricCode, packet.MeasuredValue, binding.StartsAt, @Now, 'DEVICE', packet.IsAbnormal
    FROM @Demo AS demo
    JOIN dbo.HealthDevice AS device ON device.DeviceCode = demo.DeviceCode
    CROSS APPLY (SELECT TOP (1) b.BindingId, b.StartsAt FROM dbo.HealthBinding AS b
                 WHERE b.DeviceId = device.DeviceId ORDER BY b.StartsAt) AS binding
    CROSS APPLY (VALUES (demo.PacketKey, 110, 1), (CONCAT(demo.PacketKey, '-NORMAL'), 50, 0))
         AS packet(PacketKey, MeasuredValue, IsAbnormal)
    WHERE (packet.IsAbnormal = 1 OR demo.RowNo <= 4)
      AND NOT EXISTS (SELECT 1 FROM dbo.HealthReading AS r WHERE r.PacketKey = packet.PacketKey);

    DECLARE @NewAlerts TABLE (AlertId int PRIMARY KEY, ReadingId int);
    INSERT dbo.HealthAlert (ReadingId, Severity, OpenedAt, TriageDeadline)
    OUTPUT inserted.AlertId, inserted.ReadingId INTO @NewAlerts (AlertId, ReadingId)
    SELECT reading.ReadingId, threshold.Severity, @Now, DATEADD(minute, threshold.TriageMinutes, @Now)
    FROM @Demo AS demo
    JOIN dbo.HealthReading AS reading ON reading.PacketKey = demo.PacketKey
    JOIN dbo.HealthThreshold AS threshold ON threshold.MetricCode = reading.MetricCode
    WHERE NOT EXISTS (SELECT 1 FROM dbo.HealthAlert AS a WHERE a.ReadingId = reading.ReadingId);

    INSERT dbo.HealthNotice (RecipientUserId, AlertId, Kind, CreatedAt)
    SELECT recipient.UserId, alert.AlertId, 'TRIAGE', @Now
    FROM @NewAlerts AS alert
    JOIN dbo.HealthReading AS reading ON reading.ReadingId = alert.ReadingId
    JOIN dbo.HealthBinding AS binding ON binding.BindingId = reading.BindingId
    CROSS APPLY dbo.fn_HealthNoticeRecipients(binding.ArchiveNo) AS recipient;

    INSERT dbo.HealthEvent (ArchiveNo, RequestKey, SourceType, Origin, Severity, OpenedAt, ResponseDeadline,
                            RespondedAt, RespondedBy, ArrivedAt, ClosedAt, Resolution, LastActorId)
    SELECT demo.ArchiveNo, demo.RequestKey, CASE WHEN demo.RowNo % 2 = 0 THEN 'SOS' ELSE 'MANUAL' END,
           'DEMO', 3, timing.OpenedAt, DATEADD(minute, 5, timing.OpenedAt),
           CASE WHEN demo.RowNo <= 16 THEN DATEADD(minute, 1, timing.OpenedAt) END,
           CASE WHEN demo.RowNo <= 16 THEN demo.CommunityUserId END,
           CASE WHEN demo.RowNo <= 8 THEN DATEADD(minute, 2, timing.OpenedAt) END,
           CASE WHEN demo.RowNo <= 8 THEN DATEADD(minute, 3, timing.OpenedAt) END,
           CASE WHEN demo.RowNo <= 8 THEN CHOOSE((demo.RowNo-1)%3+1,
                N'值班员回拨确认，已联系家属到家查看。',N'已到场检查呼叫设备，并和老人确认使用方法。',
                N'社区人员到场，向家属记录并反馈处理情况。') END,
           CASE WHEN demo.RowNo <= 16 THEN demo.CommunityUserId END
    FROM @Demo AS demo
    CROSS APPLY (SELECT DATEADD(minute, -60 - demo.RowNo, @Now) AS OpenedAt) AS timing
    WHERE NOT EXISTS (SELECT 1 FROM dbo.HealthEvent AS e WHERE e.RequestKey = demo.RequestKey);

    UPDATE evt SET Resolution=CHOOSE((demo.RowNo-1)%3+1,N'值班员回拨确认，已联系家属到家查看。',
        N'已到场检查呼叫设备，并和老人确认使用方法。',N'社区人员到场，向家属记录并反馈处理情况。')
    FROM dbo.HealthEvent evt JOIN @Demo demo ON demo.RequestKey=evt.RequestKey AND demo.ArchiveNo=evt.ArchiveNo
    WHERE evt.Origin='DEMO' AND evt.Resolution=N'演示处置已记录';

    COMMIT TRANSACTION;
END;
GO

EXEC dbo.usp_SeedHealth;
GO

PRINT N'健康与应急模拟数据已就绪。';
