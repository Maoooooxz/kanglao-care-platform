import re
from datetime import timedelta
from secrets import token_hex

import pytest
from werkzeug.security import check_password_hash

from kanglao.db import execute, one, query, transaction
from kanglao.web import beijing_today
from conftest import log_in, submit

EXPECTED_ROUTES = {
    "community": ("/archives/", "/services/plans", "/services/orders", "/services/workers", "/health/", "/subsidy/"),
    "family": ("/archives/", "/services/plans", "/services/orders", "/health/", "/subsidy/"),
    "resident": ("/archives/", "/services/plans", "/services/orders", "/health/", "/subsidy/"),
    "caregiver": ("/services/plans", "/services/orders", "/services/workers", "/health/", "/subsidy/quality"),
    "agency": ("/services/plans", "/services/orders", "/services/workers", "/health/", "/subsidy/quality"),
    "street": ("/archives/", "/services/plans", "/services/orders", "/services/workers", "/health/", "/subsidy/policies"),
    "civil": ("/archives/", "/services/plans", "/services/orders", "/services/workers", "/health/", "/subsidy/quality"),
}


def test_named_demo_data_and_community_password(application, password):
    with application.app_context():
        people = query("""SELECT elder.FullName,elder.Address,community.Name AS CommunityName
                       FROM dbo.ElderArchive elder JOIN dbo.Community community ON community.CommunityId=elder.CommunityId
                       WHERE elder.ArchiveNo IN ('E0001','E0002') ORDER BY elder.ArchiveNo""")
        assert people[0]["FullName"] == "周秀兰" and people[1]["FullName"] == "刘建民"
        assert all(person["CommunityName"] == "北京林业大学社区" and "北京市海淀区" in person["Address"] for person in people)
        account = one("SELECT DisplayName,PasswordHash FROM dbo.AppUser WHERE Username='community'")
        assert account["DisplayName"] == "蔡元涵" and check_password_hash(account["PasswordHash"], "123456")
        for username in ("community01", "family"):
            account = one("SELECT PasswordHash FROM dbo.AppUser WHERE Username=?", username)
            assert check_password_hash(account["PasswordHash"], password)


@pytest.mark.parametrize("role", EXPECTED_ROUTES)
def test_pages_for_each_account(application, password, role):
    client = application.test_client()
    log_in(client, role, password)
    for path in EXPECTED_ROUTES[role]:
        page = client.get(path)
        assert page.status_code == 200, f"{role} {path} 数据库或模板错误 ({page.status_code})"
        assert "<h1>" in page.get_data(as_text=True)


def test_scope_masking_and_csrf(application, password):
    client = application.test_client()
    assert client.get("/archives/").status_code == 302
    log_in(client, "family", password)
    own_page = client.get("/archives/E0001")
    assert own_page.status_code == 200
    content = own_page.get_data(as_text=True)
    assert "**************0001" in content
    assert "000000195001010001" not in content
    assert client.get("/archives/E0019").status_code == 404
    assert submit(client, "/archives/E0001", op="toggle").status_code == 403
    assert client.post("/health/events/open", data={"archive_no": "E0001"}).status_code == 400
    assert client.get("/services/workers").status_code == 403


def test_lockout(application, password):
    username = "family0019"
    client = application.test_client()
    try:
        client.get("/login")
        for _ in range(5):
            assert submit(client, "/login", username=username, password="invalid-example").status_code == 401
        assert submit(client, "/login", username=username, password=password).status_code == 401
        with application.app_context():
            assert one("SELECT LockedUntil FROM dbo.AppUser WHERE Username=?", username)["LockedUntil"] is not None
    finally:
        with application.app_context():
            execute("UPDATE dbo.AppUser SET FailedAttempts=0,LockedUntil=NULL WHERE Username=?", username)


def test_batch_archival_failure_keeps_transaction_atomic(application, password):
    client = application.test_client()
    log_in(client, "community", password)
    archive_no = "Q" + token_hex(4).upper()
    row = f"000000195001019908,{archive_no},验证批量档案,1950-01-01,验证路"
    result = submit(client, "/archives/", op="bulk", csv_text=f"{row}\n{row}")
    assert result.status_code == 302
    with application.app_context():
        assert one("SELECT ArchiveNo FROM dbo.ElderArchive WHERE ArchiveNo=?", archive_no) is None


