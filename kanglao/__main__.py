import argparse
import os
import re
import subprocess
import tempfile
import time
from pathlib import Path
from secrets import token_urlsafe

from cryptography.fernet import Fernet
from dotenv import load_dotenv
from waitress import serve
from werkzeug.security import generate_password_hash

from . import LOCAL_CONNECTION, ROOT, create_app
from .db import execute, one, query, transaction

MIGRATIONS = (
    "01_init.sql", "03_add_ability_assessment.sql", "05_platform.sql",
    "06_services.sql", "07_health.sql", "08_subsidy.sql", "10_course_completion.sql",
)
DEMO_BEFORE_USERS = ("05_demo_platform.sql", "06_demo_services.sql")
DEMO_AFTER_USERS = ("07_demo_health.sql", "08_demo_subsidy.sql", "10_demo_course_completion.sql")
CHECKS = ("02_verify.sql", "04_verify_assessment.sql", "06_verify_services.sql",
          "07_verify_health.sql", "08_verify_subsidy.sql", "10_verify_course_completion.sql")


def configure():
    config_path = ROOT / ".env"
    try:
        with config_path.open("x", encoding="utf-8") as stream:
            stream.write(
                f"KANG_LAO_SECRET={token_urlsafe(48)}\n"
                f"KANG_LAO_CONTACT_KEY={Fernet.generate_key().decode()}\n"
                f"KANG_LAO_DEMO_PASSWORD={token_urlsafe(18)}\n"
            )
    except FileExistsError:
        print("已存在 .env，本机配置继续使用现有值。")
    else:
        print("已生成本机 .env。演示账号密码保存在 KANG_LAO_DEMO_PASSWORD。")


def database_name(value):
    if not re.fullmatch(r"KanglaoCourse(?:_[A-Za-z0-9_]{1,40})?", value):
        raise argparse.ArgumentTypeError("项目数据库名须为 KanglaoCourse 或其测试后缀。")
    return value


def database_config(database):
    if database == "KanglaoCourse":
        return {}
    return {"DB_CONNECTION": LOCAL_CONNECTION.replace("Database=KanglaoCourse;", f"Database={database};")}


def apply_sql(filename, database):
    original = ROOT / "sql" / filename
    instance = os.getenv("KANG_LAO_SQLCMD_SERVER", r"lpc:.\SQLEXPRESS")
    args = ["sqlcmd", "-S", instance, "-E", "-C", "-I", "-b", "-f", "65001", "-l", "15", "-i"]
    if database == "KanglaoCourse":
        subprocess.run([*args, str(original)], check=True, cwd=ROOT)
    else:
        with tempfile.TemporaryDirectory(prefix="kanglao-sql-") as folder:
            target = Path(folder) / filename
            target.write_text(original.read_text(encoding="utf-8").replace("KanglaoCourse", database),
                              encoding="utf-8")
            subprocess.run([*args, str(target)], check=True, cwd=ROOT)


