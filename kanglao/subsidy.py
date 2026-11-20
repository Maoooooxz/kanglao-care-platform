"""Monthly subsidy claims, district review, and service inspections."""

import json
from decimal import Decimal, InvalidOperation

from flask import Blueprint, abort, flash, g, redirect, request, url_for
from markupsafe import Markup

from .archive import ABILITY_LEVELS, SUBSIDY_CATEGORIES, bounded
from .db import execute, one, query
from .web import field, roles, workspace

bp = Blueprint("subsidy", __name__, url_prefix="/subsidy")
CLAIM_STATES = {
    "DRAFT": "草稿",
    "STREET": "待街道审核",
    "CIVIL": "待民政审核",
    "RETURNED": "已退回",
    "APPROVED": "待拨付",
    "PAID": "已拨付",
}
INSPECTION_STATES = {"OPEN": "待整改", "CORRECTED": "待复查", "CLOSED": "已结案"}
INSPECTION_METHODS = {"PHONE": "电话回访", "VISIT": "上门核查"}
POLICY_CATEGORIES = {"ANY": "通用", **SUBSIDY_CATEGORIES}


def _money(value):
    return f"¥{value:,.2f}"


def _link(endpoint, label, **params):
    return Markup('<a href="{}">{}</a>').format(url_for(endpoint, **params), label)


def _claim_scope():
    role = g.user["role"]
    if role == "community":
        return "CommunityId = ?", g.user["community_id"]
    if role in ("family", "resident"):
        return "ArchiveNo = ?", g.user["archive_no"]
    return "District = ?", g.user["district"]


def _inspection_scope():
    role = g.user["role"]
    if role == "agency":
        return "AgencyId = ?", g.user["agency_id"]
    if role == "caregiver":
        return "WorkerId = ?", g.user["worker_id"]
    return "ReviewDistrict = ?", g.user["district"]


def _eligible_orders(claim=None):
    conditions = ""
    params = [g.user["community_id"]]
    if claim:
        conditions = "AND visit.ArchiveNo = ? AND visit.ServiceTypeId = ? AND visit.PeriodMonth = ?"
        params.extend([claim["ArchiveNo"], claim["ServiceTypeId"], claim["PeriodMonth"]])
    return query(f"""
        SELECT visit.OrderId, visit.ArchiveNo, visit.ServiceTypeId, visit.CommunityId, service.Name,
               visit.PeriodMonth, visit.Price, visit.EffectiveMinutes
        FROM dbo.v_SubsidyApplicableOrder visit
        JOIN dbo.ServiceType service ON service.ServiceTypeId = visit.ServiceTypeId
        WHERE visit.CommunityId = ?
          AND NOT EXISTS (
              SELECT 1 FROM dbo.SubsidyClaim existing
              WHERE existing.ArchiveNo = visit.ArchiveNo AND existing.ServiceTypeId = visit.ServiceTypeId
                 AND existing.PeriodMonth = visit.PeriodMonth
                 AND (existing.Status <> 'RETURNED' OR existing.CommunityId <> visit.CommunityId)
          )
          {conditions}
        ORDER BY visit.PeriodMonth DESC, visit.ArchiveNo, service.Name, visit.OrderId
    """, *params)


def _order_choice(order):
    return (
        order["OrderId"],
        f'订单 #{order["OrderId"]} · {order["ArchiveNo"]} · '
        f'{order["Name"]} · {order["PeriodMonth"]:%Y-%m} · {order["EffectiveMinutes"]} 分钟',
    )


def _order_form(claim=None, selected=None):
    choices = [_order_choice(order) for order in _eligible_orders(claim)]
    if not choices:
        return {"title": "申报订单", "text": "当前没有符合申报条件的订单。"}

    return {
        "title": "修改并重新提交" if claim else "提交补贴申报",
        "text": "选择同一老人、同一项目、同一自然月的订单。系统会按有效工时及适用政策核算金额。",
        "form": [
            field("order_ids", "可申报订单", "multiselect", options=choices, value=selected or []),
        ],
        "submit": "提交街道审核",
        "hidden": {"operation": "submit"},
    }