def test_every_demo_business_table_has_twenty_rows(application):
    with application.app_context():
        tables = query("SELECT name FROM sys.tables WHERE schema_id=SCHEMA_ID('dbo')")
        assert len(tables) >= 30
        for row in tables:
            name = row["name"]
            assert re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", name)
            assert one(f"SELECT COUNT(*) AS n FROM dbo.[{name}]")["n"] >= 20, name


def _panel(response, title):
    assert response.status_code == 200
    return next(section for section in re.findall(r"<section\b[^>]*>.*?</section>", response.get_data(as_text=True), re.S)
                if re.search(rf"<h2\b[^>]*>{re.escape(title)}</h2>", section))


def test_expanded_demo_archives_and_pagination(application, password):
    client = application.test_client()
    log_in(client, "community", password)
    listing = client.get("/archives/")
    assert "下一页" in _panel(listing, "老人档案")
    assert "name=\"latitude\"" not in _panel(listing, "新建档案")
    assert "name=\"longitude\"" not in _panel(listing, "新建档案")
    assert "E0041" in _panel(client.get("/archives/?page=2"), "老人档案")
    with application.app_context():
        assert one("SELECT COUNT(*) AS n FROM dbo.ElderArchive WHERE ArchiveNo BETWEEN 'E0021' AND 'E0060'")["n"] == 40
        assert one("SELECT COUNT(*) AS n FROM dbo.AbilityAssessment WHERE AssessmentNo LIKE 'DEMO-MORE-%'")["n"] == 36
        assert one("SELECT COUNT(*) AS n FROM dbo.ServiceOrder WHERE OrderNo LIKE 'DEMO-MORE-%'")["n"] == 27


def test_reassessment_reminders_include_day_fourteen_and_only_local_archives(application, password):
    client = application.test_client()
    log_in(client, "community", password)
    today = beijing_today()
    with application.app_context(), transaction() as db:
        try:
            for archive_no in ("E0001", "E0005"):
                execute("EXEC dbo.usp_RecordAbilityAssessment ?,?,'ADL',75,N'轻度失能',N'边界测试',?,?",
                        f"QA-REMIND-{archive_no}", archive_no, today, today + timedelta(days=14))
            panel = _panel(client.get("/"), "14 天内到期待复评")
            assert "/archives/E0001#assessment-form" in panel and "/archives/E0005" not in panel
            assert (today + timedelta(days=14)).isoformat() in panel
            execute("UPDATE dbo.AbilityAssessment SET ValidThrough=? WHERE AssessmentNo='QA-REMIND-E0001'",
                    today + timedelta(days=15))
            assert "/archives/E0001" not in _panel(client.get("/"), "14 天内到期待复评")
            execute("UPDATE dbo.ElderArchive SET IsActive=0 WHERE ArchiveNo='E0001'")
            execute("UPDATE dbo.AbilityAssessment SET ValidThrough=? WHERE AssessmentNo='QA-REMIND-E0001'", today)
            assert "/archives/E0001" not in _panel(client.get("/"), "14 天内到期待复评")
        finally:
            db.rollback()


def test_expired_assessment_is_replaced_in_queue_and_retained_in_history(application, password):
    client = application.test_client()
    log_in(client, "community", password)
    today = beijing_today()
    with application.app_context(), transaction() as db:
        try:
            assert "/archives/E0002#assessment-form" in _panel(client.get("/"), "已过期待复评")
            previous = one("""SELECT AssessmentNo,ValidThrough FROM dbo.v_AbilityAssessmentHistory
                            WHERE ArchiveNo='E0002' ORDER BY AssessmentDate DESC,AssessmentId DESC""")
            response = submit(client, "/archives/E0002", op="assessment", scale="ADL", score="77",
                              level="轻度失能", assessment_date=today.isoformat(), valid_through="")
            assert response.status_code == 302
            assert "/archives/E0002" not in _panel(client.get("/"), "已过期待复评")
            assert previous["AssessmentNo"] in _panel(client.get("/archives/E0002"), "能力评估历史")
            assert one("SELECT ValidThrough FROM dbo.AbilityAssessment WHERE AssessmentNo=?",
                       previous["AssessmentNo"])["ValidThrough"] == previous["ValidThrough"]
            assert one("SELECT AssessmentStatus FROM dbo.v_CurrentAbilityAssessment WHERE ArchiveNo='E0002'")[
                "AssessmentStatus"] == "有效"
        finally:
            db.rollback()


