"""Exercise retries and unique business keys from separate SQL Server sessions."""

import json
from concurrent.futures import ThreadPoolExecutor
from secrets import token_hex
from threading import Barrier

import mssql_python

from kanglao.db import connection, execute, one, transaction


def _race(application, statement, params):
    ready = Barrier(2, timeout=15)

    def call():
        with application.app_context():
            connection()
            execute("SET LOCK_TIMEOUT 12000")
            ready.wait()
            try:
                execute(statement, *params)
            except mssql_python.Error as exc:
                return str(exc)
            return None

    with ThreadPoolExecutor(max_workers=2) as workers:
        calls = [workers.submit(call) for _ in range(2)]
        return [future.result(timeout=25) for future in calls]


def test_concurrent_sos_retries_create_one_event(application):
    request_key = "QA-SOS-" + token_hex(10)
    with application.app_context():
        actor = one("SELECT UserId FROM dbo.AppUser WHERE Username='family' AND Active=1")["UserId"]
    try:
        assert _race(application, "EXEC dbo.usp_OpenHealthEvent ?, ?, 'SOS', ?", ("E0001", request_key, actor)) == [
            None, None
        ]
        with application.app_context():
            assert one(
                "SELECT COUNT(*) AS n FROM dbo.HealthEvent WHERE RequestKey=? AND SourceType='SOS'", request_key
            )["n"] == 1
    finally:
        with application.app_context(), transaction():
            execute("DELETE a FROM dbo.HealthEventAudit a JOIN dbo.HealthEvent e ON e.EventId=a.EventId WHERE e.RequestKey=?",
                    request_key)
            execute("DELETE n FROM dbo.HealthNotice n JOIN dbo.HealthEvent e ON e.EventId=n.EventId WHERE e.RequestKey=?",
                    request_key)
            execute("DELETE FROM dbo.HealthEvent WHERE RequestKey=?", request_key)


def _make_claim_fixture(application, order_no):
    with application.app_context(), transaction():
        item = one("""
            DECLARE @CheckoutAt datetime2(0) = DATEADD(minute,-2,SYSUTCDATETIME());
            DECLARE @LocalDate date = CONVERT(date,DATEADD(hour,8,@CheckoutAt));
            DECLARE @Month date = DATEFROMPARTS(YEAR(@LocalDate),MONTH(@LocalDate),1);

            SELECT TOP (1) o.OrderId AS SourceOrderId, o.ArchiveNo, o.CommunityId, o.ServiceTypeId,
                   eligible.WorkerId, creator.UserId AS CreatorId, family.UserId AS FamilyId,
                   @CheckoutAt AS CheckoutAt, @Month AS PeriodMonth
            FROM dbo.v_SubsidyEligibleOrder eligible
            JOIN dbo.ServiceOrder o ON o.OrderId=eligible.OrderId
            JOIN dbo.Community c ON c.CommunityId=o.CommunityId
            CROSS APPLY (
                SELECT TOP (1) UserId FROM dbo.AppUser
                WHERE Role='community' AND Active=1 AND CommunityId=o.CommunityId ORDER BY UserId
            ) creator
            CROSS APPLY (
                SELECT TOP (1) UserId FROM dbo.AppUser
                WHERE Role='family' AND Active=1 AND ArchiveNo=o.ArchiveNo ORDER BY UserId
            ) family
            WHERE o.OrderNo LIKE 'DEMO-ORDER-%'
              AND EXISTS (
                  SELECT 1 FROM dbo.SubsidyPolicy policy
                  WHERE policy.District=c.District AND policy.ServiceTypeId=o.ServiceTypeId
                    AND @LocalDate BETWEEN policy.ValidFrom AND policy.ValidThrough
              )
              AND NOT EXISTS (
                  SELECT 1 FROM dbo.SubsidyClaim claim WHERE claim.ArchiveNo=o.ArchiveNo
                    AND claim.ServiceTypeId=o.ServiceTypeId AND claim.PeriodMonth=@Month
              )
            ORDER BY o.OrderId
        """)
        assert item, "测试库需要有适用政策的未申报演示项目。"

        order = one("""
            DECLARE @CheckoutAt datetime2(0) = ?, @SourceOrderId int = ?, @OrderNo varchar(30) = ?;
            DECLARE @CheckInAt datetime2(0) = DATEADD(minute,-20,@CheckoutAt);
            INSERT dbo.ServiceOrder (
                OrderNo, ArchiveNo, PlanId, ServiceTypeId, CommunityId, Status, Price, AppointmentStart,
                AppointmentEnd, Address, Latitude, Longitude, Channel, CreatedAt, DispatchDeadline
            )
            SELECT @OrderNo,ArchiveNo,PlanId,ServiceTypeId,CommunityId,'COMPLETED',Price,@CheckInAt,
                @CheckoutAt,Address,Latitude,Longitude,'COMMUNITY',DATEADD(hour,-2,@CheckInAt),@CheckInAt
            FROM dbo.ServiceOrder WHERE OrderId=@SourceOrderId;
            SELECT CONVERT(int,SCOPE_IDENTITY()) AS OrderId;
        """, item["CheckoutAt"], item["SourceOrderId"], order_no)
        order_id = order["OrderId"]
        shift_id = one("""
            DECLARE @CheckoutAt datetime2(0) = ?, @WorkerId int = ?;
            SELECT TOP (1) ShiftId FROM dbo.WorkerShift WHERE WorkerId=@WorkerId
              AND StartsAt <= DATEADD(minute,-20,@CheckoutAt) AND EndsAt >= @CheckoutAt
            ORDER BY StartsAt DESC;
        """, item["CheckoutAt"], item["WorkerId"])
        created_shift = not shift_id
        if created_shift:
            shift_id = one("""
                DECLARE @CheckoutAt datetime2(0) = ?, @WorkerId int = ?;
                INSERT dbo.WorkerShift (WorkerId,StartsAt,EndsAt,Capacity)
                VALUES (@WorkerId,DATEADD(minute,-20,@CheckoutAt),@CheckoutAt,1);
                SELECT CONVERT(int,SCOPE_IDENTITY()) AS ShiftId;
            """, item["CheckoutAt"], item["WorkerId"])
        dispatch = one("""
            DECLARE @OrderId int = ?, @WorkerId int = ?, @ShiftId int = ?, @CheckoutAt datetime2(0) = ?;
            INSERT dbo.ServiceDispatch (
                OrderId,WorkerId,ShiftId,OfferedAt,OfferExpiresAt,AcceptedAt,ClosedAt,CloseReason
            ) VALUES (@OrderId,@WorkerId,@ShiftId,DATEADD(hour,-2,@CheckoutAt),DATEADD(hour,-1,@CheckoutAt),
                DATEADD(minute,-100,@CheckoutAt),@CheckoutAt,N'验证结算服务');
            SELECT CONVERT(int,SCOPE_IDENTITY()) AS DispatchId;
        """, order_id, item["WorkerId"], shift_id["ShiftId"], item["CheckoutAt"])
        execute("""
            DECLARE @OrderId int = ?, @DispatchId int = ?, @WorkerId int = ?, @FamilyId int = ?;
            INSERT dbo.ServiceVisit (
                OrderId,DispatchId,WorkerId,CheckInAt,CheckOutAt,InLatitude,InLongitude,OutLatitude,OutLongitude,
                InFence,OutFence,InShift,OutShift,ServiceRecord,WorkStatus,EffectiveMinutes,ConfirmedAt,
                ConfirmedBy,ConfirmationText,ConfirmationHash
            )
            SELECT @OrderId,@DispatchId,@WorkerId,AppointmentStart,AppointmentEnd,Latitude,Longitude,Latitude,Longitude,
                1,1,1,1,N'验证用服务记录','VALID',20,AppointmentEnd,@FamilyId,N'验证用家属签字',
                dbo.fn_ServiceConfirmationHash(@OrderId,@FamilyId,AppointmentEnd,N'验证用家属签字')
            FROM dbo.ServiceOrder WHERE OrderId=@OrderId;
        """, order_id, dispatch["DispatchId"], item["WorkerId"], item["FamilyId"])
        assert one("SELECT OrderId FROM dbo.v_SubsidyEligibleOrder WHERE OrderId=?", order_id)
        item.update(OrderId=order_id, DispatchId=dispatch["DispatchId"],
                    TemporaryShiftId=shift_id["ShiftId"] if created_shift else None)
        return item


