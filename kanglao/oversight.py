from datetime import date, timedelta

from flask import Blueprint, abort, flash, g, redirect, request, url_for
from markupsafe import Markup

from .archive import bounded
from .db import execute, one, query
from .subsidy import INSPECTION_METHODS, INSPECTION_STATES
from .web import beijing_today, field, roles, workspace

bp = Blueprint("oversight", __name__, url_prefix="/oversight")


def _period(source):
    last_month = (beijing_today().replace(day=1) - timedelta(days=1)).replace(day=1)
    value = source.get("period", last_month.isoformat()[:7])
    if len(value) != 7:
        raise ValueError("请选择已结束的月份。")
    result = date.fromisoformat(f"{value}-01")
    if not date(2000, 1, 1) <= result <= last_month:
        raise ValueError("请选择已结束的月份。")
    return result


def _month(value):
    return value.isoformat()[:7]


def _rate(closed, required):
    return f"{closed / required:.1%}" if required else "不适用"


def _score(total, count):
    return f"{total / count:.2f}" if count else "不适用"


@bp.route("/sampling", methods=["GET", "POST"])
@roles("street", "civil")
def sampling():
    actor = g.user
    period = _period(request.form if request.method == "POST" else request.args)
    if request.method == "POST":
        operation = request.form["operation"]
        if operation == "create":
            execute("EXEC dbo.usp_CreateInspectionBatch ?,?,?", actor["id"], period, int(request.form["sample_rate"]))
            flash("抽查批次已就绪；同月已有批次时沿用原样本。", "success")
            return redirect(url_for("oversight.sampling", period=_month(period)))

    batch = one("""SELECT batch.BatchId,batch.SampleRate,batch.PopulationCount,batch.TargetCount,published.PublishedAt
                 FROM dbo.InspectionBatch batch LEFT JOIN dbo.InspectionPublication published ON published.BatchId=batch.BatchId
                 WHERE batch.ReviewDistrict=? AND batch.PeriodMonth=?""", actor["district"], period)
    if request.method == "POST":
        if batch is None:
            abort(404)
        if operation == "inspect":
            execute("EXEC dbo.usp_RegisterSampleInspection ?,?,?,?,?,?,?,?", actor["id"], batch["BatchId"],
                    int(request.form["order_id"]), int(request.form["score"]),
                    bounded(request.form.get("finding", ""), 250), request.form.get("inspection_method"),
                    bounded(request.form.get("issue_tag", ""), 60, optional=True),
                    bounded(request.form.get("correction_requirement", ""), 250, optional=True))
            flash("样本检查已登记。", "success")
        elif operation == "publish":
            if actor["role"] != "civil":
                abort(403)
            execute("EXEC dbo.usp_PublishInspectionBatch ?,?", actor["id"], batch["BatchId"])
            flash("批次结果已公示。", "success")
        else:
            abort(400)
        return redirect(url_for("oversight.sampling", period=_month(period)))

    batches = query("""SELECT PeriodMonth,SampleRate,PopulationCount,TargetCount FROM dbo.InspectionBatch
                    WHERE ReviewDistrict=? ORDER BY PeriodMonth DESC""", actor["district"])
    panels = [{
        "title": "辖区抽查批次",
        "form": [field("period", "已结束的服务月份", "month", value=_month(period)),
                 field("sample_rate", "抽查比例（%）", "number", value=10, min=1, max=100)],
        "hidden": {"operation": "create"},
        "submit": "生成或打开抽查批次",
        "columns": ["月份", "比例", "完成订单总体", "样本数"],
        "rows": [(_month(row["PeriodMonth"]), f'{row["SampleRate"]}%', row["PopulationCount"], row["TargetCount"])
                 for row in batches],
        "row_links": [url_for("oversight.sampling", period=_month(row["PeriodMonth"])) for row in batches],
    }]
    if batch:
        samples = query("""SELECT OrderId,OrderNo,ServiceName,InspectionId,Score,Status FROM dbo.v_InspectionSampleOrder
                          WHERE BatchId=? ORDER BY OrderId""", batch["BatchId"])
        pending = [(row["OrderId"], row["OrderNo"] or f'#{row["OrderId"]}') for row in samples if not row["InspectionId"]]
        panels.append({
            "title": f"{_month(period)} 抽查样本",
            "text": f'已检查 {len(samples) - len(pending)}／{batch["TargetCount"]} 笔'
                    + (" · 已公示" if batch["PublishedAt"] else " · 未公示"),
            "columns": ["订单", "服务", "检查单", "得分", "状态"],
            "rows": [(row["OrderNo"] or f'#{row["OrderId"]}', row["ServiceName"],
                      Markup('<a href="{}">#{} 查看</a>').format(
                          url_for("subsidy.inspection", inspection_id=row["InspectionId"]), row["InspectionId"])
                      if row["InspectionId"] else None, row["Score"], INSPECTION_STATES.get(row["Status"], "待抽查"))
                     for row in samples],
        })
        if pending:
            panels.append({
                "title": "登记样本检查",
                "form": [
                    field("order_id", "抽样订单", "select", pending),
                    field("inspection_method", "抽查方式", "select", INSPECTION_METHODS.items()),
                    field("issue_tag", "问题标签", required=False, maxlength=60),
                    field("score", "评分", "number", min=0, max=100),
                    field("finding", "检查结论", "textarea"),
                    field("correction_requirement", "整改要求（低于 60 分必填）", "textarea", required=False),
                ],
                "hidden": {"operation": "inspect", "period": _month(period)}, "submit": "保存检查",
            })
        elif not batch["PublishedAt"] and actor["role"] == "civil":
            panels.append({
                "title": "发布结果", "text": "公示仅展示辖区汇总，不包含个人、订单或检查内容。",
                "form": [], "hidden": {"operation": "publish", "period": _month(period)}, "submit": "发布公示",
            })
    return workspace("按比例抽查", f'{actor["district"]} · 以已结束的服务月份为准', panels)


