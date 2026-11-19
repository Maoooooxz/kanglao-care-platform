-- 场景：查看人工调度池中的订单、所属社区和服务项目
-- A
SELECT OrderId, ArchiveNo, ServiceName, CommunityId, District, AppointmentStart
FROM dbo.v_ManualDispatchPool
ORDER BY OrderId;
-- B
SELECT o.OrderId, o.ArchiveNo, t.Name, c.CommunityId, c.District, o.AppointmentStart
FROM dbo.ServiceOrder o
JOIN dbo.ServiceType t ON t.ServiceTypeId = o.ServiceTypeId
JOIN dbo.Community c ON c.CommunityId = o.CommunityId
JOIN dbo.ElderArchive e ON e.ArchiveNo = o.ArchiveNo
WHERE o.Status = 'POOL'
ORDER BY o.OrderId;

-- 场景：按订单查看最近一次派单及其护工
-- A
SELECT OrderId, ArchiveNo, ServiceName, DispatchId, WorkerName
FROM dbo.v_ServiceOrderOverview
ORDER BY OrderId;
-- B
SELECT o.OrderId, o.ArchiveNo, t.Name, d.DispatchId, w.Name
FROM dbo.ServiceOrder o
JOIN dbo.ServiceType t ON t.ServiceTypeId = o.ServiceTypeId
LEFT JOIN dbo.ServiceDispatch d ON d.DispatchId = (
    SELECT MAX(h.DispatchId) FROM dbo.ServiceDispatch h WHERE h.OrderId = o.OrderId
)
LEFT JOIN dbo.Worker w ON w.WorkerId = d.WorkerId
ORDER BY o.OrderId;

-- 场景：列出已签退、待家属签字的服务订单
-- A
SELECT o.OrderId, o.ArchiveNo, t.Name, o.Price
FROM dbo.ServiceOrder o JOIN dbo.ServiceType t ON t.ServiceTypeId = o.ServiceTypeId
WHERE o.Status = 'AWAITING_CONFIRMATION'
  AND EXISTS (SELECT 1 FROM dbo.ServiceVisit v WHERE v.OrderId = o.OrderId
              AND v.CheckOutAt IS NOT NULL AND v.ConfirmedAt IS NULL)
ORDER BY o.OrderId;
-- B
SELECT o.OrderId, o.ArchiveNo, t.Name, o.Price
FROM dbo.ServiceOrder o
JOIN dbo.ServiceType t ON t.ServiceTypeId = o.ServiceTypeId
JOIN dbo.ServiceVisit v ON v.OrderId = o.OrderId AND v.CheckOutAt IS NOT NULL AND v.ConfirmedAt IS NULL
WHERE o.Status = 'AWAITING_CONFIRMATION'
ORDER BY o.OrderId;

-- 场景：计算班次已接受单量和剩余额度
-- A
SELECT ShiftId, WorkerId, WorkerName, Capacity, AcceptedCount, Remaining
FROM dbo.v_WorkerShiftAvailability
ORDER BY ShiftId;
-- B
SELECT s.ShiftId, s.WorkerId, w.Name, s.Capacity, agg.AcceptedCount, s.Capacity - agg.AcceptedCount
FROM dbo.WorkerShift s
JOIN dbo.Worker w ON w.WorkerId = s.WorkerId
CROSS APPLY (SELECT COUNT(*) AS AcceptedCount FROM dbo.ServiceDispatch d WHERE d.ShiftId = s.ShiftId
             AND d.AcceptedAt IS NOT NULL AND (d.ClosedAt IS NULL OR EXISTS (
                 SELECT 1 FROM dbo.ServiceVisit v WHERE v.DispatchId = d.DispatchId AND v.CheckOutAt IS NOT NULL
             ))) agg
ORDER BY s.ShiftId;

-- 场景：按机构和护工汇总月度有效工时
-- A
SELECT AgencyId, WorkerId, WorkMonth, Visits, EffectiveMinutes
FROM dbo.v_WorkerMonthlyHours
ORDER BY AgencyId, WorkerId, WorkMonth;
-- B
SELECT w.AgencyId, v.WorkerId, CONVERT(char(7), DATEADD(hour, 8, v.CheckOutAt), 126),
       COUNT_BIG(*), SUM(CONVERT(bigint, v.EffectiveMinutes))
FROM dbo.ServiceVisit v
JOIN dbo.Worker w ON w.WorkerId = v.WorkerId
JOIN dbo.Agency a ON a.AgencyId = w.AgencyId
WHERE v.WorkStatus = 'VALID' AND v.CheckOutAt IS NOT NULL
GROUP BY w.AgencyId, v.WorkerId, CONVERT(char(7), DATEADD(hour, 8, v.CheckOutAt), 126)
ORDER BY w.AgencyId, v.WorkerId, CONVERT(char(7), DATEADD(hour, 8, v.CheckOutAt), 126);

-- 场景：定位需复核的工时、老人档案和辖区
-- A
SELECT OrderId, ArchiveNo, District, WorkerName, CheckInAt, CheckOutAt, ReviewReason
FROM dbo.v_WorkHourReview
ORDER BY OrderId;
-- B
SELECT o.OrderId, o.ArchiveNo, c.District, w.Name, v.CheckInAt, v.CheckOutAt, v.ReviewReason
FROM dbo.ServiceOrder o
JOIN dbo.Community c ON c.CommunityId = o.CommunityId
JOIN dbo.ServiceVisit v ON v.OrderId = o.OrderId
JOIN dbo.Worker w ON w.WorkerId = v.WorkerId
WHERE v.WorkStatus = 'REVIEW'
ORDER BY o.OrderId;
