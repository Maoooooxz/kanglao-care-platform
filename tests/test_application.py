import re
from datetime import timedelta
from secrets import token_hex

import pytest

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


def test_reassessment_reminders_include_day_fourteen_and_only_local_archives(application, password):
    client = application.test_client()
    log_in(client, "community", password)
    today = beijing_today()
    with application.app_context(), transaction() as db:
        try:
            for archive_no in ("E0001", "E0005"):
                execute("EXEC dbo.usp_RecordAbilityAssessment ?,?,'ADL',75,N'轻度失能',N'边界测试',?,?",
                        f"QA-REMIND-{archive_no}", archive_no, today, today + timedelta(days=14))
            panel = _panel(client.get("/"), "待复评")
            assert "/archives/E0001" in panel and "/archives/E0005" not in panel
            assert (today + timedelta(days=14)).isoformat() in panel
            execute("UPDATE dbo.AbilityAssessment SET ValidThrough=? WHERE AssessmentNo='QA-REMIND-E0001'",
                    today + timedelta(days=15))
            assert "/archives/E0001" not in _panel(client.get("/"), "待复评")
            execute("UPDATE dbo.ElderArchive SET IsActive=0 WHERE ArchiveNo='E0001'")
            execute("UPDATE dbo.AbilityAssessment SET ValidThrough=? WHERE AssessmentNo='QA-REMIND-E0001'", today)
            assert "/archives/E0001" not in _panel(client.get("/"), "待复评")
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
            order_link = f'href="/services/orders/{order_id}"'
            assert order_link not in _panel(client.get("/services/orders"), "服务订单")
            assert order_link in _panel(client.get("/services/orders?page=6"), "服务订单")
            path = "/services/orders?status=RESCHEDULE"
            page = client.get(path)
            assert order_link in _panel(page, "服务订单")
            assert f'value="{order_id}"' in _panel(page, "取消预约")
            response = submit(client, path, operation="CANCEL", order_id=order_id, reason="分页测试取消")
            assert response.status_code == 302 and response.location == path
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
        assert "演示护工001" in panel and "演示护工002" not in panel
    assert "机构月度抽查考核" not in caregiver.get(path).get_data(as_text=True)
    assert "演示服务机构001" in _panel(agency.get(path), "机构月度抽查考核")
    with application.app_context(), transaction() as db:
        try:
            execute("""UPDATE inspection SET ReviewDistrict=N'测试外辖区'
                    FROM dbo.ServiceInspection inspection JOIN dbo.Worker worker ON worker.WorkerId=inspection.WorkerId
                    WHERE worker.WorkerNo='DEMO-WORKER-002'""")
            panel = _panel(supervisor.get(path), title)
            assert "演示护工001" in panel and "演示护工002" not in panel
        finally:
            db.rollback()
