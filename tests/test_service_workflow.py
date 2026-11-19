from datetime import datetime, timedelta, timezone
from uuid import uuid4

from werkzeug.security import generate_password_hash

from conftest import log_in, submit
from kanglao.db import execute, one, transaction
from kanglao.web import SHANGHAI, beijing_today


def _post(client, path, **fields):
    response = submit(client, path, **fields)
    assert response.status_code == 302, response.get_data(as_text=True)


def _cleanup(application, archive_no, worker_id, family_name, worker_name):
    with application.app_context(), transaction():
        execute("""
            DELETE a FROM dbo.ServiceVisitAudit a JOIN dbo.ServiceOrder o ON o.OrderId=a.OrderId WHERE o.ArchiveNo=?;
            DELETE v FROM dbo.ServiceVisit v JOIN dbo.ServiceOrder o ON o.OrderId=v.OrderId WHERE o.ArchiveNo=?;
            DELETE a FROM dbo.ServiceDispatchAudit a JOIN dbo.ServiceDispatch d ON d.DispatchId=a.DispatchId
            JOIN dbo.ServiceOrder o ON o.OrderId=d.OrderId WHERE o.ArchiveNo=?;
            DELETE d FROM dbo.ServiceDispatch d JOIN dbo.ServiceOrder o ON o.OrderId=d.OrderId WHERE o.ArchiveNo=?;
            DELETE dbo.ServiceOrder WHERE ArchiveNo=?;
            DELETE a FROM dbo.CarePlanAudit a JOIN dbo.CarePlan p ON p.PlanId=a.PlanId WHERE p.ArchiveNo=?;
            DELETE dbo.CarePlan WHERE ArchiveNo=?;
            DELETE dbo.AbilityAssessment WHERE ArchiveNo=?;
            DELETE dbo.ArchiveAudit WHERE ArchiveNo=?;
            DELETE dbo.AppUser WHERE Username IN (?,?);
            DELETE dbo.WorkerShift WHERE WorkerId=?;
            DELETE dbo.WorkerService WHERE WorkerId=?;
            DELETE dbo.WorkerCommunity WHERE WorkerId=?;
            DELETE dbo.Worker WHERE WorkerId=?;
            DELETE dbo.ElderArchive WHERE ArchiveNo=?;
        """, *([archive_no] * 9), family_name, worker_name, *([worker_id] * 4), archive_no)


