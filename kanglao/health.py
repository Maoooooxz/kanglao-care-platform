from datetime import timezone
from decimal import Decimal, InvalidOperation
from uuid import uuid4

from flask import Blueprint, flash, g, redirect, request, url_for
from mssql_python import Error

from .db import execute, query
from .web import SHANGHAI, field, local_datetime, roles, workspace


bp = Blueprint("health", __name__, url_prefix="/health")

NOTICE_ROLES = ("community", "resident", "family", "caregiver", "street", "civil")
READ_ROLES = (*NOTICE_ROLES, "agency")
REPORT_ROLES = ("community", "resident", "family", "caregiver")
RESPOND_ROLES = ("community", "caregiver", "street", "civil")

DEVICE_LABELS = {"VITALS": "体征监测", "SOS": "一键呼叫"}
ALERT_LABELS = {"PENDING": "待确认", "FALSE_ALARM": "误报已关闭", "CONFIRMED": "已确认", "TIMEOUT": "超时转应急"}
EVENT_LABELS = {"OPEN": "待响应", "ESCALATED": "已升级", "RESPONDED": "已响应", "ARRIVED": "已到场", "CLOSED": "已处置"}
SOURCE_LABELS = {"THRESHOLD": "体征告警", "SOS": "一键呼叫", "MANUAL": "人工上报"}
NOTICE_LABELS = {"TRIAGE": "体征告警待复核", "EVENT": "新增应急事件", "ESCALATED": "应急事件已升级"}
AUDIT_LABELS = {"OPENED": "创建事件", "RESPONDED": "响应", "ARRIVED": "到场", "CLOSED": "处置完成", "ESCALATED": "超时升级"}


def _perform(message, sql, *params):
    try:
        execute(sql, *params)
    except Error:
        flash("操作未保存，请核对管理范围、记录状态和填写内容。", "error")
    else:
        flash(message, "success")
    return redirect(url_for("health.index"))


def _display_time(value):
    if value is None:
        return None
    return value.replace(tzinfo=timezone.utc).astimezone(SHANGHAI).strftime("%Y-%m-%d %H:%M:%S")


def _number(name):
    try:
        value = int(request.form.get(name, ""))
    except ValueError:
        return None
    return value if 0 < value <= 2147483647 else None