@bp.get("/bulletins")
@roles()
def bulletins():
    published = query("""SELECT ReviewDistrict,PeriodMonth,InspectionCount,ScoreTotal,RequiredCount,ClosedCount,PublishedAt
                       FROM dbo.v_InspectionPublicSummary ORDER BY PeriodMonth DESC,ReviewDistrict""")
    return workspace("抽查结果公示", "仅公开已发布的辖区汇总，不含个人和订单明细。", [{
        "title": "已发布结果",
        "columns": ["辖区", "服务月份", "抽查数量", "平均分", "整改结案率", "发布时间"],
        "rows": [(row["ReviewDistrict"], _month(row["PeriodMonth"]), row["InspectionCount"],
                  _score(row["ScoreTotal"], row["InspectionCount"]), _rate(row["ClosedCount"], row["RequiredCount"]),
                  row["PublishedAt"]) for row in published],
    }])


@bp.route("/assessments", methods=["GET", "POST"])
@roles("agency", "street", "civil")
def assessments():
    actor = g.user
    is_agency = actor["role"] == "agency"
    if request.method == "POST":
        operation = request.form["operation"]
        if is_agency and operation == "submit":
            execute("EXEC dbo.usp_SubmitAgencyAssessment ?,?", actor["id"], _period(request.form))
            flash("机构考核材料已留档；同月重复提交不覆盖原材料。", "success")
        elif not is_agency and operation == "review":
            execute("EXEC dbo.usp_ReviewAgencyAssessment ?,?,?", actor["id"], int(request.form["submission_id"]),
                    bounded(request.form.get("note", ""), 250))
            flash("考核意见已保存。", "success")
        else:
            abort(403)
        return redirect(url_for("oversight.assessments"))

    predicate, value = ("record.AgencyId", actor["agency_id"]) if is_agency else ("record.District", actor["district"])
    records = query(f"""SELECT record.*,agency.Name,submitter.DisplayName AS SubmittedName,reviewer.DisplayName AS ReviewedName
        FROM dbo.AgencyAssessmentSubmission record JOIN dbo.Agency agency ON agency.AgencyId=record.AgencyId
        JOIN dbo.AppUser submitter ON submitter.UserId=record.SubmittedBy
        LEFT JOIN dbo.AppUser reviewer ON reviewer.UserId=record.ReviewedBy
        WHERE {predicate}=? ORDER BY record.PeriodMonth DESC,record.SubmissionId DESC""", value)
    panels = [{
        "title": "已提交材料",
        "columns": ["材料", "机构", "月份", "有效分钟", "投诉数", "抽查数", "抽查平均分", "整改结案率",
                    "提交人", "提交时间", "审阅人", "审阅时间", "考核意见"],
        "rows": [(f'#{row["SubmissionId"]}', row["Name"], _month(row["PeriodMonth"]), row["EffectiveMinutes"],
                  row["ComplaintCount"], row["InspectionCount"], _score(row["ScoreTotal"], row["InspectionCount"]),
                  _rate(row["ClosedCount"], row["RequiredCount"]), row["SubmittedName"], row["SubmittedAt"],
                  row["ReviewedName"], row["ReviewedAt"], row["ReviewNote"] or "待审阅") for row in records],
    }]
    if is_agency:
        panels.append({"title": "提交系统生成材料", "form": [field("period", "已结束月份", "month", value=_month(_period({})))],
                       "hidden": {"operation": "submit"}, "submit": "提交月度考核"})
    else:
        pending = [(row["SubmissionId"], f'{row["Name"]} · {_month(row["PeriodMonth"])}')
                   for row in records if not row["ReviewedAt"]]
        if pending:
            panels.append({"title": "填写考核意见", "form": [field("submission_id", "待审阅材料", "select", pending),
                           field("note", "考核意见", "textarea")], "hidden": {"operation": "review"}, "submit": "保存意见"})
    return workspace("机构考核材料", "按月留档抽查、整改、投诉和有效工时。", panels)