def _submit(claim=None):
    if g.user["role"] != "community":
        abort(403)

    try:
        selected = [int(order_id) for order_id in request.form.getlist("order_ids")]
    except ValueError:
        flash("请选择可申报的订单。", "error")
        return False

    if not selected:
        flash("请至少选择一笔订单。", "error")
        return False

    eligible = {order["OrderId"]: order for order in _eligible_orders(claim)}
    if any(order_id not in eligible for order_id in selected):
        flash("订单已不可申报，请重新选择。", "error")
        return False

    first = eligible[selected[0]]
    execute(
        "EXEC dbo.usp_SubmitSubsidyClaim ?, ?, ?, ?, ?, ?",
        g.user["id"], first["ArchiveNo"], first["CommunityId"], first["ServiceTypeId"],
        first["PeriodMonth"], json.dumps(selected),
    )
    flash("申报已提交至街道审核。", "success")
    return True


@bp.route("/", methods=["GET", "POST"])
@roles("community", "family", "resident", "agency", "caregiver", "street", "civil")
def index():
    if g.user["role"] in ("agency", "caregiver") and request.method == "GET":
        return redirect(url_for("subsidy.quality"))
    if request.method == "POST":
        _submit()
        return redirect(url_for("subsidy.index"))

    where, value = _claim_scope()
    page = max(1, request.args.get("page", 1, type=int))
    size = 25
    claims = query(f"""
        SELECT ClaimId, ArchiveNo, FullName, ServiceName, PeriodMonth, Status, TotalAmount, OrderCount
        FROM dbo.v_SubsidyClaimSummary WHERE {where}
        ORDER BY ClaimId DESC OFFSET ? ROWS FETCH NEXT ? ROWS ONLY
    """, value, (page - 1) * size, size + 1)

    navigation = []
    if page > 1:
        navigation.append(_link("subsidy.index", "上一页", page=page - 1))
    if len(claims) > size:
        navigation.append(_link("subsidy.index", "下一页", page=page + 1))

    panels = [{
        "title": "补贴申报记录",
        "text": Markup(" · ").join(navigation),
        "columns": ["申报单", "老人", "项目", "服务月份", "订单数", "金额", "状态"],
        "rows": [
            (_link("subsidy.detail", f'申报 #{row["ClaimId"]}', claim_id=row["ClaimId"]), row["FullName"],
             row["ServiceName"], f'{row["PeriodMonth"]:%Y-%m}', row["OrderCount"],
             _money(row["TotalAmount"]), CLAIM_STATES[row["Status"]])
            for row in claims[:size]
        ],
        "actions": [("抽查结果公示", url_for("oversight.bulletins"))],
    }]
    if g.user["role"] == "community":
        panels.append(_order_form())
    if g.user["role"] in ("street", "civil"):
        panels[0]["actions"].extend([("补贴政策", url_for("subsidy.policies")),
                                     ("质量抽查和服务覆盖", url_for("subsidy.quality"))])
    return workspace("补贴申报", "按月归集服务，保留核算和审核记录", panels)