@bp.get("/")
@roles(*READ_ROLES)
def index():
    user_id = g.user["id"]
    role = g.user["role"]
    elders = query("""
        SELECT e.ArchiveNo, e.FullName
        FROM dbo.fn_HealthArchiveScope(?) AS scope
        JOIN dbo.ElderArchive AS e ON scope.ArchiveNo = e.ArchiveNo
        WHERE e.IsActive = 1 ORDER BY e.ArchiveNo
    """, user_id)
    elder_options = [(row["ArchiveNo"], f'{row["FullName"]}（{row["ArchiveNo"]}）') for row in elders]

    readings = query("""
        SELECT TOP (30) r.ArchiveNo, r.DeviceCode, r.CapturedAt, r.MetricName, r.UnitLabel,
                        r.MeasuredValue, r.IsAbnormal
        FROM dbo.v_HealthReadingHistory AS r
        JOIN dbo.fn_HealthArchiveScope(?) AS scope ON scope.ArchiveNo = r.ArchiveNo
        ORDER BY r.CapturedAt DESC, r.ReadingId DESC
    """, user_id)
    alerts = query("""
        SELECT TOP (30) a.AlertId, a.ArchiveNo, a.MetricName, a.MeasuredValue, a.State, a.TriageDeadline
        FROM dbo.v_HealthAlertQueue AS a
        JOIN dbo.fn_HealthArchiveScope(?) AS scope ON scope.ArchiveNo = a.ArchiveNo
        ORDER BY CASE WHEN a.State = 'PENDING' THEN 0 ELSE 1 END, a.AlertId DESC
    """, user_id)
    events = query("""
        SELECT TOP (40) EventId, ArchiveNo, FullName, SourceType, Severity, State, ResponseDeadline,
                        ResponderName, RespondedBy, ArrivedAt, ClosedAt, Resolution
        FROM dbo.v_HealthEventOverview AS e
        WHERE EXISTS (SELECT 1 FROM dbo.fn_HealthArchiveScope(?) AS scope WHERE scope.ArchiveNo = e.ArchiveNo)
           OR e.RespondedBy = ?
        ORDER BY CASE WHEN e.State = 'CLOSED' THEN 1 ELSE 0 END, e.EventId DESC
    """, user_id, user_id)
    notices = query("""
        SELECT TOP (30) NoticeId, AlertId, EventId, Kind, CreatedAt, ReadAt
        FROM dbo.HealthNotice WHERE RecipientUserId = ?
        ORDER BY CASE WHEN ReadAt IS NULL THEN 0 ELSE 1 END, NoticeId DESC
    """, user_id)

    panels = [
        {
            "title": "应急事件",
            "columns": ["编号", "老人", "来源", "等级", "状态", "响应截止", "响应人", "处置结果"],
            "rows": [(e["EventId"], e["FullName"], SOURCE_LABELS[e["SourceType"]], e["Severity"],
                      EVENT_LABELS[e["State"]], _display_time(e["ResponseDeadline"]), e["ResponderName"], e["Resolution"])
                     for e in events],
        },
        {
            "title": "模拟通知",
            "columns": ["通知编号", "类型", "告警", "事件", "时间", "状态"],
            "rows": [(n["NoticeId"], NOTICE_LABELS[n["Kind"]], n["AlertId"], n["EventId"], _display_time(n["CreatedAt"]),
                      "已读" if n["ReadAt"] else "未读") for n in notices],
        },
        {
            "title": "体征告警",
            "columns": ["编号", "档案", "指标", "测量值", "状态", "复核截止"],
            "rows": [(a["AlertId"], a["ArchiveNo"], a["MetricName"], a["MeasuredValue"],
                      ALERT_LABELS[a["State"]], _display_time(a["TriageDeadline"])) for a in alerts],
        },
        {
            "title": "近期体征记录",
            "columns": ["档案", "设备", "采集时间", "指标", "测量值", "是否异常"],
            "rows": [(r["ArchiveNo"], r["DeviceCode"], _display_time(r["CapturedAt"]), r["MetricName"],
                      f'{r["MeasuredValue"]} {r["UnitLabel"]}', "异常" if r["IsAbnormal"] else "正常")
                     for r in readings],
        },
    ]

    if role in ("family", "resident") and elder_options:
        panels.insert(0, {
            "title": "一键呼叫", "form": [],
            "hidden": {"request_key": uuid4().hex, "archive_no": g.user["archive_no"], "source_type": "SOS"},
            "action": url_for("health.open_event"), "submit": "立即呼叫",
        })
    elif role in REPORT_ROLES and elder_options:
        source_options = [("SOS", "一键呼叫")]
        if role in ("community", "caregiver"):
            source_options.append(("MANUAL", "人工上报异常"))
        panels.insert(0, {"title": "发起应急事件", "form": [
            field("archive_no", "老人档案", "select", elder_options),
            field("source_type", "来源", "select", source_options),
        ], "hidden": {"request_key": uuid4().hex}, "action": url_for("health.open_event"), "submit": "发起应急事件"})

    if role in RESPOND_ROLES:
        response_options = [(e["EventId"], f'{e["EventId"]} · {e["FullName"]}') for e in events if e["RespondedBy"] is None]
        arrival_options = [(e["EventId"], f'{e["EventId"]} · {e["FullName"]}') for e in events
                           if e["RespondedBy"] == user_id and e["ArrivedAt"] is None and e["ClosedAt"] is None]
        closure_options = [(e["EventId"], f'{e["EventId"]} · {e["FullName"]}') for e in events
                           if e["RespondedBy"] == user_id and e["ClosedAt"] is None]
        if response_options:
            panels.append({"title": "响应应急事件", "form": [field("event_id", "事件", "select", response_options)],
                           "hidden": {"event_action": "RESPOND"}, "action": url_for("health.update_event"), "submit": "记录响应"})
        if arrival_options:
            panels.append({"title": "记录到场", "form": [field("event_id", "事件", "select", arrival_options)],
                           "hidden": {"event_action": "ARRIVE"}, "action": url_for("health.update_event"), "submit": "记录到场"})
        if closure_options:
            panels.append({"title": "完成处置", "form": [field("event_id", "事件", "select", closure_options),
                                                             field("resolution", "处置结果", maxlength=400)],
                           "hidden": {"event_action": "CLOSE"}, "action": url_for("health.update_event"), "submit": "保存处置结果"})

    unread = [(n["NoticeId"], f'{n["NoticeId"]} · {NOTICE_LABELS[n["Kind"]]}') for n in notices if not n["ReadAt"]]
    if unread and role in NOTICE_ROLES:
        panels.append({"title": "处理通知", "form": [field("notice_id", "通知", "select", unread)],
                       "action": url_for("health.read_notice"), "submit": "标记已读"})

    if role == "community":
        pending = [(a["AlertId"], f'{a["AlertId"]} · {a["ArchiveNo"]} · {a["MetricName"]}') for a in alerts if a["State"] == "PENDING"]
        if pending:
            panels.append({"title": "复核体征告警", "form": [field("alert_id", "告警", "select", pending),
                           field("decision", "复核结果", "select", [("CONFIRMED", "确认并建立应急事件"), ("FALSE_ALARM", "判为误报")])],
                           "action": url_for("health.review_alert"), "submit": "提交复核"})

    if role in ("community", "caregiver"):
        _device_panels(panels, user_id, role, elder_options)

    audit = query("""
        SELECT TOP (30) a.EventId, a.ActionCode, a.OccurredAt, u.DisplayName, a.Details
        FROM dbo.HealthEventAudit AS a
        JOIN dbo.HealthEvent AS e ON e.EventId = a.EventId
        LEFT JOIN dbo.AppUser AS u ON u.UserId = a.ActorUserId
        WHERE EXISTS (SELECT 1 FROM dbo.fn_HealthArchiveScope(?) AS scope WHERE scope.ArchiveNo = e.ArchiveNo)
           OR e.RespondedBy = ?
        ORDER BY a.AuditId DESC
    """, user_id, user_id)
    panels.append({"title": "应急处置记录", "columns": ["事件", "操作", "时间", "操作人", "记录"],
                   "rows": [(a["EventId"], AUDIT_LABELS[a["ActionCode"]], _display_time(a["OccurredAt"]), a["DisplayName"], a["Details"]) for a in audit]})
    return workspace("健康与应急", "时间按北京时间显示。体征阈值和通知均为模拟演示。", panels)


