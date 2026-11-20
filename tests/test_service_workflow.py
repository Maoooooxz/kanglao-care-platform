from datetime import datetime, timedelta, timezone
from decimal import Decimal
import json
from uuid import uuid4

import pytest
from werkzeug.security import generate_password_hash

from conftest import log_in, submit
from kanglao.db import execute, one, transaction
from kanglao.web import SHANGHAI, beijing_today


def _post(client, path, **fields):
    response = submit(client, path, **fields)
    assert response.status_code == 302, response.get_data(as_text=True)


def _cleanup(application, archive_no, worker_id, signer_name, worker_name):
    with application.app_context(), transaction():
        execute("""
            DELETE log FROM dbo.SubsidyClaimLog log JOIN dbo.SubsidyClaim claim ON claim.ClaimId=log.ClaimId
            WHERE claim.ArchiveNo=?;
            DELETE line FROM dbo.SubsidyClaimOrder line JOIN dbo.SubsidyClaim claim ON claim.ClaimId=line.ClaimId
            WHERE claim.ArchiveNo=?;
            DELETE dbo.SubsidyClaim WHERE ArchiveNo=?;
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
        """, *([archive_no] * 12), signer_name, worker_name, *([worker_id] * 4), archive_no)


@pytest.mark.parametrize("signer_role", ("family", "resident"))
def test_http_service_lifecycle_through_subsidy_payment(application, password, signer_role):
    suffix = uuid4().hex[:10]
    archive_no = f"HTTP-{suffix.upper()}"
    id_number = f"000000{uuid4().int % 10**12:012d}"
    signer_name, worker_name = f"http-{signer_role}-{suffix}", f"http-worker-{suffix}"
    worker_id = None
    today = beijing_today()
    valid_through = today + timedelta(days=7)
    now = datetime.now(timezone.utc).replace(microsecond=0)
    appointment = now + timedelta(minutes=20)
    booking_end = appointment + timedelta(minutes=30)
    community = application.test_client()
    signer = application.test_client()
    caregiver = application.test_client()
    log_in(community, "community", password)

    try:
        with application.app_context():
            area = one("""
                SELECT c.CommunityId,c.Latitude,c.Longitude,p.PackageId,p.AbilityLevel,t.ServiceTypeId,a.AgencyId
                FROM dbo.AppUser u JOIN dbo.Community c ON c.CommunityId=u.CommunityId
                CROSS JOIN dbo.CarePlan planRow JOIN dbo.CarePackage p ON p.PackageId=planRow.PackageId
                CROSS JOIN dbo.ServiceType t CROSS JOIN dbo.Agency a
                WHERE u.Username='community' AND planRow.PlanNo='DEMO-PLAN-001'
                  AND t.Code='DEMO-SERVICE-001' AND a.AgencyNo='DEMO-AGENCY-001'
            """)
            assert area is not None, "请先装载演示账号、服务包和机构"

        _post(community, "/archives/", op="create", archive_no=archive_no, id_number=id_number,
              name="流程验证老人", birth_date=f"{today.year - 70}-01-01", address="流程验证地址",
              subsidy_category="LOW_INCOME")
        with application.app_context():
            assert one("SELECT Latitude,Longitude FROM dbo.ElderArchive WHERE ArchiveNo=?", archive_no) == {
                "Latitude": area["Latitude"], "Longitude": area["Longitude"],
            }
        _post(community, f"/archives/{archive_no}", op="assessment", scale="ADL", score="75",
              level=area["AbilityLevel"], assessment_date=today.isoformat(), valid_through="")
        with application.app_context():
            assessment = one("SELECT AssessmentStatus,ValidThrough FROM dbo.v_CurrentAbilityAssessment WHERE ArchiveNo=?", archive_no)
            assert assessment == {"AssessmentStatus": "有效", "ValidThrough": today + timedelta(days=180)}

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
                       VALUES(?,?,?,?,?)""", signer_name, "流程验证签字人", password_hash, signer_role, archive_no)
            execute("""INSERT dbo.AppUser(Username,DisplayName,PasswordHash,Role,WorkerId)
                       VALUES(?,?,?,'caregiver',?)""", worker_name, "流程验证护工", password_hash, worker_id)
            signer_id = one("SELECT UserId FROM dbo.AppUser WHERE Username=?", signer_name)["UserId"]

        _post(community, "/services/plans", operation="CREATE", archive_no=archive_no,
              package_id=area["PackageId"], worker_id=worker_id, starts_on=(today - timedelta(days=1)).isoformat(),
              ends_on=valid_through.isoformat())
        with application.app_context():
            assert one("SELECT PlanId FROM dbo.CarePlan WHERE ArchiveNo=? AND Status='ACTIVE'", archive_no)

        log_in(signer, signer_name, password)
        _post(signer, "/services/orders/book", archive_no=archive_no,
              service_type_id=area["ServiceTypeId"], start=appointment.astimezone(SHANGHAI).isoformat(timespec="seconds"),
              end=booking_end.astimezone(SHANGHAI).isoformat(timespec="seconds"))
        with application.app_context():
            order = one("SELECT OrderId,Status,Channel FROM dbo.ServiceOrder WHERE ArchiveNo=?", archive_no)
            assert order is not None and order["Status"] == "NEW" and order["Channel"] == "FAMILY"
            order_id = order["OrderId"]

        order_path = f"/services/orders/{order_id}"
        assert "流程验证护工" in community.get(order_path).get_data(as_text=True)
        _post(community, order_path, operation="DISPATCH", worker_id=worker_id)
        with application.app_context():
            assert one("SELECT Status FROM dbo.ServiceOrder WHERE OrderId=?", order_id)["Status"] == "OFFERED"
        log_in(caregiver, worker_name, password)
        assert submit(caregiver, order_path, operation="CONFIRM", reason="越权验证").status_code == 403
        _post(caregiver, order_path, operation="ACCEPT")

        with application.app_context():
            assert one("SELECT Status FROM dbo.ServiceOrder WHERE OrderId=?", order_id)["Status"] == "ACCEPTED"
            # 保留真实 HTTP 操作，在独立 QA 数据库推进这份预约至当前可签到时段。
            execute("UPDATE dbo.ServiceOrder SET AppointmentStart=DATEADD(minute,-2,SYSUTCDATETIME()) WHERE OrderId=?",
                    order_id)
        _post(caregiver, order_path, operation="CHECK_IN")
        with application.app_context():
            assert one("SELECT Status FROM dbo.ServiceOrder WHERE OrderId=?", order_id)["Status"] == "IN_SERVICE"
            execute("UPDATE dbo.ServiceVisit SET CheckInAt=DATEADD(minute,-3,SYSUTCDATETIME()) WHERE OrderId=?", order_id)
        manager = application.test_client()
        log_in(manager, "agency", password)
        _post(manager, "/services/workers", operation="EMPLOYMENT", worker_id=worker_id, employment_status="LEFT")
        with application.app_context():
            assert one("SELECT EmploymentStatus FROM dbo.Worker WHERE WorkerId=?", worker_id)["EmploymentStatus"] == "LEFT"
        assert "模拟离场签退" in caregiver.get(order_path).get_data(as_text=True)
        _post(caregiver, order_path, operation="CHECK_OUT", reason="模拟上门服务完成")
        with application.app_context():
            assert one("SELECT Status FROM dbo.ServiceOrder WHERE OrderId=?", order_id)["Status"] == "AWAITING_CONFIRMATION"
            assert one("SELECT OrderId FROM dbo.v_SubsidyEligibleOrder WHERE OrderId=?", order_id) is None

        outsider = application.test_client()
        log_in(outsider, "resident", password)
        assert outsider.get(order_path).status_code == 404
        assert submit(outsider, order_path, operation="CONFIRM", reason="无权签字").status_code == 404
        signature_label = "家属电子签字" if signer_role == "family" else "老人本人电子签字"
        assert signature_label not in signer.get("/services/orders?status=AWAITING_CONFIRMATION").get_data(as_text=True)
        details = signer.get(order_path).get_data(as_text=True)
        assert "模拟上门服务完成" in details and signature_label in details and "待核定" in details
        assert details.count('name="operation" value="CONFIRM"') == 1
        _post(signer, order_path, operation="CONFIRM", reason="模拟签名")
        _post(signer, order_path, operation="CONFIRM", reason="重复签名不应覆盖")
        with application.app_context():
            eligible = one("""SELECT OrderId,WorkerId,EffectiveMinutes,SubsidyCategory,SubsidyAbilityLevel
                            FROM dbo.v_SubsidyEligibleOrder WHERE OrderId=?""", order_id)
            assert eligible is not None and eligible["WorkerId"] == worker_id and eligible["EffectiveMinutes"] >= 1
            assert eligible["SubsidyCategory"] == "LOW_INCOME" and eligible["SubsidyAbilityLevel"] == area["AbilityLevel"]
            signed = one("""SELECT ConfirmedBy,ConfirmationText,DATALENGTH(ConfirmationHash) AS HashBytes
                          FROM dbo.ServiceVisit WHERE OrderId=?""",
                         order_id)
            assert signed == {"ConfirmedBy": signer_id, "ConfirmationText": "模拟签名", "HashBytes": 32}

        _post(community, "/subsidy/", operation="submit", order_ids=order_id)
        with application.app_context():
            claim = one("""SELECT claim.ClaimId, claim.Status, line.SubsidyCategory, line.SubsidyAbilityLevel
                         FROM dbo.SubsidyClaim claim JOIN dbo.SubsidyClaimOrder line ON line.ClaimId=claim.ClaimId
                         WHERE line.OrderId=?""", order_id)
            assert claim is not None and claim["Status"] == "STREET"
            assert claim["SubsidyCategory"] == "LOW_INCOME" and claim["SubsidyAbilityLevel"] == area["AbilityLevel"]

        path = f'/subsidy/{claim["ClaimId"]}'
        street, civil = application.test_client(), application.test_client()
        log_in(street, "street", password)
        log_in(civil, "civil", password)
        claim_page = street.get(path)
        claim_content = claim_page.get_data(as_text=True)
        assert claim_page.status_code == 200 and "申报证明归档" in claim_content and "流程验证签字人" in claim_content
        assert "待核定" in signer.get(order_path).get_data(as_text=True)
        _post(street, path, operation="review", action="return", note="请补充说明")
        with application.app_context():
            execute("UPDATE dbo.ServiceVisit SET ServiceRecord=N'重新提交的服务说明' WHERE OrderId=?", order_id)
        _post(community, path, operation="submit", order_ids=order_id)
        with application.app_context():
            snapshots = one("""SELECT TOP (1) old.EvidenceSnapshot AS Original, updated.EvidenceSnapshot AS Revised
                             FROM dbo.SubsidyClaimLog old JOIN dbo.SubsidyClaimLog updated ON updated.ClaimId=old.ClaimId
                             WHERE old.ClaimId=? AND old.CurrentStatus='STREET' AND updated.CurrentStatus='STREET'
                               AND updated.LogId>old.LogId ORDER BY old.LogId,updated.LogId""", claim["ClaimId"])
            original, revised = (json.loads(snapshots[key])[0] for key in ("Original", "Revised"))
            assert original["ServiceRecord"] == "模拟上门服务完成" and len(original["ConfirmationHash"]) == 64
            assert original["ConfirmationHash"] not in claim_content
            assert revised["ServiceRecord"] == "重新提交的服务说明"
        _post(street, path, operation="review", action="approve", note="街道审核通过")
        _post(civil, path, operation="review", action="approve", note="民政审核通过")
        _post(civil, path, operation="review", action="pay", note="模拟拨付")
        with application.app_context():
            paid = one("""SELECT claim.Status,claim.PaidAt,line.OrderPrice-line.Amount AS OutOfPocket
                         FROM dbo.SubsidyClaim claim JOIN dbo.SubsidyClaimOrder line ON line.ClaimId=claim.ClaimId
                         WHERE claim.ClaimId=?""", claim["ClaimId"])
            assert paid["Status"] == "PAID" and paid["PaidAt"] is not None
        details = signer.get(order_path).get_data(as_text=True)
        assert "自付" in details and "待核定" not in details
        assert f'{Decimal(paid["OutOfPocket"]):.2f}' in details
    finally:
        _cleanup(application, archive_no, worker_id, signer_name, worker_name)