@bp.route("/<int:claim_id>", methods=["GET", "POST"])
@roles("community", "family", "resident", "street", "civil")
def detail(claim_id):
    where, value = _claim_scope()
    claim = one(f"SELECT * FROM dbo.v_SubsidyClaimSummary WHERE ClaimId = ? AND {where}", claim_id, value)
    if claim is None:
        abort(404)

    role, status = g.user["role"], claim["Status"]
    can_resubmit = role == "community" and status == "RETURNED"
    can_review = (role, status) in (("street", "STREET"), ("civil", "CIVIL"))
    can_pay = (role, status) == ("civil", "APPROVED")
    if request.method == "POST":
        if request.form.get("operation") == "submit" and can_resubmit:
            _submit(claim)
        elif request.form.get("operation") == "review" and (can_review or can_pay):
            action = request.form.get("action", "")
            if action not in ("approve", "return", "pay"):
                abort(400)
            execute(
                "EXEC dbo.usp_ProgressSubsidyClaim ?, ?, ?, ?",
                g.user["id"], claim_id, action, request.form.get("note", "").strip(),
            )
            flash("申报状态已更新。", "success")
        else:
            abort(403)
        return redirect(url_for("subsidy.detail", claim_id=claim_id))

    lines = query("SELECT * FROM dbo.v_SubsidyClaimTrace WHERE ClaimId = ? ORDER BY OrderId", claim_id)
    show_archive = role in ("community", "street", "civil")
    history = query(f"""
        SELECT log.CurrentStatus, log.ChangedAt, log.Note, log.TotalAmount, log.OrderSnapshot,
               {"log.EvidenceSnapshot" if show_archive else "NULL"} AS EvidenceSnapshot,
               actor.DisplayName
        FROM dbo.SubsidyClaimLog log LEFT JOIN dbo.AppUser actor ON actor.UserId = log.ActorId
        WHERE log.ClaimId = ? ORDER BY log.LogId DESC
    """, claim_id)
    panels = [{
        "title": "订单和核算依据",
        "text": f'{claim["FullName"]} · {claim["ServiceName"]} · {claim["PeriodMonth"]:%Y-%m} · '
                f'{CLAIM_STATES[status]} · {_money(claim["TotalAmount"])}',
        "columns": ["服务订单", "适用政策", "对象类别", "能力等级", "有效分钟", "订单金额", "每小时标准", "每单上限",
                    "补贴金额", "自付金额"],
        "rows": [(f'#{line["OrderId"]}', f'{line["PolicyName"]} (#{line["PolicyId"]})',
                  SUBSIDY_CATEGORIES.get(line["SubsidyCategory"], "未记录"), line["SubsidyAbilityLevel"] or "未记录",
                  line["EffectiveMinutes"], _money(line["OrderPrice"]),
                  _money(line["HourlyRate"]), _money(line["MaxPerOrder"]),
                  _money(line["Amount"]) if status in ("APPROVED", "PAID") else f'待核定（申报 {_money(line["Amount"])}）',
                  _money(line["OrderPrice"] - line["Amount"]) if status in ("APPROVED", "PAID") else "待核定")
                 for line in lines],
    }, {
        "title": "审核和修改记录",
        "columns": ["状态", "操作者", "时间（UTC）", "说明", "申报金额", "当时的订单及金额"],
        "rows": [(CLAIM_STATES[row["CurrentStatus"]], row["DisplayName"] or "演示初始化", row["ChangedAt"],
                  row["Note"], _money(row["TotalAmount"]),
                  "、".join(f'#{item["OrderId"]} {_money(item["Amount"])}'
                           for item in json.loads(row["OrderSnapshot"], parse_float=Decimal))) for row in history],
    }]
    if show_archive:
        evidence_rows = []
        for entry in history:
            if entry["CurrentStatus"] != "STREET":
                continue
            evidence = json.loads(entry["EvidenceSnapshot"], parse_float=Decimal) if entry["EvidenceSnapshot"] else []
            if not evidence:
                evidence_rows.append((entry["ChangedAt"], entry["DisplayName"], "历史证明未记录",
                                      None, None, None, None))
            for item in evidence:
                signer = item.get("SignerName")
                if not signer and item.get("ConfirmedBy") is not None:
                    label = {"resident": "老人本人", "family": "家属"}.get(item.get("SignerRole"), "签字人")
                    signer = f'{label} #{item["ConfirmedBy"]}'
                evidence_rows.append((entry["ChangedAt"], entry["DisplayName"], item["OrderNo"] or f'#{item["OrderId"]}',
                                      signer or "未记录", item["ConfirmedAt"], item["EffectiveMinutes"], _money(item["Amount"])))
        panels.append({"title": "申报证明归档", "text": "每次提交保留一份独立证明。",
                       "columns": ["归档时间", "经办人", "订单", "签字人", "签字时间（UTC）", "有效分钟", "补贴金额"],
                       "rows": evidence_rows})
    if can_resubmit:
        panels.append(_order_form(claim, [row["OrderId"] for row in lines]))
    if can_review or can_pay:
        actions = [("approve", "审核通过"), ("return", "退回修改")] if can_review else [("pay", "模拟拨付")]
        panels.append({
            "title": "处理申报",
            "form": [field("action", "审核操作", "select", options=actions),
                     field("note", "备注或退回原因", "textarea", required=False)],
            "submit": "确认操作",
            "hidden": {"operation": "review"},
        })
    return workspace(f"补贴申报 #{claim_id}", "核算明细与审核留痕", panels)