def test_transfer_preserves_archive_and_completed_order(application, password):
    original_admin, receiving_admin = application.test_client(), application.test_client()
    log_in(original_admin, "community", password)
    log_in(receiving_admin, "community02", password)
    with application.app_context(), transaction() as db:
        try:
            archive = one("SELECT IdNumber FROM dbo.ElderArchive WHERE ArchiveNo='E0001'")
            completed = one("SELECT Status,Address,CommunityId FROM dbo.ServiceOrder WHERE OrderNo='DEMO-ORDER-001-1'")
            pending = one("SELECT OrderId,Address FROM dbo.ServiceOrder WHERE OrderNo='DEMO-ORDER-001-3'")
            for title in ("维护档案", "跨社区迁移"):
                form = _panel(original_admin.get("/archives/E0001"), title)
                assert "name=\"latitude\"" not in form and "name=\"longitude\"" not in form
            worker = one("SELECT WorkerId FROM dbo.Worker WHERE WorkerNo='DEMO-WORKER-001'")["WorkerId"]
            execute("EXEC dbo.usp_ServiceOrderAction ?,'DISPATCH',?", pending["OrderId"], worker)
            result = submit(receiving_admin, "/archives/", op="create", id_number=archive["IdNumber"],
                            archive_no="QA-DUPLICATE", name="重复档案", birth_date="1950-01-01", address="演示住址")
            assert result.status_code == 302
            assert "联系原社区办理迁移" in receiving_admin.get("/archives/").get_data(as_text=True)
            assert one("SELECT ArchiveNo FROM dbo.ElderArchive WHERE ArchiveNo='QA-DUPLICATE'") is None
            execute("UPDATE dbo.Community SET Latitude=40.009,Longitude=116.342 WHERE CommunityId=2")
            result = submit(original_admin, "/archives/E0001", op="transfer", community=2,
                            new_address="六道口社区（新演示住址）", reason="搬到女儿家")
            assert result.status_code == 302
            assert original_admin.get("/archives/E0001").status_code == 404
            received = receiving_admin.get("/archives/E0001")
            assert "搬到女儿家" in _panel(received, "迁移记录")
            summary = _panel(received, "档案概要")
            assert "六道口社区（新演示住址）" in summary and archive["IdNumber"] not in summary
            assert one("SELECT IdNumber FROM dbo.ElderArchive WHERE ArchiveNo='E0001'") == archive
            assert one("SELECT Latitude,Longitude FROM dbo.ElderArchive WHERE ArchiveNo='E0001'") == one(
                "SELECT Latitude,Longitude FROM dbo.Community WHERE CommunityId=2")
            assert one("SELECT Status,Address,CommunityId FROM dbo.ServiceOrder WHERE OrderNo='DEMO-ORDER-001-1'") == completed
            assert one("SELECT Status,Address FROM dbo.ServiceOrder WHERE OrderId=?", pending["OrderId"]) == {
                "Status": "CANCELLED", "Address": pending["Address"],
            }
            assert one("SELECT ClosedAt FROM dbo.ServiceDispatch WHERE OrderId=?", pending["OrderId"])["ClosedAt"]
            assert one("SELECT Status FROM dbo.CarePlan WHERE PlanNo='DEMO-PLAN-001'")["Status"] == "PAUSED"
        finally:
            db.rollback()


