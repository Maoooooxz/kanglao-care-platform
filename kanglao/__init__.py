import os
from datetime import timedelta
from pathlib import Path
from urllib.parse import urlsplit

from cryptography.fernet import Fernet
from dotenv import load_dotenv
from flask import Flask, flash, redirect, render_template, request, url_for
import mssql_python
from werkzeug.exceptions import BadRequest

from .db import close_db, one
from .web import ROLE_NAMES, cell_display, check_csrf, csrf_token, status_class, status_label

ROOT = Path(__file__).resolve().parents[1]
APP_NAME = "北林之家·社区居家养老服务"
LOCAL_CONNECTION = (
    r"Server=lpc:.\SQLEXPRESS;Database=KanglaoCourse;"
    "Trusted_Connection=yes;Encrypt=yes;TrustServerCertificate=yes"
)


def create_app(config=None):
    load_dotenv(ROOT / ".env")
    app = Flask(__name__)
    app.config.update(
        SECRET_KEY=os.getenv("KANG_LAO_SECRET"),
        CONTACT_KEY=os.getenv("KANG_LAO_CONTACT_KEY"),
        DB_CONNECTION=os.getenv("KANG_LAO_DB", LOCAL_CONNECTION),
        PERMANENT_SESSION_LIFETIME=timedelta(minutes=30),
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
        SESSION_COOKIE_SECURE=os.getenv("KANG_LAO_HTTPS") == "1",
        MAX_CONTENT_LENGTH=100_000,
    )
    if config:
        app.config.update(config)
    if not app.config["SECRET_KEY"] or not app.config["CONTACT_KEY"]:
        raise RuntimeError("请先运行 python -m kanglao configure 生成本机配置。")
    app.extensions["contacts"] = Fernet(app.config["CONTACT_KEY"].encode())
    app.teardown_appcontext(close_db)
    app.before_request(check_csrf)
    app.jinja_env.globals.update(app_name=APP_NAME, csrf_token=csrf_token, role_names=ROLE_NAMES,
                                 cell_display=cell_display, status_class=status_class,
                                 status_label=status_label)

    from . import account, archive, health, home, oversight, services, subsidy
    for module in (account, home, archive, services, health, subsidy, oversight):
        app.register_blueprint(module.bp)

    @app.get("/healthz")
    def readiness():
        one("SELECT 1 AS ok")
        return {"ready": True}

    @app.errorhandler(400)
    @app.errorhandler(403)
    @app.errorhandler(404)
    def http_error(error):
        messages = {403: "当前账号无权查看或操作这条记录。", 404: "没有找到对应页面或记录。"}
        return render_template("error.html", title="操作未完成",
                               message=messages.get(error.code, error.description)), error.code

    @app.errorhandler(ValueError)
    def invalid_input(_exception):
        flash("输入格式不正确，请核对字段后重试。", "error")
        return form_error_redirect() if request.method == "POST" else http_error(BadRequest("输入格式不正确。"))

    def form_error_redirect():
        referrer = urlsplit(request.referrer or "")
        if referrer.netloc == request.host and referrer.path.startswith("/") and not referrer.path.startswith("//"):
            return redirect(referrer.path + ("?" + referrer.query if referrer.query else ""))
        if request.url_rule and "GET" in request.url_rule.methods:
            return redirect(request.path)
        return redirect(url_for("home.index"))

    @app.errorhandler(mssql_python.Error)
    def database_error(error):
        app.logger.warning("SQL 操作失败，错误类型为 %s", type(error).__name__)
        if request.method == "POST" and not isinstance(error, mssql_python.InterfaceError):
            flash("操作未保存，请检查状态、重复编号、权限和关联数据后重试。", "error")
            return form_error_redirect()
        return render_template("error.html", title="数据库暂不可用",
                               message="请确认 SQL Server 已启动，并检查本机连接配置。"), 503

    @app.after_request
    def protect_response(response):
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "same-origin"
        if request.endpoint != "static":
            response.headers["Cache-Control"] = "no-store"
        return response

    return app
