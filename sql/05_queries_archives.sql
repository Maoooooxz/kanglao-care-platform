USE [KanglaoCourse];
GO
SET NOCOUNT ON;

-- 场景：按社区统计评估有效的在册老人。
-- A
SELECT c.CommunityId,c.Name,COUNT(*) AS Eligible
FROM dbo.Community c JOIN dbo.ElderArchive e ON e.CommunityId=c.CommunityId
JOIN dbo.v_CurrentAbilityAssessment a ON a.ArchiveNo=e.ArchiveNo
WHERE e.IsActive=1 AND a.AssessmentStatus=N'有效'
GROUP BY c.CommunityId,c.Name ORDER BY c.CommunityId;
-- B
WITH recent AS (
    SELECT a.ArchiveNo,a.ValidThrough,
           ROW_NUMBER() OVER (PARTITION BY a.ArchiveNo ORDER BY a.AssessmentDate DESC,a.AssessmentId DESC) AS rank_no
    FROM dbo.AbilityAssessment a WHERE a.AssessmentDate<=CONVERT(date,DATEADD(hour,8,SYSUTCDATETIME()))
)
SELECT c.CommunityId,c.Name,COUNT(*) AS Eligible
FROM dbo.Community c JOIN dbo.ElderArchive e ON e.CommunityId=c.CommunityId
JOIN recent a ON a.ArchiveNo=e.ArchiveNo AND a.rank_no=1
WHERE e.IsActive=1 AND a.ValidThrough>=CONVERT(date,DATEADD(hour,8,SYSUTCDATETIME()))
GROUP BY c.CommunityId,c.Name ORDER BY c.CommunityId;

-- 场景：查未来 14 天内需要复评的在册档案。
-- A
SELECT e.ArchiveNo,e.FullName,c.Name,a.ValidThrough
FROM dbo.ElderArchive e JOIN dbo.Community c ON c.CommunityId=e.CommunityId
JOIN dbo.v_CurrentAbilityAssessment a ON a.ArchiveNo=e.ArchiveNo
WHERE e.IsActive=1 AND a.AssessmentStatus=N'有效'
  AND a.ValidThrough<=DATEADD(day,14,CONVERT(date,DATEADD(hour,8,SYSUTCDATETIME())))
ORDER BY a.ValidThrough,e.ArchiveNo;
-- B
SELECT e.ArchiveNo,e.FullName,c.Name,a.ValidThrough
FROM dbo.ElderArchive e JOIN dbo.Community c ON c.CommunityId=e.CommunityId
CROSS JOIN (SELECT CONVERT(date,DATEADD(hour,8,SYSUTCDATETIME())) AS Today) t
CROSS APPLY (
    SELECT TOP (1) h.ValidThrough FROM dbo.AbilityAssessment h
    WHERE h.ArchiveNo=e.ArchiveNo AND h.AssessmentDate<=t.Today
    ORDER BY h.AssessmentDate DESC,h.AssessmentId DESC
) a
WHERE e.IsActive=1 AND a.ValidThrough BETWEEN t.Today AND DATEADD(day,14,t.Today)
ORDER BY a.ValidThrough,e.ArchiveNo;

-- 场景：按档案清点历史评估数量，包含尚无记录的档案。
-- A
SELECT e.ArchiveNo,c.Name,COUNT(h.AssessmentId) AS Assessments
FROM dbo.ElderArchive e JOIN dbo.Community c ON e.CommunityId=c.CommunityId
LEFT JOIN dbo.v_AbilityAssessmentHistory h ON h.ArchiveNo=e.ArchiveNo
GROUP BY e.ArchiveNo,c.Name ORDER BY e.ArchiveNo;
-- B
SELECT e.ArchiveNo,c.Name,
       (SELECT COUNT(*) FROM dbo.AbilityAssessment h WHERE h.ArchiveNo=e.ArchiveNo) AS Assessments
FROM dbo.ElderArchive e JOIN dbo.Community c ON e.CommunityId=c.CommunityId
ORDER BY e.ArchiveNo;