@bp.route("/policies", methods=["GET", "POST"])
@roles("street", "civil")
def policies():
    district = g.user["district"]
    if request.method == "POST":
        if g.user["role"] != "civil":
            abort(403)
        category = request.form.get("beneficiary_category", "")
        ability_level = request.form.get("ability_level", "")
        if category not in POLICY_CATEGORIES or ability_level not in ("通用", *ABILITY_LEVELS):
            raise ValueError("请选择有效的适用对象和能力等级")
        try:
            hourly_rate = Decimal(request.form.get("hourly_rate", ""))
            max_per_order = Decimal(request.form.get("max_per_order", ""))
            if not (hourly_rate.is_finite() and max_per_order.is_finite() and hourly_rate > 0 and max_per_order > 0):
                raise ValueError()
            service_id = int(request.form["service_type_id"])
        except (ValueError, InvalidOperation):
            flash("请填写有效的项目和正数费率。", "error")
            return redirect(url_for("subsidy.policies"))
        execute(
            "EXEC dbo.usp_SaveSubsidyPolicy ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?",
            g.user["id"], request.form["name"].strip(), district, service_id,
            request.form["valid_from"], request.form["valid_through"], hourly_rate, max_per_order,
            int(request.form.get("close_previous") == "1"), category, ability_level,
        )
        flash("补贴政策已添加。", "success")
        return redirect(url_for("subsidy.policies"))

    items = query("""
        SELECT policy.PolicyName, service.Name, policy.ValidFrom, policy.ValidThrough,
               policy.HourlyRate, policy.MaxPerOrder, policy.BeneficiaryCategory, policy.AbilityLevel
        FROM dbo.SubsidyPolicy policy JOIN dbo.ServiceType service ON service.ServiceTypeId = policy.ServiceTypeId
        WHERE policy.District = ? ORDER BY policy.ValidFrom DESC, policy.PolicyId DESC
    """, district)
    panels = [{
        "title": "辖区补贴政策",
        "columns": ["政策", "服务项目", "适用对象", "能力等级", "起始日", "截止日", "每小时标准", "每单上限"],
        "rows": [(row["PolicyName"], row["Name"], POLICY_CATEGORIES[row["BeneficiaryCategory"]],
                  row["AbilityLevel"], row["ValidFrom"], row["ValidThrough"],
                  _money(row["HourlyRate"]), _money(row["MaxPerOrder"])) for row in items],
    }]
    if g.user["role"] == "civil":
        types = query("SELECT ServiceTypeId, Name FROM dbo.ServiceType ORDER BY Name")
        panels.append({
            "title": "新增政策版本",
            "text": "先匹配具体对象，再匹配具体等级，无更具体政策时使用通用标准。",
            "form": [field("name", "政策名称"),
                     field("service_type_id", "服务项目", "select",
                           options=[(row["ServiceTypeId"], row["Name"]) for row in types]),
                     field("beneficiary_category", "适用对象", "select", POLICY_CATEGORIES.items(), value="ANY"),
                     field("ability_level", "能力等级", "select",
                           [(level, level) for level in ("通用", *ABILITY_LEVELS)], value="通用"),
                     field("valid_from", "起始日", "date"),
                     field("valid_through", "截止日", "date"),
                     field("hourly_rate", "每小时标准（元）"),
                     field("max_per_order", "每单上限（元）"),
                     field("close_previous", "政策版本关系", "select",
                           options=[("0", "新增独立有效期"), ("1", "接续旧政策并结束旧有效期")])],
            "submit": "添加政策",
        })
    return workspace("补贴政策", f"{district} · 按自然月结算，政策按服务完成日期适用", panels)


def _monthly_inspection_panel(where, value, *, agency=False):
    label = "机构" if agency else "护工"
    group = "AgencyId, AgencyName" if agency else "WorkerId, WorkerName"
    name = "AgencyName" if agency else "WorkerName"
    results = query(f"""
        SELECT InspectionMonth, {name} AS EntityName, SUM(InspectionCount) AS Inspections,
               SUM(ScoreTotal) AS ScoreTotal, SUM(RequiredCount) AS Required, SUM(ClosedCount) AS Closed
        FROM dbo.v_MonthlyInspectionResults
        WHERE {where}
        GROUP BY InspectionMonth, {group}
        ORDER BY InspectionMonth DESC, {name}, {"AgencyId" if agency else "WorkerId"}
    """, value)
    return {
        "title": f"{label}月度抽查考核",
        "text": "按抽查月份汇总；整改结案率只统计要求整改的抽查。",
        "columns": ["月份", label, "抽查次数", "平均分", "整改结案率"],
        "rows": [(row["InspectionMonth"], row["EntityName"], row["Inspections"],
                  f'{row["ScoreTotal"] / row["Inspections"]:.2f}',
                  f'{row["Closed"] / row["Required"]:.1%}' if row["Required"] else "不适用")
                 for row in results],
    }


