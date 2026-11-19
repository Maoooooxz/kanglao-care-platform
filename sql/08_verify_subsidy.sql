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

DECLARE @ClaimId int, @ArchiveNo varchar(20), @CommunityId int, @ServiceTypeId int, @PeriodMonth date;
DECLARE @Creator int, @Street int, @Civil int, @BeforeStatus varchar(12), @BeforeLogCount int, @OrderIdsJson nvarchar(max);

SELECT TOP (1)
       @ClaimId = claim.ClaimId, @ArchiveNo = claim.ArchiveNo, @CommunityId = claim.CommunityId,
       @ServiceTypeId = claim.ServiceTypeId, @PeriodMonth = claim.PeriodMonth, @BeforeStatus = claim.Status,
       @Creator = creator.UserId, @Street = street.UserId, @Civil = civil.UserId
FROM dbo.v_SubsidyClaimSummary claim
CROSS APPLY (
    SELECT TOP (1) UserId FROM dbo.AppUser WHERE Role = 'community' AND CommunityId = claim.CommunityId AND Active = 1
    ORDER BY UserId
) creator
CROSS APPLY (
    SELECT TOP (1) UserId FROM dbo.AppUser WHERE Role = 'street' AND District = claim.District AND Active = 1
    ORDER BY UserId
) street
CROSS APPLY (
    SELECT TOP (1) UserId FROM dbo.AppUser WHERE Role = 'civil' AND District = claim.District AND Active = 1
    ORDER BY UserId
) civil
WHERE EXISTS (
    SELECT 1 FROM dbo.SubsidyClaimOrder line JOIN dbo.ServiceOrder orders ON orders.OrderId = line.OrderId
    WHERE line.ClaimId = claim.ClaimId AND orders.OrderNo LIKE 'DEMO-ORDER-%'
)
ORDER BY claim.ClaimId;

IF @ClaimId IS NULL
    THROW 51830, N'需先初始化补贴样例和社区、街道、民政演示账号。', 1;

SELECT @BeforeLogCount = COUNT(*) FROM dbo.SubsidyClaimLog WHERE ClaimId = @ClaimId;
SELECT @OrderIdsJson = CONCAT(N'[', STRING_AGG(CONVERT(nvarchar(max), OrderId), N','), N']')
FROM dbo.SubsidyClaimOrder WHERE ClaimId = @ClaimId;

