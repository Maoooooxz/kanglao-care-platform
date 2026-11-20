from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta, timezone
from threading import Barrier
from uuid import uuid4

import pytest
from mssql_python import Error

from kanglao.db import execute, one, query, transaction
from kanglao.web import beijing_today


def _race(application, statement, calls):
    barrier = Barrier(2, timeout=10)

    def attempt(parameters):
        with application.app_context():
            session_id = one("SELECT @@SPID AS SessionId")["SessionId"]
            barrier.wait()
            result = one(f"""
                SET LOCK_TIMEOUT 12000;
                BEGIN TRY
                    BEGIN TRANSACTION;
                    {statement};
                    WAITFOR DELAY '00:00:00.300';
                    COMMIT;
                    SELECT 0 AS ErrorNumber;
                END TRY
                BEGIN CATCH
                    IF XACT_STATE() <> 0 ROLLBACK;
                    SELECT ERROR_NUMBER() AS ErrorNumber;
                END CATCH;
            """, *parameters)
            return session_id, result["ErrorNumber"]

    with ThreadPoolExecutor(max_workers=2) as workers:
        futures = [workers.submit(attempt, parameters) for parameters in calls]
        results = [future.result(timeout=30) for future in futures]
    assert len({session_id for session_id, _ in results}) == 2
    return sorted(error_number for _, error_number in results)


@pytest.fixture
def service_case(application):
    suffix = uuid4().hex[:10].upper()
    archives = (f"RACE-{suffix}-1", f"RACE-{suffix}-2")
    today = beijing_today()
    ends_on = today + timedelta(days=10)
    with application.app_context(), transaction():
        reference = one("""
            SELECT c.CommunityId,c.Latitude,c.Longitude,p.PackageId,p.AbilityLevel,t.ServiceTypeId,a.AgencyId
            FROM dbo.Community c
            CROSS JOIN dbo.CarePlan planRow JOIN dbo.CarePackage p ON p.PackageId=planRow.PackageId
            CROSS JOIN dbo.ServiceType t CROSS JOIN dbo.Agency a
            WHERE c.CommunityId=1 AND planRow.PlanNo='DEMO-PLAN-001'
              AND t.Code='DEMO-SERVICE-001' AND a.AgencyNo='DEMO-AGENCY-001'
        """)
        assert reference is not None, "并发测试依赖已装载的模拟社区、服务包和机构"
        for index, archive_no in enumerate(archives, 1):
            synthetic_id = f"000000{uuid4().int % 10**12:012d}"
            execute("""
                INSERT dbo.ElderArchive(IdNumber,ArchiveNo,FullName,BirthDate,Address,CommunityId,Latitude,Longitude)
                VALUES (?,?,?,?,?,?,?,?)
            """, synthetic_id, archive_no, "并发测试老人", date(1950, 1, 1), "并发测试地址",
                    reference["CommunityId"], reference["Latitude"], reference["Longitude"])
            execute("""
                EXEC dbo.usp_RecordAbilityAssessment ?,?,'ADL',75,?,N'并发测试评估员',?,?
            """, f"RACE-{suffix}-{index}", archive_no, reference["AbilityLevel"], today, ends_on)
        worker_id = one("""
            INSERT dbo.Worker(WorkerNo,AgencyId,Name,Grade) OUTPUT inserted.WorkerId VALUES (?,?,?,?)
        """, f"RACE-WK-{suffix}", reference["AgencyId"], "并发测试护工", "院内测试等级")["WorkerId"]
        execute("INSERT dbo.WorkerCommunity(WorkerId,CommunityId) VALUES (?,?)", worker_id, reference["CommunityId"])
        execute("EXEC dbo.usp_SetWorkerCredential ?,?,?,?,?",
                worker_id, reference["ServiceTypeId"], f"RACE-CERT-{suffix}", today, ends_on)

    try:
        yield {**reference, "archives": archives, "worker_id": worker_id, "today": today, "ends_on": ends_on}
    finally:
        with application.app_context(), transaction():
            # 保留 QA 中其他档案与订单。删除顺序按这些测试行的外键依赖。
            execute("""
                DELETE a FROM dbo.ServiceDispatchAudit a JOIN dbo.ServiceDispatch d ON d.DispatchId=a.DispatchId
                JOIN dbo.ServiceOrder o ON o.OrderId=d.OrderId WHERE o.ArchiveNo IN (?,?);
                DELETE d FROM dbo.ServiceDispatch d JOIN dbo.ServiceOrder o ON o.OrderId=d.OrderId
                WHERE o.ArchiveNo IN (?,?);
                DELETE dbo.ServiceOrder WHERE ArchiveNo IN (?,?);
                DELETE a FROM dbo.CarePlanAudit a JOIN dbo.CarePlan p ON p.PlanId=a.PlanId WHERE p.ArchiveNo IN (?,?);
                DELETE dbo.CarePlan WHERE ArchiveNo IN (?,?);
                DELETE dbo.WorkerShift WHERE WorkerId=?;
                DELETE dbo.WorkerCommunity WHERE WorkerId=?;
                DELETE dbo.WorkerService WHERE WorkerId=?;
                DELETE dbo.Worker WHERE WorkerId=?;
                DELETE dbo.AbilityAssessment WHERE ArchiveNo IN (?,?);
                DELETE dbo.ArchiveAudit WHERE ArchiveNo IN (?,?);
                DELETE dbo.ElderArchive WHERE ArchiveNo IN (?,?);
            """, *archives, *archives, *archives, *archives, *archives,
                    worker_id, worker_id, worker_id, worker_id, *archives, *archives, *archives)