@bp.route("/quality", methods=["GET", "POST"])
@roles("agency", "caregiver", "street", "civil")
def quality():
    role = g.user["role"]
    regulator = role in ("street", "civil")
    if request.method == "POST":
        if not regulator:
            abort(403)
        target_type = request.form["target_type"]
        if target_type not in ("order", "worker"):
            abort(400)
        try:
            target_id = int(request.form["target_id"])
            score = int(request.form["score"])
        except ValueError:
            flash("请选择检查对象并填写整数评分。", "error")
            return redirect(url_for("subsidy.quality"))
        execute(
            "EXEC dbo.usp_RegisterInspection ?, ?, ?, ?, ?, ?, ?, ?",
            g.user["id"], target_type, target_id, score, request.form["finding"].strip(),
            request.form["inspection_method"], bounded(request.form.get("issue_tag", ""), 60, optional=True),
            bounded(request.form.get("correction_requirement", ""), 250, optional=True),
        )
        flash("质量抽查已登记。", "success")
        return redirect(url_for("subsidy.quality"))

    where, value = _inspection_scope()
    inspections = query(f"""
        SELECT InspectionId, OrderId, WorkerName, AgencyName, Score, Status, InspectedAt, InspectionMethod, IssueTag
        FROM dbo.v_QualityInspectionSummary WHERE {where} ORDER BY InspectionId DESC
    """, value)
    panels = [{
        "title": "质量抽查与整改",
        "columns": ["检查单", "服务订单", "护工", "机构", "方式", "问题标签", "得分", "状态", "检查时间"],
        "rows": [(_link("subsidy.inspection", f'抽查 #{row["InspectionId"]}', inspection_id=row["InspectionId"]),
                   row["OrderId"] or "护工专项", row["WorkerName"], row["AgencyName"],
                   INSPECTION_METHODS.get(row["InspectionMethod"], "未记录"), row["IssueTag"] or "未记录",
                  row["Score"], INSPECTION_STATES[row["Status"]], row["InspectedAt"]) for row in inspections],
    }]
    panels.append(_monthly_inspection_panel(where, value))
    if role != "caregiver":
        panels.append(_monthly_inspection_panel(where, value, agency=True))
    panels.append({
        "title": "抽查与考核入口",
        "links": [("抽查结果公示", url_for("oversight.bulletins"))]
                 + ([("机构考核材料", url_for("oversight.assessments"))] if role != "caregiver" else [])
                 + ([("按比例抽查", url_for("oversight.sampling"))] if regulator else []),
    })
    if regulator:
        combined = query("""
            SELECT TOP (100) orders.OrderId, worker.Name AS WorkerName, community.Name AS CommunityName
            FROM dbo.ServiceOrder orders
            JOIN dbo.ServiceVisit visit ON visit.OrderId = orders.OrderId
            JOIN dbo.Worker worker ON worker.WorkerId = visit.WorkerId
            JOIN dbo.Community community ON community.CommunityId = orders.CommunityId
            WHERE community.District = ? AND orders.Status = 'COMPLETED'
            ORDER BY visit.CheckOutAt DESC, orders.OrderId DESC
        """, value)
        workers = query("""
            SELECT worker.WorkerId, worker.Name, agency.Name AS AgencyName FROM dbo.Worker worker
            JOIN dbo.Agency agency ON agency.AgencyId = worker.AgencyId WHERE agency.District = ?
            ORDER BY agency.Name, worker.Name
        """, value)
        for target, title, choices in (
            ("order", "按订单抽查", [(row["OrderId"], f'#{row["OrderId"]} · {row["WorkerName"]} · {row["CommunityName"]}')
                                for row in combined]),
            ("worker", "按护工抽查", [(row["WorkerId"], f'{row["Name"]} · {row["AgencyName"]}') for row in workers]),
        ):
            if choices:
                panels.append({
                    "title": title,
                    "form": [field("target_id", "检查对象", "select", options=choices),
                             field("inspection_method", "抽查方式", "select", INSPECTION_METHODS.items()),
                             field("issue_tag", "问题标签", required=False, maxlength=60),
                             field("score", "评分（0 至 100）", "number"),
                             field("finding", "检查结论", "textarea"),
                             field("correction_requirement", "整改要求（低于 60 分必填）", "textarea", required=False)],
                    "submit": "登记抽查",
                    "hidden": {"target_type": target},
                })
        coverage = query("""
            SELECT CommunityName, ElderCount, ServedElderCount, CompletedOrderCount
            FROM dbo.v_DistrictServiceCoverage WHERE District = ? ORDER BY CommunityName
        """, value)
        panels.append({
            "title": "辖区服务覆盖",
            "columns": ["社区", "有效档案", "已服务老人", "完成订单", "覆盖率"],
            "rows": [(row["CommunityName"], row["ElderCount"], row["ServedElderCount"], row["CompletedOrderCount"],
                      f'{row["ServedElderCount"] / row["ElderCount"]:.1%}' if row["ElderCount"] else "0%")
                     for row in coverage],
        })
    return workspace("质量监管", "登记抽查，跟进机构整改与服务覆盖", panels)


