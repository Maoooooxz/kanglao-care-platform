"""Monthly subsidy claims, district review, and service inspections."""

import json
from decimal import Decimal, InvalidOperation

from flask import Blueprint, abort, flash, g, redirect, request, url_for
from markupsafe import Markup

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
        conditions = "AND visit.ArchiveNo = ? AND visit.ServiceTypeId = ? AND dates.PeriodMonth = ?"
        params.extend([claim["ArchiveNo"], claim["ServiceTypeId"], claim["PeriodMonth"]])
    return query(f"""
        SELECT visit.OrderId, visit.ArchiveNo, visit.ServiceTypeId, visit.CommunityId, service.Name,
               dates.PeriodMonth, visit.Price, visit.EffectiveMinutes
        FROM dbo.v_SubsidyEligibleOrder visit
        JOIN dbo.ServiceType service ON service.ServiceTypeId = visit.ServiceTypeId
        JOIN dbo.Community community ON community.CommunityId = visit.CommunityId
        CROSS APPLY (VALUES (CONVERT(date, DATEADD(hour, 8, visit.CheckOutAt)))) clock(ServiceDate)
        CROSS APPLY (VALUES (DATEFROMPARTS(YEAR(clock.ServiceDate), MONTH(clock.ServiceDate), 1))) dates(PeriodMonth)
        WHERE visit.CommunityId = ? AND visit.EffectiveMinutes > 0
          AND EXISTS (
              SELECT 1 FROM dbo.SubsidyPolicy policy
              WHERE policy.District = community.District AND policy.ServiceTypeId = visit.ServiceTypeId
                AND clock.ServiceDate BETWEEN policy.ValidFrom AND policy.ValidThrough
          )
          AND NOT EXISTS (
              SELECT 1 FROM dbo.SubsidyClaim existing
              WHERE existing.ArchiveNo = visit.ArchiveNo AND existing.ServiceTypeId = visit.ServiceTypeId
                AND existing.PeriodMonth = dates.PeriodMonth AND existing.Status <> 'RETURNED'
          )
          {conditions}
        ORDER BY dates.PeriodMonth DESC, visit.ArchiveNo, service.Name, visit.OrderId
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
    }]
    if g.user["role"] == "community":
        panels.append(_order_form())
    if g.user["role"] in ("street", "civil"):
        panels.append({"title": "辖区管理", "text": Markup(" · ").join([
            _link("subsidy.policies", "补贴政策"),
            _link("subsidy.quality", "质量抽查和服务覆盖"),
        ])})
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
    history = query("""
        SELECT log.CurrentStatus, log.ChangedAt, log.Note, log.TotalAmount, log.OrderSnapshot,
               actor.DisplayName
        FROM dbo.SubsidyClaimLog log LEFT JOIN dbo.AppUser actor ON actor.UserId = log.ActorId
        WHERE log.ClaimId = ? ORDER BY log.LogId DESC
    """, claim_id)
    panels = [{
        "title": "订单和核算依据",
        "text": f'{claim["FullName"]} · {claim["ServiceName"]} · {claim["PeriodMonth"]:%Y-%m} · '
                f'{CLAIM_STATES[status]} · {_money(claim["TotalAmount"])}',
        "columns": ["服务订单", "适用政策", "有效分钟", "订单金额", "每小时标准", "每单上限", "核定金额"],
        "rows": [(f'#{line["OrderId"]}', line["PolicyName"], line["EffectiveMinutes"], _money(line["OrderPrice"]),
                  _money(line["HourlyRate"]), _money(line["MaxPerOrder"]), _money(line["Amount"])) for line in lines],
    }, {
        "title": "审核和修改记录",
        "columns": ["状态", "操作者", "时间（UTC）", "说明", "申报金额", "当时的订单及金额"],
        "rows": [(CLAIM_STATES[row["CurrentStatus"]], row["DisplayName"] or "演示初始化", row["ChangedAt"],
                  row["Note"], _money(row["TotalAmount"]),
                  "、".join(f'#{item["OrderId"]} {_money(item["Amount"])}'
                           for item in json.loads(row["OrderSnapshot"], parse_float=Decimal))) for row in history],
    }]
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
            "EXEC dbo.usp_SaveSubsidyPolicy ?, ?, ?, ?, ?, ?, ?, ?, ?",
            g.user["id"], request.form["name"].strip(), district, service_id,
            request.form["valid_from"], request.form["valid_through"], hourly_rate, max_per_order,
            int(request.form.get("close_previous") == "1"),
        )
        flash("补贴政策已添加。", "success")
        return redirect(url_for("subsidy.policies"))

    items = query("""
        SELECT policy.PolicyName, service.Name, policy.ValidFrom, policy.ValidThrough,
               policy.HourlyRate, policy.MaxPerOrder
        FROM dbo.SubsidyPolicy policy JOIN dbo.ServiceType service ON service.ServiceTypeId = policy.ServiceTypeId
        WHERE policy.District = ? ORDER BY policy.ValidFrom DESC, policy.PolicyId DESC
    """, district)
    panels = [{
        "title": "辖区补贴政策",
        "columns": ["政策", "服务项目", "起始日", "截止日", "每小时标准", "每单上限"],
        "rows": [(row["PolicyName"], row["Name"], row["ValidFrom"], row["ValidThrough"],
                  _money(row["HourlyRate"]), _money(row["MaxPerOrder"])) for row in items],
    }]
    if g.user["role"] == "civil":
        types = query("SELECT ServiceTypeId, Name FROM dbo.ServiceType ORDER BY Name")
        panels.append({
            "title": "新增政策版本",
            "text": "演示金额以有效工时、订单金额和政策单笔上限中的适用值核算。",
            "form": [field("name", "政策名称"),
                     field("service_type_id", "服务项目", "select",
                           options=[(row["ServiceTypeId"], row["Name"]) for row in types]),
                     field("valid_from", "起始日", "date"),
                     field("valid_through", "截止日", "date"),
                     field("hourly_rate", "每小时标准（元）"),
                     field("max_per_order", "每单上限（元）"),
                     field("close_previous", "政策版本关系", "select",
                           options=[("0", "新增独立有效期"), ("1", "接续旧政策并结束旧有效期")])],
            "submit": "添加政策",
        })
    return workspace("补贴政策", f"{district} · 政策按服务完成日期适用", panels)


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
            "EXEC dbo.usp_RegisterInspection ?, ?, ?, ?, ?",
            g.user["id"], target_type, target_id, score, request.form["finding"].strip(),
        )
        flash("质量抽查已登记。", "success")
        return redirect(url_for("subsidy.quality"))

    where, value = _inspection_scope()
    inspections = query(f"""
        SELECT InspectionId, OrderId, WorkerName, AgencyName, Score, Status, InspectedAt
        FROM dbo.v_QualityInspectionSummary WHERE {where} ORDER BY InspectionId DESC
    """, value)
    panels = [{
        "title": "质量抽查与整改",
        "columns": ["检查单", "服务订单", "护工", "机构", "得分", "状态", "时间（UTC）"],
        "rows": [(_link("subsidy.inspection", f'抽查 #{row["InspectionId"]}', inspection_id=row["InspectionId"]),
                  row["OrderId"] or "护工专项", row["WorkerName"], row["AgencyName"],
                  row["Score"], INSPECTION_STATES[row["Status"]], row["InspectedAt"]) for row in inspections],
    }]
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
                             field("score", "评分（0 至 100）", "number"),
                             field("finding", "检查结论", "textarea")],
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
        "columns": ["护工", "机构", "评分", "状态", "整改内容"],
        "rows": [(item["WorkerName"], item["AgencyName"], item["Score"],
                  INSPECTION_STATES[status], item["Correction"] or "—")],
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