def test_concurrent_monthly_claim_allows_one_submission(application):
    item = _make_claim_fixture(application, "QA-CLAIM-" + token_hex(8))
    order_id = item["OrderId"]
    try:
        result = _race(
            application, "EXEC dbo.usp_SubmitSubsidyClaim ?, ?, ?, ?, ?, ?",
            (item["CreatorId"], item["ArchiveNo"], item["CommunityId"], item["ServiceTypeId"],
             item["PeriodMonth"], json.dumps([order_id])),
        )
        failures = [error for error in result if error is not None]
        assert len(failures) == 1 and (
            "51807" in failures[0] or "同一老人、项目和月份已有申报" in failures[0]
        ), result
        with application.app_context():
            assert one("SELECT COUNT(*) AS n FROM dbo.SubsidyClaimOrder WHERE OrderId=?", order_id)["n"] == 1
            assert one("""
                SELECT COUNT(*) AS n FROM dbo.SubsidyClaim
                WHERE ArchiveNo=? AND ServiceTypeId=? AND PeriodMonth=?
            """, item["ArchiveNo"], item["ServiceTypeId"], item["PeriodMonth"])["n"] == 1
    finally:
        with application.app_context(), transaction():
            row = one("SELECT ClaimId FROM dbo.SubsidyClaimOrder WHERE OrderId=?", order_id)
            if row:
                claim_id = row["ClaimId"]
                execute("DELETE FROM dbo.SubsidyClaimLog WHERE ClaimId=?", claim_id)
                execute("DELETE FROM dbo.SubsidyClaimOrder WHERE ClaimId=?", claim_id)
                execute("DELETE FROM dbo.SubsidyClaim WHERE ClaimId=?", claim_id)
            execute("DELETE FROM dbo.ServiceVisitAudit WHERE OrderId=?", order_id)
            execute("DELETE FROM dbo.ServiceVisit WHERE OrderId=?", order_id)
            execute("DELETE FROM dbo.ServiceDispatchAudit WHERE DispatchId=?", item["DispatchId"])
            execute("DELETE FROM dbo.ServiceDispatch WHERE DispatchId=?", item["DispatchId"])
            execute("DELETE FROM dbo.ServiceOrder WHERE OrderId=?", order_id)
            if item["TemporaryShiftId"]:
                execute("DELETE FROM dbo.WorkerShift WHERE ShiftId=?", item["TemporaryShiftId"])