def test_http_service_lifecycle_produces_subsidy_eligible_order(application, password):
    suffix = uuid4().hex[:10]
    archive_no = f"HTTP-{suffix.upper()}"
    id_number = f"000000{uuid4().int % 10**12:012d}"
    family_name, worker_name = f"http-family-{suffix}", f"http-worker-{suffix}"
    worker_id = None
    today = beijing_today()
    valid_through = today + timedelta(days=7)
    now = datetime.now(timezone.utc).replace(microsecond=0)
    appointment = now + timedelta(minutes=20)
    booking_end = appointment + timedelta(minutes=30)
    community = application.test_client()
    family = application.test_client()
    caregiver = application.test_client()
    log_in(community, "community", password)

    try:
        with application.app_context():
            area = one("""
                SELECT c.CommunityId,c.Latitude,c.Longitude,p.PackageId,p.AbilityLevel,t.ServiceTypeId,a.AgencyId
                FROM dbo.AppUser u JOIN dbo.Community c ON c.CommunityId=u.CommunityId
                CROSS JOIN dbo.CarePackage p CROSS JOIN dbo.ServiceType t CROSS JOIN dbo.Agency a
                WHERE u.Username='community' AND p.Name=N'演示照护包001'
                  AND t.Code='DEMO-SERVICE-001' AND a.AgencyNo='DEMO-AGENCY-001'
            """)
            assert area is not None, "请先装载演示账号、服务包和机构"

        _post(community, "/archives/", op="create", archive_no=archive_no, id_number=id_number,
              name="流程验证老人", birth_date="1950-01-01", address="流程验证地址",
              latitude=str(area["Latitude"]), longitude=str(area["Longitude"]))
        with application.app_context():
            assert one("SELECT ArchiveNo FROM dbo.ElderArchive WHERE ArchiveNo=?", archive_no) is not None
        _post(community, f"/archives/{archive_no}", op="assessment", scale="ADL", score="75",
              level=area["AbilityLevel"], assessment_date=today.isoformat(), valid_through=valid_through.isoformat())
        with application.app_context():
            assessment = one("SELECT AssessmentStatus FROM dbo.v_CurrentAbilityAssessment WHERE ArchiveNo=?", archive_no)
            assert assessment["AssessmentStatus"] == "有效"

        with application.app_context(), transaction():
            worker_id = one("INSERT dbo.Worker(WorkerNo,AgencyId,Name,Grade) OUTPUT inserted.WorkerId VALUES(?,?,?,?)",
                            worker_name, area["AgencyId"], "流程验证护工", "模拟等级")["WorkerId"]
            execute("INSERT dbo.WorkerCommunity(WorkerId,CommunityId) VALUES(?,?)", worker_id, area["CommunityId"])
            execute("EXEC dbo.usp_SetWorkerCredential ?,?,?,?,?", worker_id, area["ServiceTypeId"],
                    f"http-cert-{suffix}", today, valid_through)
            execute("EXEC dbo.usp_CreateWorkerShift ?,?,?,4", worker_id,
                    now.replace(tzinfo=None) - timedelta(hours=1), now.replace(tzinfo=None) + timedelta(hours=3))
            password_hash = generate_password_hash(password)
            execute("""INSERT dbo.AppUser(Username,DisplayName,PasswordHash,Role,ArchiveNo)
                       VALUES(?,?,?,'family',?)""", family_name, "流程验证家属", password_hash, archive_no)
            execute("""INSERT dbo.AppUser(Username,DisplayName,PasswordHash,Role,WorkerId)
                       VALUES(?,?,?,'caregiver',?)""", worker_name, "流程验证护工", password_hash, worker_id)
            family_id = one("SELECT UserId FROM dbo.AppUser WHERE Username=?", family_name)["UserId"]

        _post(community, "/services/plans", operation="CREATE", archive_no=archive_no,
              package_id=area["PackageId"], worker_id=worker_id, starts_on=(today - timedelta(days=1)).isoformat(),
              ends_on=valid_through.isoformat())
        with application.app_context():
            assert one("SELECT PlanId FROM dbo.CarePlan WHERE ArchiveNo=? AND Status='ACTIVE'", archive_no)

        log_in(family, family_name, password)
        _post(family, "/services/orders", operation="BOOK", archive_no=archive_no,
              service_type_id=area["ServiceTypeId"], start=appointment.astimezone(SHANGHAI).isoformat(timespec="seconds"),
              end=booking_end.astimezone(SHANGHAI).isoformat(timespec="seconds"))
        with application.app_context():
            order = one("SELECT OrderId,Status,Channel FROM dbo.ServiceOrder WHERE ArchiveNo=?", archive_no)
            assert order is not None and order["Status"] == "NEW" and order["Channel"] == "FAMILY"
            order_id = order["OrderId"]

        _post(community, "/services/orders", operation="DISPATCH", order_id=order_id, worker_id=worker_id)
        with application.app_context():
            assert one("SELECT Status FROM dbo.ServiceOrder WHERE OrderId=?", order_id)["Status"] == "OFFERED"
        log_in(caregiver, worker_name, password)
        assert submit(caregiver, "/services/orders", operation="CONFIRM", order_id=order_id, reason="越权验证").status_code == 403
        _post(caregiver, "/services/orders", operation="ACCEPT", order_id=order_id)

        with application.app_context():
            assert one("SELECT Status FROM dbo.ServiceOrder WHERE OrderId=?", order_id)["Status"] == "ACCEPTED"
            # 保留真实 HTTP 操作，在独立 QA 数据库推进这份预约至当前可签到时段。
            execute("UPDATE dbo.ServiceOrder SET AppointmentStart=DATEADD(minute,-2,SYSUTCDATETIME()) WHERE OrderId=?",
                    order_id)
        _post(caregiver, "/services/orders", operation="CHECK_IN", order_id=order_id)
        with application.app_context():
            assert one("SELECT Status FROM dbo.ServiceOrder WHERE OrderId=?", order_id)["Status"] == "IN_SERVICE"
            execute("UPDATE dbo.ServiceVisit SET CheckInAt=DATEADD(minute,-3,SYSUTCDATETIME()) WHERE OrderId=?", order_id)
        _post(caregiver, "/services/orders", operation="CHECK_OUT", order_id=order_id, reason="模拟上门服务完成")
        with application.app_context():
            assert one("SELECT Status FROM dbo.ServiceOrder WHERE OrderId=?", order_id)["Status"] == "AWAITING_CONFIRMATION"
            assert one("SELECT OrderId FROM dbo.v_SubsidyEligibleOrder WHERE OrderId=?", order_id) is None

        _post(family, "/services/orders", operation="CONFIRM", order_id=order_id, reason="模拟家属签名")
        with application.app_context():
            eligible = one("SELECT OrderId,WorkerId,EffectiveMinutes FROM dbo.v_SubsidyEligibleOrder WHERE OrderId=?", order_id)
            assert eligible is not None and eligible["WorkerId"] == worker_id and eligible["EffectiveMinutes"] >= 1
            signed = one("SELECT ConfirmedBy,DATALENGTH(ConfirmationHash) AS HashBytes FROM dbo.ServiceVisit WHERE OrderId=?",
                         order_id)
            assert signed == {"ConfirmedBy": family_id, "HashBytes": 32}
    finally:
        _cleanup(application, archive_no, worker_id, family_name, worker_name)