def _device_panels(panels, user_id, role, elder_options):
    bindings = query("""
        SELECT b.BindingId, b.DeviceCode, b.DeviceType, b.ArchiveNo, b.StartsAt, b.EndsAt, b.IsEnabled,
               CASE WHEN NOT EXISTS (SELECT 1 FROM dbo.HealthBinding AS newer
                    WHERE newer.DeviceId = b.DeviceId AND newer.StartsAt > b.StartsAt)
                    THEN 1 ELSE 0 END AS IsLatest
        FROM dbo.v_HealthDeviceBindings AS b
        JOIN dbo.fn_HealthArchiveScope(?) AS scope ON scope.ArchiveNo = b.ArchiveNo
        ORDER BY b.StartsAt DESC, b.BindingId DESC
    """, user_id)
    panels.append({"title": "设备绑定历史", "columns": ["设备", "类型", "归属档案", "绑定时间", "解绑时间"],
                   "rows": [(b["DeviceCode"], DEVICE_LABELS[b["DeviceType"]], b["ArchiveNo"], _display_time(b["StartsAt"]), _display_time(b["EndsAt"])) for b in bindings[:30]]})
    vitals = dict.fromkeys(b["DeviceCode"] for b in bindings if b["DeviceType"] == "VITALS" and b["IsEnabled"])
    if vitals:
        metrics = query("SELECT MetricCode, MetricName, UnitLabel FROM dbo.HealthThreshold ORDER BY MetricName")
        panels.append({"title": "模拟体征上报", "form": [
            field("device_code", "设备", "select", [(code, code) for code in vitals]),
            field("metric_code", "指标", "select", [(m["MetricCode"], f'{m["MetricName"]}（{m["UnitLabel"]}）') for m in metrics]),
            field("measured_value", "测量值"), field("captured_at", "采集时间（留空用当前时间）", "datetime-local", required=False),
        ], "hidden": {"packet_key": uuid4().hex}, "action": url_for("health.record_reading"), "submit": "上报体征"})

    if role == "community" and elder_options:
        panels.append({"title": "登记新设备", "form": [field("device_code", "设备编号", maxlength=24),
            field("device_type", "类型", "select", list(DEVICE_LABELS.items())), field("archive_no", "老人档案", "select", elder_options)],
            "action": url_for("health.register_device"), "submit": "登记并绑定"})
        fresh = [b for b in bindings if b["IsLatest"] and b["EndsAt"] and b["IsEnabled"]]
        active = [b for b in bindings if b["EndsAt"] is None]
        if fresh:
            panels.append({"title": "重新绑定设备", "form": [field("device_code", "设备", "select", [(b["DeviceCode"], b["DeviceCode"]) for b in fresh]),
                              field("archive_no", "老人档案", "select", elder_options)],
                           "action": url_for("health.bind_device"), "submit": "绑定"})
        if active:
            panels.append({"title": "解除设备绑定", "form": [field("device_code", "设备", "select", [(b["DeviceCode"], b["DeviceCode"]) for b in active])],
                           "action": url_for("health.unbind_device"), "submit": "解除绑定"})