def test_concurrent_care_plans_reject_overlap(application, service_case):
    archive = service_case["archives"][0]
    parameters = (archive, service_case["PackageId"], service_case["worker_id"],
                  service_case["today"], service_case["ends_on"])
    outcomes = _race(application, "EXEC dbo.usp_CreateCarePlan ?,?,?,?,?", (parameters, parameters))
    assert outcomes == [0, 51204]
    with application.app_context():
        assert one("SELECT COUNT(*) AS n FROM dbo.CarePlan WHERE ArchiveNo=? AND Status='ACTIVE'", archive)["n"] == 1


def test_concurrent_acceptance_competes_for_one_shift_seat(application, service_case):
    worker_id = service_case["worker_id"]
    now = datetime.now(timezone.utc).replace(tzinfo=None, microsecond=0)
    order_ids = []
    with application.app_context(), transaction():
        execute("EXEC dbo.usp_CreateWorkerShift ?,?,?,1", worker_id, now - timedelta(minutes=5), now + timedelta(hours=4))
        for index, archive in enumerate(service_case["archives"], 1):
            execute("EXEC dbo.usp_CreateCarePlan ?,?,?,?,?", archive, service_case["PackageId"], worker_id,
                    service_case["today"], service_case["ends_on"])
            starts_at = now + timedelta(hours=index)
            ends_at = starts_at + timedelta(minutes=30)
            execute("""
                EXEC dbo.usp_CreateServiceOrder @ArchiveNo=?,@ServiceTypeId=?,@AppointmentStart=?,
                     @AppointmentEnd=?,@Address=NULL,@Latitude=NULL,@Longitude=NULL,@Channel='COMMUNITY',@Now=?
            """, archive, service_case["ServiceTypeId"], starts_at, ends_at, now)
            order_id = one("SELECT OrderId FROM dbo.ServiceOrder WHERE ArchiveNo=?", archive)["OrderId"]
            execute("EXEC dbo.usp_ServiceOrderAction @OrderId=?,@Action='DISPATCH',@WorkerId=?,@Now=?",
                    order_id, worker_id, now)
            order_ids.append(order_id)

    outcomes = _race(application, "EXEC dbo.usp_ServiceOrderAction @OrderId=?,@Action='ACCEPT',@WorkerId=?,@Now=?",
                     [(order_id, worker_id, now) for order_id in order_ids])
    assert outcomes == [0, 51214]
    with application.app_context():
        orders = query("SELECT Status FROM dbo.ServiceOrder WHERE OrderId IN (?,?)", *order_ids)
        assert {order["Status"] for order in orders} == {"ACCEPTED", "OFFERED"}
        shift = one("SELECT AcceptedCount,Remaining FROM dbo.v_WorkerShiftAvailability WHERE WorkerId=?", worker_id)
        assert shift == {"AcceptedCount": 1, "Remaining": 0}