@bp.route("/quality/<int:inspection_id>", methods=["GET", "POST"])
@roles("agency", "caregiver", "street", "civil")
def inspection(inspection_id):
    where, value = _inspection_scope()
    item = one(f"SELECT * FROM dbo.v_QualityInspectionSummary WHERE InspectionId = ? AND {where}",
               inspection_id, value)
    if item is None:
        abort(404)

    role, status = g.user["role"], item["Status"]
    can_correct = role == "agency" and status == "OPEN"
    can_close = role in ("street", "civil") and status == "CORRECTED"
    if request.method == "POST":
        if not (can_correct or can_close):
            abort(403)
        action = "correct" if can_correct else request.form.get("review")
        if action not in ("correct", "close", "reopen"):
            abort(400)
        execute("EXEC dbo.usp_ProgressInspection ?, ?, ?, ?", g.user["id"], inspection_id,
                action, request.form.get("correction", "").strip())
        flash("整改状态已更新。", "success")
        return redirect(url_for("subsidy.inspection", inspection_id=inspection_id))

    history = query("""
        SELECT log.CurrentStatus, log.ChangedAt, log.Correction, actor.DisplayName
        FROM dbo.ServiceInspectionLog log LEFT JOIN dbo.AppUser actor ON actor.UserId = log.ActorId
        WHERE log.InspectionId = ? ORDER BY log.LogId DESC
    """, inspection_id)
    panels = [{
        "title": "检查结论",
        "text": item["Finding"],
        "columns": ["护工", "机构", "抽查方式", "问题标签", "评分", "状态", "整改要求", "整改内容"],
        "rows": [(item["WorkerName"], item["AgencyName"],
                  INSPECTION_METHODS.get(item["InspectionMethod"], "未记录"), item["IssueTag"] or "未记录", item["Score"],
                  INSPECTION_STATES[status], item["CorrectionRequirement"] or "未记录", item["Correction"] or "—")],
    }, {
        "title": "整改记录",
        "columns": ["状态", "操作者", "时间（UTC）", "整改内容"],
        "rows": [(INSPECTION_STATES[row["CurrentStatus"]], row["DisplayName"] or "演示初始化",
                  row["ChangedAt"], row["Correction"] or "—") for row in history],
    }]
    if can_correct:
        panels.append({"title": "提交整改", "form": [field("correction", "整改内容", "textarea")],
                       "submit": "提交复查"})
    if can_close:
        panels.append({"title": "整改复查", "text": "复查通过后解除本次抽查产生的接单限制。",
                       "form": [field("review", "复查结果", "select",
                                      options=[("close", "复查通过并结案"), ("reopen", "退回整改")]),
                                field("correction", "退回原因", "textarea", required=False)],
                       "submit": "提交复查结果"})
    return workspace(f"质量抽查 #{inspection_id}", "查看问题、整改与复查记录", panels)
