from datetime import timedelta
from secrets import token_hex

from conftest import log_in, submit
from kanglao.db import one, transaction
from kanglao.web import beijing_today


def _last_month():
    return (beijing_today().replace(day=1) - timedelta(days=1)).replace(day=1)


def test_sampling_publication_and_assessment_pages(application, password):
    regulator, street, manager, family = (application.test_client() for _ in range(4))
    for client, username in ((regulator, "civil"), (street, "street"), (manager, "agency"), (family, "family")):
        log_in(client, username, password)
    output = "/oversight/bulletins"
    assert application.test_client().get(output).status_code == 302
    published = family.get(output).get_data(as_text=True)
    assert "课设抽查演示区" in published
    for private in ("E0001", "DEMO-COURSE-", "孟秋华", "郑思雨", "合成服务记录核查通过"):
        assert private not in published
    assert family.get("/oversight/sampling").status_code == 403

    period = _last_month()
    form_month = period.isoformat()[:7]
    sampling = f"/oversight/sampling?period={form_month}"
    with application.app_context(), transaction() as db:
        try:
            assert submit(street, sampling, operation="create", period=form_month, sample_rate="1").status_code == 302
            batch = one("""SELECT batch.BatchId,batch.ReviewDistrict,sample.OrderId,sample.InspectionId
                         FROM dbo.InspectionBatch batch JOIN dbo.v_InspectionSampleOrder sample ON sample.BatchId=batch.BatchId
                         JOIN dbo.AppUser actor ON actor.District=batch.ReviewDistrict
                         WHERE actor.Username='street' AND batch.PeriodMonth=?""", period)
            assert batch is not None and batch["ReviewDistrict"] not in family.get(output).get_data(as_text=True)
            assert submit(street, sampling, operation="publish", period=form_month).status_code == 403
            if not batch["InspectionId"]:
                response = submit(street, sampling, operation="inspect", period=form_month, order_id=batch["OrderId"],
                                  inspection_method="VISIT", score=85, finding="验收检查结果")
                assert response.status_code == 302
            assert "发布公示" in regulator.get(sampling).get_data(as_text=True)
            assert submit(regulator, sampling, operation="publish", period=form_month).status_code == 302
            shared = family.get(output).get_data(as_text=True)
            assert batch["ReviewDistrict"] in shared and "验收检查结果" not in shared

            assessments = "/oversight/assessments"
            assert "兰溪园养老服务站" not in regulator.get(assessments).get_data(as_text=True)
            assert submit(manager, assessments, operation="submit", period=form_month).status_code == 302
            record = one("""SELECT record.SubmissionId FROM dbo.AgencyAssessmentSubmission record
                          JOIN dbo.AppUser actor ON actor.AgencyId=record.AgencyId
                          WHERE actor.Username='agency' AND record.PeriodMonth=?""", period)
            assert record is not None
            response = submit(regulator, assessments, operation="review", submission_id=record["SubmissionId"],
                              note="验收考核意见")
            assert response.status_code == 302
            mine = manager.get(assessments).get_data(as_text=True)
            assert "验收考核意见" in mine and "兰溪园养老服务站" not in mine
        finally:
            db.rollback()


def test_device_binding_and_environment_report_pages(application, password):
    community, caregiver, family, supervisor = (application.test_client() for _ in range(4))
    for client, username in ((community, "community"), (caregiver, "caregiver"), (family, "family"),
                             (supervisor, "street")):
        log_in(client, username, password)
    device_code = "QA-ECG-" + token_hex(5)
    request_key = "QA-HOME-RISK-" + token_hex(6)
    with application.app_context(), transaction() as db:
        try:
            assert submit(community, "/health/devices/register", device_code=device_code,
                          device_type="ECG_PATCH", archive_no="E0001", location="验收心电贴位置").status_code == 302
            binding = one("SELECT InstallationLocation,DeviceType FROM dbo.v_HealthDeviceBindings WHERE DeviceCode=?",
                          device_code)
            assert binding == {"InstallationLocation": "验收心电贴位置", "DeviceType": "ECG_PATCH"}
            assert "验收心电贴位置" in community.get("/health/").get_data(as_text=True)

            result = submit(caregiver, "/health/events/open", archive_no="E0001", request_key=request_key,
                            source_type="HOME_RISK", report_text="验收：通道堆物")
            assert result.status_code == 302
            report = one("SELECT ReportKind,ReportText FROM dbo.HealthEvent WHERE RequestKey=?", request_key)
            assert report == {"ReportKind": "HOME_RISK", "ReportText": "验收：通道堆物"}
            assert "验收：通道堆物" in family.get("/health/").get_data(as_text=True)
            assert "辖区预警响应" in supervisor.get("/health/").get_data(as_text=True)
        finally:
            db.rollback()
