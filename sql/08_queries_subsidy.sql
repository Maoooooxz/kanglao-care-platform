USE [KanglaoCourse];
GO
SET NOCOUNT ON;
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

DECLARE @District nvarchar(80) = (
    SELECT TOP (1) District FROM dbo.Community WHERE District IS NOT NULL ORDER BY CommunityId
);
DECLARE @ClaimId int = (SELECT MIN(ClaimId) FROM dbo.SubsidyClaim);

-- 场景一，查看辖区的街道待审申报和订单数。
-- 写法 A 从申报摘要筛选，摘要逐单统计明细。
SELECT ClaimId, FullName, ServiceName, CommunityName, OrderCount, TotalAmount
FROM dbo.v_SubsidyClaimSummary
WHERE District = @District AND Status = 'STREET'
ORDER BY ClaimId;

-- 写法 B 先按申报汇总明细，再与档案、服务项目和社区连接。
WITH order_counts AS (
    SELECT ClaimId, COUNT(*) AS OrderCount FROM dbo.SubsidyClaimOrder GROUP BY ClaimId
)
SELECT claim.ClaimId, elder.FullName, service.Name AS ServiceName, community.Name AS CommunityName,
       ISNULL(order_counts.OrderCount, 0) AS OrderCount, claim.TotalAmount
FROM dbo.SubsidyClaim claim
JOIN dbo.ElderArchive elder ON elder.ArchiveNo = claim.ArchiveNo
JOIN dbo.ServiceType service ON service.ServiceTypeId = claim.ServiceTypeId
JOIN dbo.Community community ON community.CommunityId = claim.CommunityId
LEFT JOIN order_counts ON order_counts.ClaimId = claim.ClaimId
WHERE community.District = @District AND claim.Status = 'STREET'
ORDER BY claim.ClaimId;

-- 场景二，核对一份申报保存的有效工时和政策金额。
-- 写法 A 从追溯视图分组，视图连接了申报、明细和政策。
SELECT ClaimId, SUM(EffectiveMinutes) AS EffectiveMinutes, SUM(Amount) AS Amount
FROM dbo.v_SubsidyClaimTrace WHERE ClaimId = @ClaimId
GROUP BY ClaimId;

-- 写法 B 从指定申报通过 APPLY 聚合其明细，适合定位单据。
SELECT claim.ClaimId, totals.EffectiveMinutes, totals.Amount
FROM dbo.SubsidyClaim claim
CROSS APPLY (
    SELECT SUM(line.EffectiveMinutes) AS EffectiveMinutes, SUM(line.Amount) AS Amount
    FROM dbo.SubsidyClaimOrder line WHERE line.ClaimId = claim.ClaimId HAVING COUNT(*) > 0
) totals
WHERE claim.ClaimId = @ClaimId;

-- 场景三，按服务机构统计本辖区未复查完成的抽查。
-- 写法 A 先筛选抽查视图，再按机构汇总。
SELECT AgencyId, AgencyName, COUNT(*) AS UnresolvedCount
FROM dbo.v_QualityInspectionSummary
WHERE ReviewDistrict = @District AND Status IN ('OPEN', 'CORRECTED')
GROUP BY AgencyId, AgencyName
ORDER BY AgencyId;

-- 写法 B 以机构作为入口，对关联护工的检查逐机构汇总。
SELECT agency.AgencyId, agency.Name AS AgencyName, checks.UnresolvedCount
FROM dbo.Agency agency
CROSS APPLY (
    SELECT COUNT(*) AS UnresolvedCount
    FROM dbo.Worker worker JOIN dbo.ServiceInspection inspection ON inspection.WorkerId = worker.WorkerId
    WHERE worker.AgencyId = agency.AgencyId AND inspection.ReviewDistrict = @District
      AND inspection.Status IN ('OPEN', 'CORRECTED')
    HAVING COUNT(*) > 0
) checks
ORDER BY agency.AgencyId;

SET STATISTICS TIME OFF;
SET STATISTICS IO OFF;
GO
