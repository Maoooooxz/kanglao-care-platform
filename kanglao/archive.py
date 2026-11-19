import csv
import io
import re
from datetime import date, timedelta
from decimal import Decimal, InvalidOperation
from secrets import token_hex

from flask import Blueprint, abort, current_app, flash, g, redirect, request, url_for

from .db import execute, execute_many, one, query, transaction
from .web import beijing_today, field, roles, workspace

bp = Blueprint("archive", __name__, url_prefix="/archives")
READERS = ("community", "family", "resident", "street", "civil")
SUBSIDY_CATEGORIES = {"GENERAL": "普通", "LOW_INCOME": "低保"}
ABILITY_LEVELS = ("能力完好", "轻度失能", "中度失能", "重度失能", "完全失能")


def archive_scope():
    viewer = g.user
    if viewer["role"] == "community":
        return "e.CommunityId=?", (viewer["community_id"],)
    if viewer["role"] in {"family", "resident"}:
        return "e.ArchiveNo=?", (viewer["archive_no"],)
    return "c.District=?", (viewer["district"],)


def current_archive(number, *, lock=False):
    scope, params = archive_scope()
    table = "dbo.ElderArchive e WITH (UPDLOCK,HOLDLOCK)" if lock else "dbo.ElderArchive e"
    row = one(
        "SELECT e.ArchiveNo,e.FullName,e.BirthDate,e.Address,e.GuardianName,e.GuardianContactEncrypted,"
        " e.Tags,e.SubsidyCategory,e.IsActive,e.Latitude,e.Longitude,e.CommunityId,c.Name AS CommunityName"
        f" FROM {table} JOIN dbo.Community c ON c.CommunityId=e.CommunityId"
        f" WHERE e.ArchiveNo=? AND {scope}", number, *params,
    )
    if row is None:
        abort(404)
    return row


def bounded(value, limit, *, optional=False):
    result = value.strip()
    if len(result) > limit or (not optional and not result):
        raise ValueError("长度不合法")
    return result


def coordinate(value, limit):
    try:
        result = Decimal(value)
        if not result.is_finite() or not -limit <= result <= limit:
            raise ValueError("坐标超出范围")
        return result
    except InvalidOperation as error:
        raise ValueError("坐标不合法") from error


def archive_values(values, *, default_category="GENERAL"):
    dob = date.fromisoformat(values.get("birth_date", ""))
    if dob > beijing_today():
        raise ValueError("出生日期晚于当天")
    phone = bounded(values.get("guardian_contact", ""), 64, optional=True)
    encrypted = current_app.extensions["contacts"].encrypt(phone.encode()) if phone else None
    category = values.get("subsidy_category", default_category)
    if category not in SUBSIDY_CATEGORIES:
        raise ValueError("请选择有效的补贴对象类别")
    return (
        bounded(values.get("name", ""), 100), dob,
        bounded(values.get("address", ""), 200),
        bounded(values.get("guardian", ""), 100, optional=True) or None, encrypted,
        bounded(values.get("tags", ""), 200, optional=True) or None,
        category,
        coordinate(values.get("latitude", "40.008"), 90),
        coordinate(values.get("longitude", "116.341"), 180),
    )


def new_archive(values):
    id_number = values.get("id_number", "").strip().upper()
    number = values.get("archive_no", "").strip().upper()
    if not re.fullmatch(r"[0-9]{17}[0-9X]", id_number) or not re.fullmatch(r"[A-Z0-9_-]{1,20}", number):
        raise ValueError("证件号或档案编号格式错误")
    return id_number, number, *archive_values(values), g.user["community_id"]


INSERT_ARCHIVE = """INSERT dbo.ElderArchive
    (IdNumber,ArchiveNo,FullName,BirthDate,Address,GuardianName,GuardianContactEncrypted,Tags,SubsidyCategory,
     Latitude,Longitude,CommunityId)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?)"""


