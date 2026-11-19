from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from secrets import token_hex

from flask import Blueprint, abort, flash, g, redirect, request, url_for

from .db import execute, one, query, transaction
from .web import SHANGHAI, beijing_today, field, local_datetime, roles, workspace

bp = Blueprint("services", __name__, url_prefix="/services")
ALL_ROLES = ("community", "family", "resident", "caregiver", "agency", "street", "civil")
WORKER_READERS = ("community", "caregiver", "agency", "street", "civil")
STATUS = {
    "ACTIVE": "生效", "PAUSED": "暂停", "ENDED": "结束", "NEW": "待派单", "POOL": "人工调度",
    "OFFERED": "待接单", "ACCEPTED": "已接单", "IN_SERVICE": "服务中", "AWAITING_CONFIRMATION": "待签字",
    "COMPLETED": "已完成", "REVIEW": "待复核", "RESCHEDULE": "待预约", "CANCELLED": "已取消",
    "OPEN": "工时记录中", "VALID": "工时有效", "REJECTED": "工时驳回",
}
ORDER_ACTIONS = {
    "community": {"DISPATCH", "CANCEL", "REVIEW_APPROVE", "RESCHEDULE", "WORK_APPROVE", "WORK_REJECT", "COMPLAINT_RESOLVE"},
    "family": {"CONFIRM", "FEEDBACK", "CANCEL", "RESCHEDULE", "COMPLAIN"},
    "resident": {"FEEDBACK", "CANCEL", "RESCHEDULE", "COMPLAIN"},
    "caregiver": {"ACCEPT", "CHECK_IN", "CHECK_OUT"},
    "agency": {"WORK_APPROVE", "WORK_REJECT"},
}
BOOKERS = {"community", "family", "resident"}


def _time(value):
    if value is None:
        return ""
    return value.replace(tzinfo=timezone.utc).astimezone(SHANGHAI).strftime("%m-%d %H:%M")


def _status(value):
    return STATUS.get(value, value or "")


def _scope(target):
    user = g.user
    role = user["role"]
    if role == "community":
        return f"{target}.CommunityId=?", (user["community_id"],)
    if role in {"family", "resident"}:
        return f"{target}.ArchiveNo=?", (user["archive_no"],)
    if role == "caregiver":
        column = "ResponsibleWorkerId" if target == "p" else "WorkerId"
        return f"{target}.{column}=?", (user["worker_id"],)
    if role == "agency":
        return f"{target}.AgencyId=?", (user["agency_id"],)
    if role in {"street", "civil"}:
        return f"{target}.District=?", (user["district"],)
    return "1=1", ()


def _worker_scope(target):
    if g.user["role"] == "community":
        return (f"EXISTS (SELECT 1 FROM dbo.WorkerCommunity wc WHERE wc.WorkerId={target}.WorkerId "
                "AND wc.CommunityId=?)"), (g.user["community_id"],)
    return _scope(target)


def _coordinate(name, limit):
    value = request.form.get(name, "").strip()
    if not value:
        return None
    try:
        result = Decimal(value)
    except InvalidOperation as error:
        raise ValueError("坐标格式不正确") from error
    if not result.is_finite() or not -limit <= result <= limit:
        raise ValueError("坐标超出范围")
    return result


def _text(name, limit, *, required=True):
    value = request.form.get(name, "").strip()
    if len(value) > limit or (required and not value):
        raise ValueError("输入长度不正确")
    return value or None


def _scoped_archive(archive_no):
    column, value = ("CommunityId", g.user["community_id"]) if g.user["role"] == "community" else (
        "ArchiveNo", g.user["archive_no"])
    record = one(f"SELECT ArchiveNo FROM dbo.ElderArchive WHERE IsActive=1 AND ArchiveNo=? AND {column}=?",
                 archive_no, value)
    if record is None:
        abort(404)
    return record


