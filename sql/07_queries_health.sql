-- 1. 查找还没有响应、也没有升级的应急事件，先处理最接近截止的事项。
-- A
SELECT TOP (20) evt.EventId, evt.ArchiveNo, elder.FullName,
       community.Name AS CommunityName, evt.Severity, evt.ResponseDeadline
FROM dbo.HealthEvent AS evt
JOIN dbo.ElderArchive AS elder ON elder.ArchiveNo = evt.ArchiveNo
JOIN dbo.Community AS community ON community.CommunityId = elder.CommunityId
WHERE evt.RespondedAt IS NULL AND evt.EscalatedAt IS NULL
ORDER BY evt.ResponseDeadline, evt.EventId;

-- B
SELECT TOP (20) evt.EventId, evt.ArchiveNo, evt.FullName,
       community.Name AS CommunityName, evt.Severity, evt.ResponseDeadline
FROM dbo.v_HealthEventOverview AS evt
JOIN dbo.ElderArchive AS elder ON elder.ArchiveNo = evt.ArchiveNo
JOIN dbo.Community AS community ON community.CommunityId = elder.CommunityId
WHERE evt.State = 'OPEN'
ORDER BY evt.ResponseDeadline, evt.EventId;

-- 2. 按绑定分别取最近体征。补传的历史读数仍在原绑定内排序。
-- A
SELECT binding.BindingId, binding.ArchiveNo, device.DeviceCode,
       reading.PacketKey, reading.CapturedAt, reading.MeasuredValue
FROM dbo.HealthBinding AS binding
JOIN dbo.HealthDevice AS device ON device.DeviceId = binding.DeviceId
CROSS APPLY (
    SELECT TOP (1) r.PacketKey, r.CapturedAt, r.MeasuredValue
    FROM dbo.HealthReading AS r
    WHERE r.BindingId = binding.BindingId
    ORDER BY r.CapturedAt DESC, r.ReadingId DESC
) AS reading
ORDER BY binding.ArchiveNo, binding.BindingId;

-- B
SELECT ranked.BindingId, ranked.ArchiveNo, ranked.DeviceCode,
       ranked.PacketKey, ranked.CapturedAt, ranked.MeasuredValue
FROM (
    SELECT binding.BindingId, binding.ArchiveNo, device.DeviceCode,
           reading.PacketKey, reading.CapturedAt, reading.MeasuredValue,
           ROW_NUMBER() OVER (PARTITION BY binding.BindingId ORDER BY reading.CapturedAt DESC, reading.ReadingId DESC) AS RowNo
    FROM dbo.HealthBinding AS binding
    JOIN dbo.HealthDevice AS device ON device.DeviceId = binding.DeviceId
    JOIN dbo.HealthReading AS reading ON reading.BindingId = binding.BindingId
) AS ranked
WHERE ranked.RowNo = 1
ORDER BY ranked.ArchiveNo, ranked.BindingId;

-- 3. 找出仍有未读提醒的待确认告警。同一告警可提醒多位值班员。
-- A
SELECT alert.AlertId, alert.ArchiveNo, alert.MetricName, alert.MeasuredValue, alert.TriageDeadline
FROM dbo.v_HealthAlertQueue AS alert
WHERE alert.State = 'PENDING'
  AND EXISTS (SELECT 1 FROM dbo.HealthNotice AS notice
              WHERE notice.AlertId = alert.AlertId AND notice.ReadAt IS NULL)
ORDER BY alert.TriageDeadline, alert.AlertId;

-- B
SELECT alert.AlertId, alert.ArchiveNo, alert.MetricName, alert.MeasuredValue, alert.TriageDeadline
FROM dbo.v_HealthAlertQueue AS alert
JOIN (SELECT DISTINCT AlertId FROM dbo.HealthNotice WHERE AlertId IS NOT NULL AND ReadAt IS NULL) AS unread
    ON unread.AlertId = alert.AlertId
WHERE alert.State = 'PENDING'
ORDER BY alert.TriageDeadline, alert.AlertId;