def archive_form(data=None):
    data = data or {}
    return [
        field("name", "姓名", value=data.get("FullName"), maxlength=100),
        field("birth_date", "出生日期", "date", value=data.get("BirthDate")),
        field("address", "居住地址", value=data.get("Address"), maxlength=200),
        field("guardian", "监护人", value=data.get("GuardianName"), required=False, maxlength=100),
        field("guardian_contact", "监护人联系方式", "tel", value=data.get("contact"),
              required=False, maxlength=64),
        field("tags", "照护标签", value=data.get("Tags"), required=False, maxlength=200),
        field("subsidy_category", "补贴对象类别", "select", SUBSIDY_CATEGORIES.items(),
              value=data.get("SubsidyCategory", "GENERAL")),
        field("latitude", "模拟纬度", "number", value=data.get("Latitude", "40.008"),
              step="0.000001", min="-90", max="90"),
        field("longitude", "模拟经度", "number", value=data.get("Longitude", "116.341"),
              step="0.000001", min="-180", max="180"),
    ]


@bp.route("/", methods=["GET", "POST"])
@roles(*READERS)
def index():
    if request.method == "POST":
        if g.user["role"] != "community":
            abort(403)
        if request.form.get("op") == "bulk":
            columns = ("id_number", "archive_no", "name", "birth_date", "address")
            entries = list(csv.reader(io.StringIO(request.form.get("csv_text", "").strip())))
            if not 1 <= len(entries) <= 50 or any(len(row) != len(columns) for row in entries):
                raise ValueError("批量输入每行需 5 列，单次最多 50 行")
            with transaction():
                execute_many(INSERT_ARCHIVE, [new_archive(dict(zip(columns, row))) for row in entries])
            flash(f"已批量保存 {len(entries)} 份档案。", "success")
        elif request.form.get("op") == "create":
            execute(INSERT_ARCHIVE, *new_archive(request.form))
            flash("老人档案已建立。", "success")
        else:
            abort(400)
        return redirect(url_for("archive.index"))

    search = request.args.get("q", "").strip()[:60]
    page = max(1, min(100_000, request.args.get("page", 1, type=int)))
    scope, params = archive_scope()
    conditions = f"{scope} AND (e.ArchiveNo LIKE ? OR e.FullName LIKE ?)"
    params = (*params, f"%{search}%", f"%{search}%")
    tables = ("dbo.ElderArchive e JOIN dbo.Community c ON c.CommunityId=e.CommunityId "
              "JOIN dbo.v_CurrentAbilityAssessment a ON a.ArchiveNo=e.ArchiveNo")
    count = one(f"SELECT COUNT(*) AS n FROM {tables} WHERE {conditions}", *params)["n"]
    page = min(page, max(1, (count + 11) // 12))
    rows = query(
        f"SELECT e.ArchiveNo,e.FullName,c.Name,a.AssessmentStatus,e.IsActive FROM {tables} "
        f"WHERE {conditions} ORDER BY e.ArchiveNo OFFSET ? ROWS FETCH NEXT 12 ROWS ONLY",
        *params, (page - 1) * 12,
    )
    panels = [dict(
        title="老人档案", columns=["档案编号", "姓名", "所属社区", "评估状态", "档案状态"],
        rows=[(r["ArchiveNo"], r["FullName"], r["Name"], r["AssessmentStatus"],
               "在册" if r["IsActive"] else "已停用") for r in rows],
        row_links=[url_for("archive.detail", archive_no=r["ArchiveNo"]) for r in rows],
        search=dict(value=search, placeholder="搜索档案编号或姓名"),
        links=[(label, url_for("archive.index", q=search, page=target)) for label, target in (
            ("上一页", page - 1), ("下一页", page + 1)) if 1 <= target <= (count + 11) // 12],
        text=f"共 {count} 条，第 {page} 页",
    )]
    if g.user["role"] == "community":
        panels.extend([
            dict(title="新建档案", form=[
                field("id_number", "模拟身份证号", maxlength=18),
                field("archive_no", "档案编号", maxlength=20), *archive_form(),
            ], hidden={"op": "create"}, submit="保存档案"),
            dict(title="批量建档", text="每行依次填写模拟身份证号、档案编号、姓名、出生日期和地址，用英文逗号分隔。",
                 form=[field("csv_text", "档案数据", "textarea")],
                 hidden={"op": "bulk"}, submit="批量保存"),
        ])
    return workspace("老人档案", "管理社区档案、能力评估和照护基础信息。", panels)


@bp.route("/<archive_no>", methods=["GET", "POST"])
@roles(*READERS)
def detail(archive_no):
    if request.method == "POST":
        if g.user["role"] != "community":
            abort(403)
        op = request.form.get("op")
        with transaction():
            existing = current_archive(archive_no, lock=True)
            if op == "edit":
                execute("""UPDATE dbo.ElderArchive SET FullName=?,BirthDate=?,Address=?,GuardianName=?,
                        GuardianContactEncrypted=?,Tags=?,SubsidyCategory=?,Latitude=?,Longitude=? WHERE ArchiveNo=?""",
                        *archive_values(request.form, default_category=existing["SubsidyCategory"]), archive_no)
            elif op == "transfer":
                target = int(request.form["community"])
                execute("EXEC dbo.usp_TransferElderArchive ?,?,?", archive_no,
                        existing["CommunityId"], target)
            elif op == "toggle":
                execute("UPDATE dbo.ElderArchive SET IsActive=? WHERE ArchiveNo=?",
                        not existing["IsActive"], archive_no)
            elif op == "assessment":
                score = coordinate(request.form["score"], 9999)
                execute("EXEC dbo.usp_RecordAbilityAssessment ?,?,?,?,?,?,?,?",
                        "AS-" + token_hex(8), archive_no, request.form["scale"], score,
                        bounded(request.form["level"], 20), g.user["display_name"],
                        date.fromisoformat(request.form["assessment_date"]),
                        date.fromisoformat(request.form["valid_through"]))
            else:
                abort(400)
        flash("档案操作已保存。", "success")
        if op == "transfer":
            return redirect(url_for("archive.index"))
        return redirect(url_for("archive.detail", archive_no=archive_no))

    data = current_archive(archive_no)
    history = query(
        "SELECT AssessmentNo,ScaleCode,Score,AbilityLevel,EvaluatorName,AssessmentDate,ValidThrough "
        "FROM dbo.v_AbilityAssessmentHistory WHERE ArchiveNo=? ORDER BY AssessmentDate DESC,AssessmentId DESC",
        archive_no,
    )
    masked = one("SELECT MaskedIdNumber FROM dbo.v_ElderArchiveSummary WHERE ArchiveNo=?", archive_no)
    panels = [
        dict(title="档案概要", columns=["编号", "姓名", "社区", "证件号", "出生日期", "补贴对象类别"],
             rows=[(archive_no, data["FullName"], data["CommunityName"], masked["MaskedIdNumber"], data["BirthDate"],
                    SUBSIDY_CATEGORIES[data["SubsidyCategory"]])]),
        dict(title="能力评估历史", columns=["评估编号", "量表", "得分", "等级", "评估员", "评估日", "有效截止"],
             rows=[tuple(row.values()) for row in history]),
    ]
    if g.user["role"] == "community":
        if data["GuardianContactEncrypted"]:
            data["contact"] = current_app.extensions["contacts"].decrypt(
                bytes(data["GuardianContactEncrypted"])).decode()
        communities = query("SELECT CommunityId,Name FROM dbo.Community WHERE CommunityId<>? ORDER BY Name",
                            data["CommunityId"])
        today = beijing_today()
        panels.extend([
            dict(title="登记能力评估", form=[
                field("scale", "量表", "select", [("ADL", "ADL 日常生活能力"), ("MMSE", "MMSE 简易智能状态")]),
                field("score", "评估得分", "number", min=0, max=9999, step="0.01"),
                field("level", "能力等级", "select", [(level, level) for level in ABILITY_LEVELS]),
                field("assessment_date", "评估日期", "date", value=today),
                field("valid_through", "有效期截止", "date", value=today + timedelta(days=90)),
            ], hidden={"op": "assessment"}, submit="保存评估"),
            dict(title="维护档案", form=archive_form(data), hidden={"op": "edit"}, submit="保存修改"),
            dict(title="跨社区迁移", form=[field("community", "目标社区", "select", [
                (c["CommunityId"], c["Name"]) for c in communities])],
                 hidden={"op": "transfer"}, submit="迁移原档案"),
            dict(title="档案状态", form=[], hidden={"op": "toggle"},
                 submit="停用档案" if data["IsActive"] else "恢复档案"),
        ])
    return workspace(data["FullName"], f"档案 {archive_no} · {data['CommunityName']}", panels)
