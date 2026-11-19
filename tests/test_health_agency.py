from conftest import log_in, submit


def test_agency_health_is_scoped_and_read_only(application, password):
    client = application.test_client()
    log_in(client, "agency", password)
    response = client.get("/health/")

    assert response.status_code == 200
    page = response.get_data(as_text=True)
    assert "E0001" in page
    assert "E0019" not in page
    assert 'action="/health/events/open"' not in page
    assert 'action="/health/notices/read"' not in page

    assert submit(client, "/health/events/open", archive_no="E0001", source_type="SOS").status_code == 403
    assert submit(client, "/health/notices/read", notice_id="1").status_code == 403
