import re
from secrets import token_hex

import pytest

from kanglao.db import execute, one, query
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