def seed_users():
    password = os.getenv("KANG_LAO_DEMO_PASSWORD")
    if not password:
        raise RuntimeError("演示配置需要 KANG_LAO_DEMO_PASSWORD。")
    elder = one("SELECT e.CommunityId,c.District FROM dbo.ElderArchive e "
                "JOIN dbo.Community c ON c.CommunityId=e.CommunityId WHERE e.ArchiveNo='E0001'")
    worker = one("SELECT WorkerId, AgencyId FROM dbo.Worker WHERE WorkerNo='DEMO-WORKER-001'")
    users = [
        ("community", "社区管理员", "community", elder["CommunityId"], None, None, None, None),
        ("family", "示例家属", "family", None, "E0001", None, None, None),
        ("resident", "示例老人", "resident", None, "E0001", None, None, None),
        ("caregiver", "示例护工", "caregiver", None, None, worker["WorkerId"], None, None),
        ("agency", "机构负责人", "agency", None, None, None, worker["AgencyId"], None),
        ("street", "街道审核员", "street", None, None, None, None, elder["District"]),
        ("civil", "民政监管员", "civil", None, None, None, None, elder["District"]),
    ]
    for row in query("SELECT CommunityId FROM dbo.Community WHERE CommunityId BETWEEN 1 AND 20"):
        number = row["CommunityId"]
        users.append((f"community{number:02d}", f"演示社区管理员 {number}", "community",
                      number, None, None, None, None))
    for row in query(
        "SELECT ArchiveNo FROM dbo.ElderArchive WHERE ArchiveNo BETWEEN 'E0001' AND 'E0020' "
        "AND LEFT(IdNumber, 6)='000000'"
    ):
        archive = row["ArchiveNo"]
        users.append((f"family{archive[1:]}", f"演示家属 {archive}", "family",
                      None, archive, None, None, None))
    for row in query("SELECT WorkerId,AgencyId,WorkerNo FROM dbo.Worker WHERE WorkerNo LIKE 'DEMO-WORKER-%'"):
        suffix = row["WorkerNo"][-3:]
        users.append((f"caregiver{suffix}", f"演示护工 {suffix}", "caregiver",
                      None, None, row["WorkerId"], None, None))
        users.append((f"agency{suffix}", f"演示机构 {suffix}", "agency",
                      None, None, None, row["AgencyId"], None))
    with transaction():
        for username, name, role, community, archive, worker, agency, district in users:
            if one("SELECT UserId FROM dbo.AppUser WITH (UPDLOCK,HOLDLOCK) WHERE Username=?", username):
                continue
            execute(
                "INSERT dbo.AppUser(Username,DisplayName,PasswordHash,Role,CommunityId,ArchiveNo,WorkerId,AgencyId,District) "
                "VALUES (?,?,?,?,?,?,?,?,?)", username, name, generate_password_hash(password),
                role, community, archive, worker, agency, district,
            )
        execute("""
            UPDATE visit SET ConfirmedBy=signer.UserId, ConfirmationHash=dbo.fn_ServiceConfirmationHash(
                visit.OrderId,signer.UserId,visit.ConfirmedAt,visit.ConfirmationText)
            FROM dbo.ServiceVisit visit JOIN dbo.ServiceOrder orders ON orders.OrderId=visit.OrderId
            CROSS APPLY (
                SELECT TOP (1) UserId FROM dbo.AppUser
                WHERE Role='family' AND Active=1 AND ArchiveNo=orders.ArchiveNo
                ORDER BY CASE WHEN Username='family' THEN 0 ELSE 1 END,UserId
            ) signer
            WHERE orders.OrderNo LIKE 'DEMO-ORDER-%' AND visit.ConfirmationText=N'模拟家属电子签字'
              AND visit.ConfirmedBy<>signer.UserId
        """)
    print("演示账号已准备。使用 .env 中的演示密码登录。")


def process_jobs(app, watch, simulate_devices=False):
    jobs = (
        ("评估到期及派单时限", "EXEC dbo.usp_ProcessServiceTimeouts"),
        ("健康告警及应急时限", "EXEC dbo.usp_ProcessHealthTimeouts"),
    )
    if simulate_devices:
        jobs = (("演示设备上报", "EXEC dbo.usp_SimulateHealthReadings"), *jobs)
    while True:
        first_error = None
        for title, statement in jobs:
            try:
                with app.app_context():
                    execute(statement)
                print(f"已检查{title}。", flush=True)
            except Exception as error:
                first_error = first_error or error
                app.logger.exception("%s检查失败。", title)
        if not watch:
            if first_error is not None:
                raise first_error
            return
        time.sleep(60)


def main():
    parser = argparse.ArgumentParser(description="康老系统 SQL Server 工具")
    parser.add_argument("--database", type=database_name, default="KanglaoCourse")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("configure", help="生成本机演示账号和加密配置")
    commands.add_parser("install", help="建库或应用增量迁移")
    commands.add_parser("seed-demo", help="写入合成业务数据和演示账号")
    commands.add_parser("verify-sql", help="运行 SQL 业务与回归测试")
    web = commands.add_parser("serve", help="在本机启动网页")
    web.add_argument("--port", default=8080, type=int)
    jobs = commands.add_parser("jobs", help="扫描到期和超时")
    jobs.add_argument("--watch", action="store_true", help="每分钟执行一次")
    jobs.add_argument("--simulate-devices", action="store_true", help="只为合成演示设备生成体征数据")
    args = parser.parse_args()
    load_dotenv(ROOT / ".env")
    if args.command == "configure":
        configure()
        return
    if args.command in {"install", "verify-sql"}:
        for filename in MIGRATIONS if args.command == "install" else CHECKS:
            print(f"执行 {filename}", flush=True)
            apply_sql(filename, args.database)
        return

    app = create_app(database_config(args.database))
    if args.command == "seed-demo":
        for filename in DEMO_BEFORE_USERS:
            apply_sql(filename, args.database)
        with app.app_context():
            seed_users()
        for filename in DEMO_AFTER_USERS:
            apply_sql(filename, args.database)
    elif args.command == "jobs":
        process_jobs(app, args.watch, args.simulate_devices)
    else:
        print(f"康老工作台 http://127.0.0.1:{args.port}", flush=True)
        serve(app, host="127.0.0.1", port=args.port)


if __name__ == "__main__":
    main()