def test_ready_order_can_be_reassigned_to_a_second_eligible_worker(application, password):
    admin, alternate = application.test_client(), application.test_client()
    log_in(admin, "community02", password)
    log_in(alternate, "caregiver002", password)
    with application.app_context(), transaction() as db:
        try:
            order_id = one("""SELECT TOP (1) OrderId FROM dbo.ServiceOrder
                            WHERE OrderNo LIKE 'DEMO-BJ-REASSIGN-%' ORDER BY OrderId DESC""")["OrderId"]
            path = f"/services/orders/{order_id}"
            options = _panel(admin.get(path), "改派护工")
            assert "陈立新" in options and "林瑞霞" not in options
            worker = one("SELECT WorkerId FROM dbo.Worker WHERE WorkerNo='DEMO-WORKER-002'")["WorkerId"]
            assert submit(admin, path, operation="DISPATCH", worker_id=worker, reason="原护工临时请假").status_code == 302
            assert submit(alternate, path, operation="ACCEPT").status_code == 302
            records = query("""SELECT WorkerName,ClosedAt,CloseReason,AcceptedAt FROM dbo.v_ServiceDispatchHistory
                            WHERE OrderId=? ORDER BY DispatchId""", order_id)
            assert [record["WorkerName"] for record in records] == ["林瑞霞", "陈立新"]
            assert records[0]["ClosedAt"] and records[0]["CloseReason"] == "原护工临时请假"
            assert records[1]["AcceptedAt"] and records[1]["ClosedAt"] is None
        finally:
            db.rollback()


def test_order_pagination_keeps_old_orders_actionable(application, password):
    client = application.test_client()
    log_in(client, "community", password)
    insert = """
        INSERT dbo.ServiceOrder (
            OrderNo, ArchiveNo, PlanId, ServiceTypeId, CommunityId, Status, Price, AppointmentStart,
            AppointmentEnd, Address, Latitude, Longitude, Channel, DispatchDeadline
        )
        SELECT TOP ({limit}) CONCAT('QA-PAGE-',LEFT(CONVERT(varchar(36),NEWID()),18)),
            source.ArchiveNo,source.PlanId,source.ServiceTypeId,source.CommunityId,?,source.Price,
            source.AppointmentStart,source.AppointmentEnd,source.Address,source.Latitude,source.Longitude,
            source.Channel,source.DispatchDeadline
        FROM dbo.ServiceOrder source CROSS JOIN sys.all_objects
        WHERE source.OrderNo='DEMO-ORDER-001-3';
    """
    with application.app_context(), transaction() as db:
        try:
            item = one(insert.format(limit=1) + "SELECT CONVERT(int,SCOPE_IDENTITY()) AS OrderId;", "RESCHEDULE")
            order_id = item["OrderId"]
            execute(insert.format(limit=160), "NEW")
            order_link = rf'href="/services/orders/{order_id}[?"]'
            assert not re.search(order_link, _panel(client.get("/services/orders"), "服务订单"))
            assert re.search(order_link, _panel(client.get("/services/orders?page=6"), "服务订单"))
            path = "/services/orders?status=RESCHEDULE"
            page = client.get(path)
            assert re.search(order_link, _panel(page, "服务订单"))
            assert 'name="operation" value="CANCEL"' not in page.get_data(as_text=True)
            detail_path = f"/services/orders/{order_id}?status=RESCHEDULE"
            detail = client.get(detail_path)
            assert 'name="operation" value="CANCEL"' in _panel(detail, "取消预约")
            assert f'href="{path}"' in detail.get_data(as_text=True)
            response = submit(client, detail_path, operation="CANCEL", reason="分页测试取消")
            assert response.status_code == 302 and response.location == detail_path
            assert one("SELECT Status FROM dbo.ServiceOrder WHERE OrderId=?", order_id)["Status"] == "CANCELLED"
        finally:
            db.rollback()


def test_monthly_inspection_panel_respects_role_scope(application, password):
    agency, caregiver, supervisor = (application.test_client() for _ in range(3))
    for client, username in ((agency, "agency"), (caregiver, "caregiver"), (supervisor, "civil")):
        log_in(client, username, password)
    path = "/subsidy/quality"
    title = "护工月度抽查考核"
    for client in (agency, caregiver):
        panel = _panel(client.get(path), title)
        assert "王海燕" in panel and "陈立新" not in panel
    assert "机构月度抽查考核" not in caregiver.get(path).get_data(as_text=True)
    assert "清溪里居家养老服务站" in _panel(agency.get(path), "机构月度抽查考核")
    with application.app_context(), transaction() as db:
        try:
            execute("""UPDATE inspection SET ReviewDistrict=N'测试外辖区'
                    FROM dbo.ServiceInspection inspection JOIN dbo.Worker worker ON worker.WorkerId=inspection.WorkerId
                    WHERE worker.WorkerNo='DEMO-WORKER-002'""")
            panel = _panel(supervisor.get(path), title)
            assert "王海燕" in panel and "陈立新" not in panel
        finally:
            db.rollback()