@bp.post("/devices/register")
@roles("community")
def register_device():
    code = request.form.get("device_code", "").strip()
    if not code or len(code) > 24:
        flash("设备编号须为 1 到 24 个字符。", "error")
        return redirect(url_for("health.index"))
    return _perform("设备已登记并绑定。", "EXEC dbo.usp_RegisterHealthDevice ?, ?, ?, ?", code,
                    request.form.get("device_type"), request.form.get("archive_no"), g.user["id"])


@bp.post("/devices/bind")
@roles("community")
def bind_device():
    return _perform("设备已绑定。", "EXEC dbo.usp_BindHealthDevice ?, ?, ?",
                    request.form.get("device_code"), request.form.get("archive_no"), g.user["id"])


@bp.post("/devices/unbind")
@roles("community")
def unbind_device():
    return _perform("设备已解绑。", "EXEC dbo.usp_UnbindHealthDevice ?, ?", request.form.get("device_code"), g.user["id"])


@bp.post("/readings")
@roles("community", "caregiver")
def record_reading():
    try:
        value = Decimal(request.form.get("measured_value", ""))
        if not value.is_finite() or value.copy_abs() > Decimal("99999999.99"):
            raise ValueError
        captured = request.form.get("captured_at", "")
        captured_at = local_datetime(captured) if captured else None
    except (InvalidOperation, ValueError, OverflowError):
        flash("请填写有效的测量值和采集时间。", "error")
        return redirect(url_for("health.index"))
    return _perform("体征记录已接收。", "EXEC dbo.usp_RecordHealthReading ?, ?, ?, ?, ?, ?",
                    request.form.get("device_code"), request.form.get("packet_key"),
                    request.form.get("metric_code"), value, captured_at, g.user["id"])


@bp.post("/alerts/review")
@roles("community")
def review_alert():
    return _perform("告警复核已保存。", "EXEC dbo.usp_ReviewHealthAlert ?, ?, ?",
                    _number("alert_id"), g.user["id"], request.form.get("decision"))


@bp.post("/events/open")
@roles(*REPORT_ROLES)
def open_event():
    return _perform("应急事件已记录，模拟通知可在收件箱查看。", "EXEC dbo.usp_OpenHealthEvent ?, ?, ?, ?",
                    request.form.get("archive_no"), request.form.get("request_key"), request.form.get("source_type"), g.user["id"])


@bp.post("/events/update")
@roles(*RESPOND_ROLES)
def update_event():
    resolution = request.form.get("resolution")
    if resolution is not None and len(resolution) > 400:
        flash("处置结果最多可填写 400 个字符。", "error")
        return redirect(url_for("health.index"))
    return _perform("应急处置已记录。", "EXEC dbo.usp_UpdateHealthEvent ?, ?, ?, ?",
                    _number("event_id"), g.user["id"], request.form.get("event_action"), resolution)


@bp.post("/notices/read")
@roles(*NOTICE_ROLES)
def read_notice():
    return _perform("通知已标记为已读。", """
        UPDATE dbo.HealthNotice SET ReadAt = COALESCE(ReadAt, SYSUTCDATETIME())
        WHERE NoticeId = ? AND RecipientUserId = ?
    """, _number("notice_id"), g.user["id"])
