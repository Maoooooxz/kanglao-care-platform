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
from werkzeug.security import check_password_hash, generate_password_hash

from . import APP_NAME, LOCAL_CONNECTION, ROOT, create_app
from .db import execute, one, query, transaction

MIGRATIONS = (
    "01_init.sql", "03_add_ability_assessment.sql", "05_platform.sql",
    "06_services.sql", "07_health.sql", "08_subsidy.sql", "10_course_completion.sql", "11_community_workflows.sql",
)
DEMO_BEFORE_USERS = ("05_demo_platform.sql", "06_demo_services.sql")
DEMO_AFTER_USERS = ("07_demo_health.sql", "08_demo_subsidy.sql", "10_demo_course_completion.sql",
                    "11_demo_beijing_workflows.sql", "12_demo_more_archives.sql")
CHECKS = ("02_verify.sql", "04_verify_assessment.sql", "06_verify_services.sql",
          "07_verify_health.sql", "08_verify_subsidy.sql", "10_verify_course_completion.sql")
DEMO_COMMUNITY_PASSWORD = "123456"


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
        print("已生成本机 .env。其他演示账号密码保存在 KANG_LAO_DEMO_PASSWORD。")


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
    elder = one("SELECT FullName,GuardianName FROM dbo.ElderArchive WHERE ArchiveNo='E0001' AND LEFT(IdNumber,6)='000000'")
    community_demo = one("SELECT CommunityId,District FROM dbo.Community WHERE CommunityId=1 AND District=N'海淀演示区'")
    worker = one("SELECT WorkerId,AgencyId,Name FROM dbo.Worker WHERE WorkerNo='DEMO-WORKER-001'")
    if elder is None or worker is None or community_demo is None:
        raise RuntimeError("找不到用于初始化演示账号的合成档案或护工。")
    users = [
        ("community", "蔡元涵", "社区管理员", "community", community_demo["CommunityId"], None, None, None, None),
        ("family", elder["GuardianName"] or "周敏", "示例家属", "family", None, "E0001", None, None, None),
        ("resident", elder["FullName"], "示例老人", "resident", None, "E0001", None, None, None),
        ("caregiver", worker["Name"], "示例护工", "caregiver", None, None, worker["WorkerId"], None, None),
        ("agency", "林佳音", "机构负责人", "agency", None, None, None, worker["AgencyId"], None),
        ("street", "陈明远", "街道审核员", "street", None, None, None, None, community_demo["District"]),
        ("civil", "贺晓岚", "民政监管员", "civil", None, None, None, None, community_demo["District"]),
    ]
    for row in query("SELECT CommunityId,Name FROM dbo.Community WHERE CommunityId BETWEEN 1 AND 20"):
        number = row["CommunityId"]
        users.append((f"community{number:02d}", f'{row["Name"]}服务台', f"演示社区管理员 {number}", "community",
                      number, None, None, None, None))
    for row in query(
        "SELECT ArchiveNo,FullName,GuardianName FROM dbo.ElderArchive WHERE ArchiveNo BETWEEN 'E0001' AND 'E0020' "
        "AND LEFT(IdNumber, 6)='000000'"
    ):
        archive = row["ArchiveNo"]
        users.append((f"family{archive[1:]}", row["GuardianName"] or f'{row["FullName"]}的家属',
                      f"演示家属 {archive}", "family",
                      None, archive, None, None, None))
    for row in query("""SELECT w.WorkerId,w.AgencyId,w.WorkerNo,w.Name,a.Name AS AgencyName
                      FROM dbo.Worker w JOIN dbo.Agency a ON a.AgencyId=w.AgencyId
                      WHERE w.WorkerNo LIKE 'DEMO-WORKER-[0-9][0-9][0-9]'"""):
        suffix = row["WorkerNo"][-3:]
        users.append((f"caregiver{suffix}", row["Name"], f"演示护工 {suffix}", "caregiver",
                      None, None, row["WorkerId"], None, None))
        users.append((f"agency{suffix}", f'{row["AgencyName"]}值班室', f"演示机构 {suffix}", "agency",
                      None, None, None, row["AgencyId"], None))
    with transaction():
        for username, name, old_name, role, community, archive, worker_id, agency, district in users:
            existing = one("""SELECT UserId,DisplayName,PasswordHash,Role,CommunityId,ArchiveNo,WorkerId,AgencyId,District
                            FROM dbo.AppUser WITH (UPDLOCK,HOLDLOCK) WHERE Username=?""", username)
            if existing:
                scoped_fields = ("Role", "CommunityId", "ArchiveNo", "WorkerId", "AgencyId", "District")
                if tuple(existing[key] for key in scoped_fields) != (role, community, archive, worker_id, agency, district):
                    if username == "community":
                        raise RuntimeError("现有 community 账号不属于合成社区，未重置其密码。")
                    continue
                if existing["DisplayName"] != name and (username == "community" or existing["DisplayName"] == old_name):
                    execute("UPDATE dbo.AppUser SET DisplayName=? WHERE UserId=?", name, existing["UserId"])
                if username == "community" and not check_password_hash(existing["PasswordHash"], DEMO_COMMUNITY_PASSWORD):
                    execute("UPDATE dbo.AppUser SET PasswordHash=?,FailedAttempts=0,LockedUntil=NULL WHERE UserId=?",
                            generate_password_hash(DEMO_COMMUNITY_PASSWORD), existing["UserId"])
                continue
            account_password = DEMO_COMMUNITY_PASSWORD if username == "community" else password
            execute(
                "INSERT dbo.AppUser(Username,DisplayName,PasswordHash,Role,CommunityId,ArchiveNo,WorkerId,AgencyId,District) "
                "VALUES (?,?,?,?,?,?,?,?,?)", username, name, generate_password_hash(account_password),
                role, community, archive, worker_id, agency, district,
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
    print("演示账号已准备：community 使用指定的本机演示密码；其他账号沿用 .env 设置。")


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
    parser = argparse.ArgumentParser(description=f"{APP_NAME} SQL Server 工具")
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
        print(f"{APP_NAME} http://127.0.0.1:{args.port}", flush=True)
        serve(app, host="127.0.0.1", port=args.port)


if __name__ == "__main__":
    main()
