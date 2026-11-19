from datetime import datetime, timedelta, timezone
from secrets import token_hex

from flask import Blueprint, abort, flash, g, redirect, render_template, request, session, url_for
from werkzeug.security import check_password_hash, generate_password_hash

from .db import execute, one, transaction
from .web import roles

bp = Blueprint("account", __name__)
USER_COLUMNS = """UserId AS id, Username AS username, DisplayName AS display_name,
  Role AS role, CommunityId AS community_id, ArchiveNo AS archive_no,
  WorkerId AS worker_id, AgencyId AS agency_id, District AS district"""
DUMMY_PASSWORD = generate_password_hash(token_hex(24))


@bp.before_app_request
def load_user():
    g.user = None
    account_id = session.get("user_id")
    if not account_id:
        return
    g.user = one(f"SELECT {USER_COLUMNS} FROM dbo.AppUser WHERE UserId=? AND Active=1", account_id)
    if g.user is None:
        session.clear()
    elif request.method == "POST":
        execute("EXEC sys.sp_set_session_context @key=N'app_user', @value=?", account_id)


@bp.route("/login", methods=["GET", "POST"])
def login():
    if g.user:
        return redirect(url_for("home.index"))
    if request.method == "POST":
        username = request.form.get("username", "").strip().lower()
        password = request.form.get("password", "")
        now = datetime.now(timezone.utc).replace(tzinfo=None)
        if not 1 <= len(username) <= 48 or not 1 <= len(password) <= 128:
            abort(400, description="请输入有效的用户名和密码。")
        with transaction():
            user = one(
                "SELECT UserId, PasswordHash, FailedAttempts, LockedUntil FROM dbo.AppUser "
                "WITH (UPDLOCK,HOLDLOCK) WHERE Username=? AND Active=1", username,
            )
            valid = check_password_hash(user["PasswordHash"] if user else DUMMY_PASSWORD, password)
            if user and (user["LockedUntil"] is None or user["LockedUntil"] <= now):
                if valid:
                    execute("UPDATE dbo.AppUser SET FailedAttempts=0, LockedUntil=NULL WHERE UserId=?",
                            user["UserId"])
                    session.clear()
                    session.permanent = True
                    session["user_id"] = user["UserId"]
                    return redirect(url_for("home.index"))
                failures = 1 if user["LockedUntil"] else user["FailedAttempts"] + 1
                locked_until = now + timedelta(minutes=15) if failures >= 5 else None
                execute("UPDATE dbo.AppUser SET FailedAttempts=?,LockedUntil=? WHERE UserId=?",
                        failures, locked_until, user["UserId"])
        flash("登录未成功，请核对账号与密码。连续失败后请等待 15 分钟。", "error")
        return render_template("login.html", title="登录", username=username), 401
    return render_template("login.html", title="登录")


@bp.post("/logout")
@roles()
def logout():
    session.clear()
    return redirect(url_for("account.login"))
