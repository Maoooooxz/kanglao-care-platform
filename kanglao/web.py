from datetime import datetime, timedelta, timezone
from functools import wraps
from secrets import compare_digest, token_urlsafe

from flask import abort, flash, g, redirect, render_template, request, session, url_for

SHANGHAI = timezone(timedelta(hours=8), "Asia/Shanghai")
ROLE_NAMES = {
    "community": "社区管理员", "family": "家属", "resident": "老人",
    "caregiver": "护工", "agency": "机构负责人", "street": "街道审核员", "civil": "民政监管员",
}
STATUSES = {
    "有效": ("有效", "good"), "已过期": ("已过期", "bad"), "未评估": ("未评估", "warn"),
    "active": ("生效", "good"), "inactive": ("停用", "bad"), "pending": ("待处理", "warn"),
    "paused": ("已暂停", "warn"), "closed": ("已关闭", "good"), "completed": ("已完成", "good"),
    "complete": ("已完成", "good"), "new": ("待处理", "warn"), "open": ("待响应", "warn"),
    "approved": ("已通过", "good"), "rejected": ("未通过", "bad"), "returned": ("已退回", "warn"),
    "draft": ("草稿", "warn"), "cancelled": ("已取消", "bad"), "scheduled": ("已预约", "good"),
    "responded": ("已响应", "good"), "arrived": ("已到场", "good"),
    "accepted": ("已接单", "good"), "paid": ("已拨付", "good"), "resolved": ("已整改", "good"),
    "pending_dispatch": ("待派单", "warn"), "offered": ("待接单", "warn"),
    "confirmed": ("已确认", "good"), "ready": ("待派单", "warn"), "manual": ("人工调度", "warn"),
    "in_service": ("服务中", "good"), "awaiting_confirmation": ("待签字确认", "warn"),
    "on_review": ("待复核", "warn"), "escalated": ("已升级", "bad"),
    "street_pending": ("街道待审", "warn"), "civil_pending": ("民政待审", "warn"),
}


def beijing_today():
    return datetime.now(SHANGHAI).date()


def local_datetime(value):
    value = datetime.fromisoformat(value)
    if value.tzinfo is None:
        value = value.replace(tzinfo=SHANGHAI)
    return value.astimezone(timezone.utc).replace(tzinfo=None)


def status_class(value):
    return STATUSES.get(value.lower(), ("", ""))[1] if isinstance(value, str) else ""


def status_label(value):
    return STATUSES.get(value.lower(), (value, ""))[0]


def cell_display(value):
    if isinstance(value, datetime):
        return value.replace(tzinfo=timezone.utc).astimezone(SHANGHAI).strftime("%Y-%m-%d %H:%M")
    return value


def roles(*allowed):
    def decorate(view):
        @wraps(view)
        def guarded(*args, **kwargs):
            if g.get("user") is None:
                flash("请先登录。", "info")
                return redirect(url_for("account.login"))
            if allowed and g.user["role"] not in allowed:
                abort(403)
            return view(*args, **kwargs)
        return guarded
    return decorate


def csrf_token():
    if "csrf" not in session:
        session["csrf"] = token_urlsafe(32)
    return session["csrf"]


def check_csrf():
    if request.method not in {"GET", "HEAD", "OPTIONS"}:
        expected = session.get("csrf", "")
        provided = request.form.get("csrf_token", "")
        if not expected or not compare_digest(provided.encode(), expected.encode()):
            abort(400, description="表单已过期，请刷新页面后重新提交。")


def field(name, label, type="text", options=None, value=None, required=True, **attributes):
    return dict(name=name, label=label, type=type, options=options or (), value=value,
                required=required, attributes=attributes)


def workspace(title, subtitle, panels, *, stats=None):
    return render_template("workspace.html", title=title, subtitle=subtitle,
                           panels=panels, stats=stats or ())