def test_non_duty_keeps_existing_dispatch_for_manual_reassignment(application, service_case):
    worker_id = service_case["worker_id"]
    archive = service_case["archives"][0]
    service_id = service_case["ServiceTypeId"]
    today, ends_on = service_case["today"], service_case["ends_on"]
    now = datetime.now(timezone.utc).replace(tzinfo=None, microsecond=0)
    start = now + timedelta(minutes=15)
    end = start + timedelta(minutes=30)
    with application.app_context():
        manager = one("SELECT UserId FROM dbo.AppUser WHERE Username='agency'")["UserId"]
        outsider = one("SELECT UserId FROM dbo.AppUser WHERE Username='agency002'")["UserId"]
        with pytest.raises(Error):
            execute("EXEC dbo.usp_SetWorkerEmploymentStatus ?,?,'LEFT'", worker_id, outsider)
        assert one("SELECT EmploymentStatus FROM dbo.Worker WHERE WorkerId=?", worker_id)["EmploymentStatus"] == "ON_DUTY"
        execute("EXEC dbo.usp_CreateWorkerShift ?,?,?,2", worker_id, now, now + timedelta(hours=2))
        execute("EXEC dbo.usp_CreateCarePlan ?,?,?,?,?", archive, service_case["PackageId"], worker_id, today, ends_on)
        execute("EXEC dbo.usp_CreateServiceOrder ?,?,?,?,NULL,NULL,NULL,'COMMUNITY',@Now=?", archive, service_id, start, end, now)
        order_id = one("SELECT OrderId FROM dbo.ServiceOrder WHERE ArchiveNo=?", archive)["OrderId"]
        execute("EXEC dbo.usp_ServiceOrderAction ?,'DISPATCH',?,@Now=?", order_id, worker_id, now)
        dispatch_id = one("SELECT DispatchId FROM dbo.ServiceDispatch WHERE OrderId=?", order_id)["DispatchId"]

        for status in ("ON_LEAVE", "LEFT"):
            execute("EXEC dbo.usp_SetWorkerEmploymentStatus ?,?,?", worker_id, manager, status)
            assert not query("SELECT WorkerId FROM dbo.fn_EligibleServiceShifts(?) WHERE WorkerId=?", order_id, worker_id)
            with pytest.raises(Error):
                execute("EXEC dbo.usp_ServiceOrderAction ?,'ACCEPT',?,@Now=?", order_id, worker_id, now)
            with pytest.raises(Error):
                execute("EXEC dbo.usp_CreateWorkerShift ?,?,?,2", worker_id, now + timedelta(hours=3), now + timedelta(hours=4))
            assert one("SELECT ClosedAt FROM dbo.ServiceDispatch WHERE DispatchId=?", dispatch_id)["ClosedAt"] is None

        execute("EXEC dbo.usp_SetWorkerEmploymentStatus ?,?,'ON_DUTY'", worker_id, manager)
        execute("EXEC dbo.usp_ServiceOrderAction ?,'ACCEPT',?,@Now=?", order_id, worker_id, now)
        execute("EXEC dbo.usp_SetWorkerEmploymentStatus ?,?,'ON_LEAVE'", worker_id, manager)
        with pytest.raises(Error):
            execute("EXEC dbo.usp_ServiceOrderAction ?,'CHECK_IN',?,@Now=?", order_id, worker_id, start)
        assert one("SELECT Status FROM dbo.ServiceOrder WHERE OrderId=?", order_id)["Status"] == "ACCEPTED"

        with transaction() as db:
            try:
                replacement = one("""INSERT dbo.Worker(WorkerNo,AgencyId,Name,Grade)
                                   OUTPUT inserted.WorkerId VALUES (?,?,N'替班护工',N'测试')""",
                                  f"QA-ALT-{uuid4().hex[:10]}", service_case["AgencyId"])["WorkerId"]
                execute("INSERT dbo.WorkerCommunity(WorkerId,CommunityId) VALUES (?,?)", replacement, service_case["CommunityId"])
                execute("EXEC dbo.usp_SetWorkerCredential ?,?,N'替班测试证书',?,?", replacement, service_id, today, ends_on)
                execute("EXEC dbo.usp_CreateWorkerShift ?,?,?,1", replacement, now, now + timedelta(hours=2))
                execute("EXEC dbo.usp_ServiceOrderAction ?,'DISPATCH',?,N'护工请假，社区改派',@Now=?",
                        order_id, replacement, now + timedelta(seconds=1))
                history = query("SELECT WorkerId,CloseReason FROM dbo.ServiceDispatch WHERE OrderId=? ORDER BY DispatchId", order_id)
                assert history == [{"WorkerId": worker_id, "CloseReason": "护工请假，社区改派"},
                                   {"WorkerId": replacement, "CloseReason": None}]
            finally:
                db.rollback()