BEGIN TRY
    BEGIN TRANSACTION;
    UPDATE dbo.SubsidyClaim SET Status = 'STREET', ChangeNote = N'验证退回与重新提交'
    WHERE ClaimId = @ClaimId;
    EXEC dbo.usp_ProgressSubsidyClaim @Street, @ClaimId, 'return', N'验证用街道退回原因';
    EXEC dbo.usp_SubmitSubsidyClaim @Creator, @ArchiveNo, @CommunityId, @ServiceTypeId, @PeriodMonth, @OrderIdsJson;
    EXEC dbo.usp_ProgressSubsidyClaim @Street, @ClaimId, 'approve', N'验证街道通过';
    EXEC dbo.usp_ProgressSubsidyClaim @Civil, @ClaimId, 'approve', N'验证民政通过';
    EXEC dbo.usp_ProgressSubsidyClaim @Civil, @ClaimId, 'pay', N'验证模拟拨付';

    IF NOT EXISTS (
        SELECT 1 FROM dbo.SubsidyClaim claim
        CROSS APPLY (SELECT SUM(line.Amount) AS Amount FROM dbo.SubsidyClaimOrder line WHERE line.ClaimId = claim.ClaimId) calc
        WHERE claim.ClaimId = @ClaimId AND claim.Status = 'PAID'
          AND claim.TotalAmount = calc.Amount AND claim.ApprovedAt IS NOT NULL AND claim.PaidAt IS NOT NULL
    )
        THROW 51831, N'补贴申报的状态、拨付时间或核算金额有误。', 1;

    IF NOT EXISTS (
        SELECT 1 FROM dbo.SubsidyClaimLog
        WHERE ClaimId = @ClaimId AND CurrentStatus = 'RETURNED' AND Note = N'验证用街道退回原因'
          AND ISJSON(OrderSnapshot, ARRAY) = 1 AND OrderSnapshot <> N'[]'
    )
        THROW 51832, N'退回时须保留订单和核算快照。', 1;

    DECLARE @OrderId int, @QualityActor int, @AgencyActor int, @InspectionId int, @RestrictionId int;
    SELECT TOP (1) @OrderId = visit.OrderId, @QualityActor = supervisor.UserId, @AgencyActor = manager.UserId
    FROM dbo.v_SubsidyEligibleOrder visit
    JOIN dbo.ServiceOrder orders ON orders.OrderId = visit.OrderId
    JOIN dbo.Community community ON community.CommunityId = visit.CommunityId
    CROSS APPLY (
        SELECT TOP (1) UserId FROM dbo.AppUser WHERE Role = 'civil' AND District = community.District AND Active = 1
        ORDER BY UserId
    ) supervisor
    CROSS APPLY (
        SELECT TOP (1) UserId FROM dbo.AppUser WHERE Role = 'agency' AND AgencyId = visit.AgencyId AND Active = 1
        ORDER BY UserId
    ) manager
    WHERE orders.OrderNo LIKE 'DEMO-ORDER-%'
    ORDER BY visit.OrderId;

    IF @OrderId IS NULL
        THROW 51833, N'未找到带机构账号的模拟完成订单。', 1;
    EXEC dbo.usp_RegisterInspection @QualityActor, 'order', @OrderId, 55, N'验证用抽查';
    SELECT TOP (1) @InspectionId = InspectionId, @RestrictionId = RestrictionId
    FROM dbo.ServiceInspection WHERE OrderId = @OrderId AND Finding = N'验证用抽查'
    ORDER BY InspectionId DESC;
    IF @RestrictionId IS NULL OR NOT EXISTS (
        SELECT 1 FROM dbo.WorkerRestriction WHERE RestrictionId = @RestrictionId AND ResolvedAt IS NULL
    )
        THROW 51834, N'低分抽查应建立未解除的接单限制。', 1;

    EXEC dbo.usp_ProgressInspection @AgencyActor, @InspectionId, 'correct', N'第一轮验证整改';
    EXEC dbo.usp_ProgressInspection @QualityActor, @InspectionId, 'reopen', N'缺少整改凭证';
    IF NOT EXISTS (SELECT 1 FROM dbo.ServiceInspection WHERE InspectionId = @InspectionId AND Status = 'OPEN')
        THROW 51835, N'复查退回后应重新进入待整改状态。', 1;
    EXEC dbo.usp_ProgressInspection @AgencyActor, @InspectionId, 'correct', N'第二轮验证整改';
    EXEC dbo.usp_ProgressInspection @QualityActor, @InspectionId, 'close', N'';
    IF NOT EXISTS (
        SELECT 1 FROM dbo.WorkerRestriction WHERE RestrictionId = @RestrictionId AND ResolvedAt IS NOT NULL
    )
        THROW 51836, N'复查通过应解除本次抽查的限制。', 1;

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;

IF NOT EXISTS (SELECT 1 FROM dbo.SubsidyClaim WHERE ClaimId = @ClaimId AND Status = @BeforeStatus)
   OR (SELECT COUNT(*) FROM dbo.SubsidyClaimLog WHERE ClaimId = @ClaimId) <> @BeforeLogCount
    THROW 51837, N'验证事务未恢复原申报状态及日志。', 1;

BEGIN TRY
    BEGIN TRANSACTION;
    UPDATE dbo.SubsidyClaim SET Status = 'STREET' WHERE ClaimId = @ClaimId;
    EXEC dbo.usp_ProgressSubsidyClaim @Civil, @ClaimId, 'approve', N'验证禁止越级';
    ROLLBACK TRANSACTION;
    THROW 51838, N'民政不应跳过街道审核。', 1;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    IF ERROR_NUMBER() <> 51809 THROW;
END CATCH;

DECLARE @OtherOrder int = (
    SELECT TOP (1) visit.OrderId FROM dbo.v_SubsidyEligibleOrder visit
    JOIN dbo.ServiceOrder orders ON orders.OrderId = visit.OrderId
    WHERE orders.OrderNo LIKE 'DEMO-ORDER-%' AND visit.ArchiveNo <> @ArchiveNo
    ORDER BY visit.OrderId
);
DECLARE @MixedOrders nvarchar(max) = CONCAT(LEFT(@OrderIdsJson, LEN(@OrderIdsJson) - 1), N',', @OtherOrder, N']');
BEGIN TRY
    BEGIN TRANSACTION;
    UPDATE dbo.SubsidyClaim SET Status = 'RETURNED' WHERE ClaimId = @ClaimId;
    EXEC dbo.usp_SubmitSubsidyClaim @Creator, @ArchiveNo, @CommunityId, @ServiceTypeId, @PeriodMonth, @MixedOrders;
    ROLLBACK TRANSACTION;
    THROW 51839, N'一份申报不应混入其他老人的订单。', 1;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    IF ERROR_NUMBER() <> 51808 THROW;
END CATCH;

PRINT N'PASS 补贴核算与留痕、退回重提、分级审核、模拟拨付、越级与混单拒绝、质量整改及限制解除。';
GO