def _archive_options():
    column, value = ("CommunityId", g.user["community_id"]) if g.user["role"] == "community" else (
        "ArchiveNo", g.user["archive_no"])
    return [(item["ArchiveNo"], f'{item["ArchiveNo"]} · {item["FullName"]}') for item in query(
        f"SELECT ArchiveNo,FullName FROM dbo.ElderArchive WHERE IsActive=1 AND {column}=? ORDER BY ArchiveNo", value)]


def _worker_options():
    scope, args = _worker_scope("w")
    workers = query("SELECT w.WorkerId,w.WorkerNo,w.Name FROM dbo.Worker w JOIN dbo.Agency a ON a.AgencyId=w.AgencyId "
                    f"WHERE w.IsActive=1 AND {scope} ORDER BY w.WorkerNo", *args)
    return [(row["WorkerId"], f'{row["WorkerNo"]} · {row["Name"]}') for row in workers]


def _form(title, fields, action, *, hidden=None, submit="提交"):
    return dict(title=title, form=fields, action=action, hidden=hidden or {}, submit=submit)


def _slots(prefix=""):
    start = datetime.now(SHANGHAI) + timedelta(hours=4)
    return [field(prefix + "start", "预约开始（北京时间）", "datetime-local", value=start.strftime("%Y-%m-%dT%H:%M")),
            field(prefix + "end", "预约结束（北京时间）", "datetime-local",
                  value=(start + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M"))]


def _location_fields():
    return [field("latitude", "模拟纬度（留空取服务地址）", "number", required=False,
                  step="0.000001", min=-90, max=90),
            field("longitude", "模拟经度（留空取服务地址）", "number", required=False,
                  step="0.000001", min=-180, max=180)]


def _coordinates():
    latitude, longitude = _coordinate("latitude", 90), _coordinate("longitude", 180)
    if (latitude is None) != (longitude is None):
        raise ValueError("坐标须同时填写或同时留空")
    return latitude, longitude


@bp.get("/")
@roles(*ALL_ROLES)
def index():
    return redirect(url_for("services.orders"))


@bp.route("/plans", methods=["GET", "POST"])
@roles(*ALL_ROLES)
def plans():
    scope, args = _scope("p")
    if request.method == "POST":
        if g.user["role"] != "community":
            abort(403)
        operation = request.form.get("operation")
        if operation == "CREATE":
            archive_no = _text("archive_no", 20)
            _scoped_archive(archive_no)
            execute("EXEC dbo.usp_CreateCarePlan ?,?,?,?,?,?", archive_no, int(request.form["package_id"]),
                    int(request.form["worker_id"]), date.fromisoformat(request.form["starts_on"]),
                    date.fromisoformat(request.form["ends_on"]), g.user["community_id"])
        elif operation in {"RESUME", "END"}:
            plan_id = int(request.form["plan_id"])
            if one(f"SELECT PlanId FROM dbo.v_CarePlanOverview p WHERE p.PlanId=? AND {scope}", plan_id, *args) is None:
                abort(404)
            execute("EXEC dbo.usp_ChangeCarePlan ?,?,?,?", plan_id, operation, _text("reason", 250),
                    g.user["community_id"])
        else:
            abort(400)
        flash("照护计划已保存。", "success")
        return redirect(url_for("services.plans"))

    rows = query(f"SELECT TOP (100) p.* FROM dbo.v_CarePlanOverview p WHERE {scope} ORDER BY p.PlanId DESC", *args)
    packages = query("SELECT p.PackageId,p.Name,p.AbilityLevel,t.Name AS ServiceName,s.VisitsPerWeek "
                     "FROM dbo.CarePackage p JOIN dbo.CarePackageService s ON s.PackageId=p.PackageId "
                     "JOIN dbo.ServiceType t ON t.ServiceTypeId=s.ServiceTypeId ORDER BY p.Name,t.Name")
    applicable = {row["PackageId"] for row in rows}
    panels = [dict(title="照护计划", columns=["档案", "姓名", "服务包", "负责护工", "有效期", "计划状态", "评估", "处理说明"],
                   rows=[(row["ArchiveNo"], row["FullName"], row["PackageName"], row["WorkerName"],
                          f'{row["StartsOn"]} 至 {row["EndsOn"]}', _status(row["Status"]),
                          row["AssessmentStatus"], row["ChangedReason"]) for row in rows]),
              dict(title="适用服务包与频次", columns=["服务包", "能力等级", "服务项目", "每周参考频次"],
                   rows=[(row["Name"], row["AbilityLevel"], row["ServiceName"], row["VisitsPerWeek"])
                         for row in packages if row["PackageId"] in applicable or g.user["role"] == "community"])]
    if g.user["role"] == "community":
        action = url_for("services.plans")
        options = {row["PackageId"]: f'{row["Name"]} · {row["AbilityLevel"]}' for row in packages}
        panels.append(_form("建立照护计划", [field("archive_no", "老人档案", "select", _archive_options()),
                            field("package_id", "服务包", "select", list(options.items())),
                            field("worker_id", "责任护工", "select", _worker_options()),
                            field("starts_on", "开始日期", "date", value=beijing_today()),
                            field("ends_on", "结束日期", "date", value=beijing_today() + timedelta(days=30))],
                            action, hidden={"operation": "CREATE"}))
        for operation, title, allowed in (("RESUME", "复核恢复照护", {"PAUSED"}), ("END", "结束照护计划", {"ACTIVE", "PAUSED"})):
            choices = [(row["PlanId"], f'{row["ArchiveNo"]} · {row["PackageName"]}') for row in rows if row["Status"] in allowed]
            if choices:
                panels.append(_form(title, [field("plan_id", "计划", "select", choices),
                                            field("reason", "理由", maxlength=250)], action, hidden={"operation": operation}))
    return workspace("照护计划", "依照最新有效评估匹配服务包，同一老人同一期间只安排一份生效计划。", panels)


def _book_order():
    archive_no = _text("archive_no", 20)
    _scoped_archive(archive_no)
    role = g.user["role"]
    channel = request.form.get("channel", "COMMUNITY") if role == "community" else "FAMILY"
    if channel not in ({"PHONE", "COMMUNITY"} if role == "community" else {"FAMILY"}):
        abort(400)
    address = _text("address", 200, required=False)
    latitude, longitude = _coordinates()
    if address and latitude is None:
        abort(400, description="自填服务地址时请同时提供模拟纬度和经度。")
    execute("EXEC dbo.usp_CreateServiceOrder @ArchiveNo=?,@ServiceTypeId=?,@AppointmentStart=?,"
            "@AppointmentEnd=?,@Address=?,@Latitude=?,@Longitude=?,@Channel=?,@ActingCommunityId=?",
            archive_no, int(request.form["service_type_id"]),
            local_datetime(request.form["start"]), local_datetime(request.form["end"]),
            address, latitude, longitude, channel,
            g.user["community_id"] if role == "community" else None)


def _change_order(scope, args, action):
    role = g.user["role"]
    if action not in ORDER_ACTIONS.get(role, set()):
        abort(403)
    order_id = int(request.form["order_id"])
    order = one(f"SELECT o.OrderId,o.WorkerId FROM dbo.v_ServiceOrderOverview o WHERE o.OrderId=? AND {scope}", order_id, *args)
    if order is None:
        abort(404)
    worker_id = g.user["worker_id"] if role == "caregiver" else None
    if action == "DISPATCH":
        worker_id = int(request.form["worker_id"])
    elif action in {"WORK_APPROVE", "WORK_REJECT"}:
        worker_id = order["WorkerId"]
    start = local_datetime(request.form["start"]) if action == "RESCHEDULE" else None
    end = local_datetime(request.form["end"]) if action == "RESCHEDULE" else None
    score = int(request.form["score"]) if action == "FEEDBACK" else None
    limit = 500 if action == "CHECK_OUT" else 300 if action in {"COMPLAIN", "COMPLAINT_RESOLVE"} else 250
    reason = _text("reason", limit, required=False)
    latitude, longitude = _coordinates() if action in {"CHECK_IN", "CHECK_OUT"} else (None, None)
    execute("EXEC dbo.usp_ServiceOrderAction @OrderId=?,@Action=?,@WorkerId=?,@Reason=?,@ActorId=?,"
            "@Latitude=?,@Longitude=?,@NewStart=?,@NewEnd=?,@FeedbackScore=?",
            order_id, action, worker_id, reason, g.user["id"], latitude, longitude, start, end, score)


def _booking_panel(action):
    fields = [field("archive_no", "老人档案", "select", _archive_options()),
              field("service_type_id", "服务项目", "select", [(row["ServiceTypeId"], row["Name"]) for row in
                    query("SELECT ServiceTypeId,Name FROM dbo.ServiceType ORDER BY Name")]), *_slots(),
              field("address", "服务地址（自填地址须附两项坐标，留空取档案地址）", required=False, maxlength=200),
              *_location_fields()]
    if g.user["role"] == "community":
        fields.append(field("channel", "下单渠道", "select", [("COMMUNITY", "社区代下单"), ("PHONE", "电话下单")]))
    return _form("预约上门服务", fields, action, hidden={"operation": "BOOK"}, submit="提交预约")


def _order_forms(rows, action):
    panels = []
    role = g.user["role"]
    if role in BOOKERS:
        panels.append(_booking_panel(action))
    if role == "community":
        candidates = query("""SELECT TOP (100) o.OrderId,o.ArchiveNo,o.ServiceName,e.WorkerName,e.Remaining
            FROM dbo.v_ServiceOrderOverview o CROSS APPLY dbo.fn_EligibleServiceShifts(o.OrderId) e
            WHERE o.CommunityId=? AND o.Status IN ('NEW','POOL','OFFERED','ACCEPTED')
                AND o.AppointmentStart>SYSUTCDATETIME() ORDER BY o.AppointmentStart,e.WorkerId""", g.user["community_id"])
        panels.append(dict(title="可接单护工推荐", columns=["订单", "老人档案", "项目", "候选护工", "剩余班次名额"],
                           rows=[tuple(row[key] for key in ("OrderId", "ArchiveNo", "ServiceName", "WorkerName", "Remaining"))
                                 for row in candidates]))

    definitions = (
        ("DISPATCH", "派单或改派", ("NEW", "POOL", "OFFERED", "ACCEPTED")),
        ("ACCEPT", "接受派单", ("OFFERED",)), ("CHECK_IN", "模拟上门签到", ("ACCEPTED",)),
        ("CHECK_OUT", "模拟离场签退", ("IN_SERVICE",)),
        ("CONFIRM", "家属签字确认", ("AWAITING_CONFIRMATION",)), ("FEEDBACK", "服务评价", ("COMPLETED",)),
        ("REVIEW_APPROVE", "评估恢复后的人工复核", ("REVIEW",)),
        ("RESCHEDULE", "重新预约", ("RESCHEDULE", "POOL")),
        ("CANCEL", "取消预约", ("NEW", "POOL", "OFFERED", "ACCEPTED", "REVIEW", "RESCHEDULE")),
        ("WORK_APPROVE", "批准异常工时", ()), ("WORK_REJECT", "驳回异常工时", ()),
        ("COMPLAIN", "提交服务投诉", ("COMPLETED",)),
        ("COMPLAINT_RESOLVE", "回复服务投诉", ("COMPLETED",)),
    )
    for operation, title, states in definitions:
        if operation not in ORDER_ACTIONS.get(role, set()):
            continue
        available = [row for row in rows if row["Status"] in states or (not states and row["WorkStatus"] == "REVIEW")]
        if operation == "COMPLAIN":
            available = [row for row in available if row["ComplainedAt"] is None]
        elif operation == "COMPLAINT_RESOLVE":
            available = [row for row in available if row["ComplainedAt"] and row["ComplaintResolvedAt"] is None]
        if not available:
            continue
        fields = [field("order_id", "订单", "select", [(row["OrderId"], f'{row["OrderId"]} · {row["ServiceName"]} · {row["ArchiveNo"]}')
                    for row in available])]
        if operation == "DISPATCH":
            fields.extend([field("worker_id", "护工", "select", _worker_options()),
                           field("reason", "改派原因（首次可留空）", required=False, maxlength=250)])
        elif operation in {"CHECK_IN", "CHECK_OUT"}:
            fields.extend(_location_fields())
            if operation == "CHECK_OUT":
                fields.append(field("reason", "服务情况记录", maxlength=500))
        elif operation == "CONFIRM":
            fields.append(field("reason", "家属电子签字", maxlength=200))
        elif operation == "FEEDBACK":
            fields.extend([field("score", "评分", "select", [(n, str(n)) for n in range(1, 6)]),
                           field("reason", "评价内容", required=False, maxlength=250)])
        elif operation == "RESCHEDULE":
            fields.extend(_slots())
        elif operation in {"COMPLAIN", "COMPLAINT_RESOLVE"}:
            fields.append(field("reason", "投诉内容" if operation == "COMPLAIN" else "处理结果", maxlength=300))
        elif operation != "ACCEPT":
            fields.append(field("reason", "处理理由", maxlength=250))
        panels.append(_form(title, fields, action, hidden={"operation": operation}, submit=title))
    return panels


@bp.route("/orders", methods=["GET", "POST"])
@roles(*ALL_ROLES)
def orders():
    role = g.user["role"]
    scope, args = _scope("o")
    if request.method == "POST":
        operation = request.form.get("operation")
        if operation == "BOOK":
            if role not in BOOKERS:
                abort(403)
            _book_order()
        else:
            _change_order(scope, args, operation)
        flash("订单操作已保存。", "success")
        return redirect(url_for("services.orders"))

    rows = query(f"SELECT TOP (150) o.* FROM dbo.v_ServiceOrderOverview o WHERE {scope} ORDER BY o.OrderId DESC", *args)
    display_address = role in {"community", "family", "resident", "caregiver", "agency"}
    columns = ["订单", "档案", "服务项目", "开始", "结束", "金额", "状态", "护工",
               "工时状态", "有效分钟", "家属签字时间", "评分", "说明"]
    if display_address:
        columns.append("服务地址")
    table = []
    for row in rows:
        cells = (row["OrderId"], row["ArchiveNo"], row["ServiceName"], _time(row["AppointmentStart"]),
                 _time(row["AppointmentEnd"]), row["Price"], _status(row["Status"]), row["WorkerName"],
                 _status(row["WorkStatus"]), row["EffectiveMinutes"], _time(row["ConfirmedAt"]),
                 row["FeedbackScore"], row["ReviewReason"])
        table.append(cells + (row["Address"],) if display_address else cells)
    panels = [dict(title="服务订单", columns=columns, rows=table)]
    complaints = [row for row in rows if row["ComplainedAt"] is not None]
    if complaints:
        panels.append(dict(title="服务投诉与处理", columns=["订单", "投诉时间", "投诉", "处理时间", "处理结果"],
                           rows=[(row["OrderId"], _time(row["ComplainedAt"]), row["ComplaintText"],
                                  _time(row["ComplaintResolvedAt"]), row["ComplaintResolution"] or "待社区处理")
                                 for row in complaints]))
    history_scope, history_args = _scope("h")
    history = query(f"SELECT TOP (80) h.* FROM dbo.v_ServiceDispatchHistory h WHERE {history_scope} "
                    "ORDER BY h.DispatchId DESC", *history_args)
    panels.append(dict(title="派单历史", columns=["派单", "订单", "护工", "发出", "接受", "结束", "原因"],
                       rows=[(row["DispatchId"], row["OrderId"], row["WorkerName"], _time(row["OfferedAt"]),
                              _time(row["AcceptedAt"]), _time(row["ClosedAt"]), row["CloseReason"]) for row in history]))
    panels.extend(_order_forms(rows, url_for("services.orders")))
    return workspace("服务下单与派单", "评估、照护计划、服务地址和护工可用性均通过校验后，才可进入下一步。", panels)


@bp.route("/workers", methods=["GET", "POST"])
@roles(*WORKER_READERS)
def workers():
    scope, args = _worker_scope("w")
    if request.method == "POST":
        if g.user["role"] != "agency":
            abort(403)
        operation = request.form.get("operation")
        agency_id = g.user["agency_id"]
        if operation == "ADD_WORKER":
            community_id = int(request.form["community_id"])
            if one("SELECT c.CommunityId FROM dbo.Community c JOIN dbo.Agency a ON a.District=c.District "
                   "WHERE c.CommunityId=? AND a.AgencyId=?", community_id, agency_id) is None:
                abort(404)
            with transaction():
                worker = one("INSERT dbo.Worker(WorkerNo,AgencyId,Name,Grade) OUTPUT inserted.WorkerId VALUES(?,?,?,?)",
                             f"WK-{token_hex(9)}", agency_id, _text("name", 100), _text("grade", 40))
                execute("INSERT dbo.WorkerCommunity(WorkerId,CommunityId) VALUES(?,?)", worker["WorkerId"], community_id)
        else:
            worker_id = int(request.form["worker_id"])
            if one("SELECT WorkerId FROM dbo.Worker WHERE WorkerId=? AND AgencyId=?", worker_id, agency_id) is None:
                abort(404)
            if operation == "SHIFT":
                execute("EXEC dbo.usp_CreateWorkerShift ?,?,?,?", worker_id, local_datetime(request.form["start"]),
                        local_datetime(request.form["end"]), int(request.form["capacity"]))
            elif operation == "CREDENTIAL":
                execute("EXEC dbo.usp_SetWorkerCredential ?,?,?,?,?", worker_id, int(request.form["service_type_id"]),
                        _text("credential", 60), date.fromisoformat(request.form["valid_from"]),
                        date.fromisoformat(request.form["valid_through"]))
            elif operation == "TRAINING":
                completed_on = date.fromisoformat(request.form["completed_on"])
                if completed_on > beijing_today():
                    raise ValueError("培训完成日期不能晚于当天")
                execute("UPDATE dbo.Worker SET TrainingCompletedOn=? WHERE WorkerId=? AND AgencyId=?",
                        completed_on, worker_id, agency_id)
            else:
                abort(400)
        flash("护工资料已保存。", "success")
        return redirect(url_for("services.workers"))

    # 护工名册与汇总视图都使用相同的所属机构、区域和账号范围。
    worker_rows = query("SELECT TOP (100) w.WorkerId,w.WorkerNo,w.Name,w.Grade,w.Rating,w.IsActive,"
                        "w.TrainingCompletedOn,a.Name AS AgencyName "
                        "FROM dbo.Worker w JOIN dbo.Agency a ON a.AgencyId=w.AgencyId "
                        f"WHERE {scope.replace('w.District', 'a.District')} ORDER BY w.WorkerNo", *args)
    shift_scope, shift_args = _worker_scope("s")
    shifts = query(f"SELECT TOP (100) s.* FROM dbo.v_WorkerShiftAvailability s WHERE {shift_scope} "
                   "ORDER BY s.StartsAt DESC,s.ShiftId DESC", *shift_args)
    hours = query(f"SELECT TOP (100) s.* FROM dbo.v_WorkerMonthlyHours s WHERE {shift_scope} "
                  "ORDER BY s.WorkMonth DESC,s.WorkerId", *shift_args)
    credentials = query("SELECT TOP (100) w.Name AS WorkerName,t.Name AS ServiceName,"
                        " ws.CredentialNo,ws.ValidFrom,ws.ValidThrough"
                        " FROM dbo.WorkerService ws JOIN dbo.Worker w ON w.WorkerId=ws.WorkerId"
                        " JOIN dbo.Agency a ON a.AgencyId=w.AgencyId JOIN dbo.ServiceType t ON t.ServiceTypeId=ws.ServiceTypeId"
                        f" WHERE {scope.replace('w.District', 'a.District')} ORDER BY w.WorkerNo,t.Name", *args)
    review_scope, review_args = _scope("r")
    review = query(f"SELECT TOP (100) r.* FROM dbo.v_WorkHourReview r WHERE {review_scope} ORDER BY r.OrderId DESC", *review_args)
    panels = [dict(title="护工资料", columns=["编号", "姓名", "机构", "等级", "评分", "在岗", "培训完成"], rows=[(
                   row["WorkerNo"], row["Name"], row["AgencyName"], row["Grade"], row["Rating"],
                   "在岗" if row["IsActive"] else "离岗", row["TrainingCompletedOn"]) for row in worker_rows]),
              dict(title="排班与名额", columns=["护工", "开始", "结束", "容量", "已接", "剩余"], rows=[(
                   row["WorkerName"], _time(row["StartsAt"]), _time(row["EndsAt"]), row["Capacity"],
                   row["AcceptedCount"], row["Remaining"]) for row in shifts]),
              dict(title="月度有效工时", columns=["护工", "月份", "服务次数", "有效分钟"], rows=[(
                   row["WorkerName"], row["WorkMonth"], row["Visits"], row["EffectiveMinutes"]) for row in hours]),
              dict(title="护工资质与有效期", columns=["护工", "项目", "证书编号", "生效", "有效至"], rows=[(
                   row["WorkerName"], row["ServiceName"], row["CredentialNo"], row["ValidFrom"], row["ValidThrough"])
                   for row in credentials]),
              dict(title="待复核工时", columns=["订单", "档案", "护工", "签到", "签退", "原因"], rows=[(
                   row["OrderId"], row["ArchiveNo"], row["WorkerName"], _time(row["CheckInAt"]),
                   _time(row["CheckOutAt"]), row["ReviewReason"]) for row in review])]
    if g.user["role"] == "agency":
        action = url_for("services.workers")
        options = _worker_options()
        communities = query("SELECT c.CommunityId,c.Name FROM dbo.Community c JOIN dbo.Agency a ON a.District=c.District "
                            "WHERE a.AgencyId=? ORDER BY c.Name", g.user["agency_id"])
        panels.extend([_form("登记护工", [field("name", "姓名", maxlength=100), field("grade", "等级", maxlength=40),
                            field("community_id", "服务社区", "select", [(r["CommunityId"], r["Name"]) for r in communities])],
                            action, hidden={"operation": "ADD_WORKER"}),
                       _form("登记可接单班次", [field("worker_id", "护工", "select", options), *_slots(),
                              field("capacity", "可接单数", "number", value=4, min=1)], action, hidden={"operation": "SHIFT"}),
                       _form("登记培训完成日期", [field("worker_id", "护工", "select", options),
                              field("completed_on", "培训完成日期", "date", value=beijing_today())],
                             action, hidden={"operation": "TRAINING"}),
                       _form("维护项目资质", [field("worker_id", "护工", "select", options),
                              field("service_type_id", "服务项目", "select", [(r["ServiceTypeId"],r["Name"]) for r in
                                    query("SELECT ServiceTypeId,Name FROM dbo.ServiceType ORDER BY Name")]),
                              field("credential", "证书编号", maxlength=60),
                              field("valid_from", "生效日期", "date", value=beijing_today()),
                              field("valid_through", "到期日期", "date", value=beijing_today() + timedelta(days=365))],
                             action, hidden={"operation": "CREDENTIAL"})])
    return workspace("护工与排班", "班次覆盖、资格有效期和服务范围决定可接单资格，异常工时须人工复核。", panels)
