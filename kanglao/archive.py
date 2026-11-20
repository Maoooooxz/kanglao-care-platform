import csv
import io
import re
from datetime import date
from decimal import Decimal, InvalidOperation
from secrets import token_hex

from flask import Blueprint, abort, current_app, flash, g, redirect, request, url_for

from .db import execute, execute_many, one, query, transaction
from .web import beijing_today, field, roles, workspace

bp = Blueprint("archive", __name__, url_prefix="/archives")
READERS = ("community", "family", "resident", "street", "civil")
SUBSIDY_CATEGORIES = {"GENERAL": "普通", "LOW_INCOME": "低保"}
ABILITY_LEVELS = ("能力完好", "轻度失能", "中度失能", "重度失能", "完全失能")


def community_title(row):
    if not row["CityName"]:
        return row["CommunityName"]
    district = row["AreaName"] or ""
    return f"{row['CityName']}{district}{row['StreetName'] or ''} · {row['CommunityName']}"


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
        " e.Tags,e.SubsidyCategory,e.IsActive,e.CommunityId,"
        " c.Name AS CommunityName,c.CityName,c.AreaName,c.StreetName"
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
    )


def new_archive(values):
    id_number = values.get("id_number", "").strip().upper()
    number = values.get("archive_no", "").strip().upper()
    if not re.fullmatch(r"[0-9]{17}[0-9X]", id_number) or not re.fullmatch(r"[A-Z0-9_-]{1,20}", number):
        raise ValueError("证件号或档案编号格式错误")
    return id_number, number, *archive_values(values)


INSERT_ARCHIVE = """INSERT dbo.ElderArchive
    (IdNumber,ArchiveNo,FullName,BirthDate,Address,GuardianName,GuardianContactEncrypted,Tags,SubsidyCategory,
     Latitude,Longitude,CommunityId)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?)"""


def save_archives(records):
    identities = sorted(record[0] for record in records)
    with transaction():
        if len(identities) != len(set(identities)) or any(
            one("SELECT 1 AS Present FROM dbo.ElderArchive WITH (UPDLOCK,HOLDLOCK) WHERE IdNumber=?", identity)
            for identity in identities
        ):
            flash("身份证号重复，档案未保存。已在其他社区建档的老人请联系原社区办理迁移。", "error")
            return False
        community = g.user["community_id"]
        location = community_location(community)
        execute_many(INSERT_ARCHIVE, [(*record, *location, community) for record in records])
    return True


def community_location(community_id):
    row = one("SELECT Latitude,Longitude FROM dbo.Community WHERE CommunityId=?", community_id)
    if row is None:
        abort(400, description="请选择有效的社区。")
    return row["Latitude"], row["Longitude"]


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
            if save_archives([new_archive(dict(zip(columns, row))) for row in entries]):
                flash(f"已批量保存 {len(entries)} 份档案。", "success")
        elif request.form.get("op") == "create":
            if save_archives([new_archive(request.form)]):
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
        f"SELECT e.ArchiveNo,e.FullName,c.Name AS CommunityName,c.CityName,c.AreaName,c.StreetName,"
        f" a.AssessmentStatus,e.IsActive FROM {tables} "
        f"WHERE {conditions} ORDER BY e.ArchiveNo OFFSET ? ROWS FETCH NEXT 12 ROWS ONLY",
        *params, (page - 1) * 12,
    )
    panels = [dict(
        title="老人档案", columns=["档案编号", "姓名", "所属社区", "评估状态", "档案状态"],
        rows=[(r["ArchiveNo"], r["FullName"], community_title(r), r["AssessmentStatus"],
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
            if op in {"transfer", "assessment"}:
                archive_no = current_archive(archive_no)["ArchiveNo"]
                execute("EXEC dbo.usp_ServiceLock 'archive',?", archive_no)
            existing = current_archive(archive_no, lock=True)
            if op == "edit":
                execute("""UPDATE dbo.ElderArchive SET FullName=?,BirthDate=?,Address=?,GuardianName=?,
                        GuardianContactEncrypted=?,Tags=?,SubsidyCategory=? WHERE ArchiveNo=?""",
                        *archive_values(request.form, default_category=existing["SubsidyCategory"]), archive_no)
            elif op == "transfer":
                target = int(request.form["community"])
                execute("EXEC dbo.usp_TransferElderArchive ?,?,?,?,?,?,?", archive_no, g.user["id"],
                        target, bounded(request.form.get("new_address", ""), 200), *community_location(target),
                        bounded(request.form.get("reason", ""), 250))
            elif op == "toggle":
                execute("UPDATE dbo.ElderArchive SET IsActive=? WHERE ArchiveNo=?",
                        not existing["IsActive"], archive_no)
            elif op == "assessment":
                score = coordinate(request.form["score"], 9999)
                valid_through = request.form.get("valid_through", "").strip()
                execute("EXEC dbo.usp_RecordAbilityAssessment ?,?,?,?,?,?,?,?",
                        "AS-" + token_hex(8), archive_no, request.form["scale"], score,
                        bounded(request.form["level"], 20), g.user["display_name"],
                        date.fromisoformat(request.form["assessment_date"]),
                        date.fromisoformat(valid_through) if valid_through else None)
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
    can_view_address = g.user["role"] in {"community", "family", "resident"}
    panels = [
        dict(title="档案概要", columns=["编号", "姓名", "社区", "证件号", "出生日期", "补贴对象类别"],
             rows=[(archive_no, data["FullName"], community_title(data), masked["MaskedIdNumber"], data["BirthDate"],
                    SUBSIDY_CATEGORIES[data["SubsidyCategory"]])],
             text=f"居住地址：{data['Address']}" if can_view_address else None),
        dict(title="能力评估历史", columns=["评估编号", "量表", "得分", "等级", "评估员", "评估日", "有效截止"],
             rows=[tuple(row.values()) for row in history]),
    ]
    if g.user["role"] == "community":
        if data["GuardianContactEncrypted"]:
            data["contact"] = current_app.extensions["contacts"].decrypt(
                bytes(data["GuardianContactEncrypted"])).decode()
        communities = query(
            "SELECT CommunityId,Name AS CommunityName,CityName,AreaName,StreetName FROM dbo.Community "
            "WHERE CommunityId<>? ORDER BY Name", data["CommunityId"],
        )
        transfers = query(
            "SELECT FromCommunityName,ToCommunityName,OccurredAt,"
            " OperatorName,TransferReason FROM dbo.v_ElderTransferHistory WHERE ArchiveNo=? ORDER BY AuditId DESC",
            archive_no,
        )
        today = beijing_today()
        panels.extend([
            dict(title="登记复评" if history else "登记首次评估", anchor="assessment-form", form=[
                field("scale", "量表", "select", [("ADL", "ADL 日常生活能力"), ("MMSE", "MMSE 简易智能状态")]),
                field("score", "评估得分", "number", min=0, max=9999, step="0.01"),
                field("level", "能力等级", "select", [(level, level) for level in ABILITY_LEVELS]),
                field("assessment_date", "评估日期", "date", value=today),
                field("valid_through", "有效期截止（可留空）", "date", required=False),
            ], text="未满 80 岁最长 180 天，满 80 岁最长 90 天。复评会保留历次记录，暂停的计划须经复核后恢复。",
                 hidden={"op": "assessment"}, submit="保存评估"),
            dict(title="维护档案", form=archive_form(data), hidden={"op": "edit"}, submit="保存修改"),
            dict(title="跨社区迁移", text="迁移会更新原档案，暂停照护计划并取消原社区尚未开始的预约。",
                 form=[
                     field("community", "迁入社区", "select", [
                         (c["CommunityId"], community_title(c)) for c in communities]),
                     field("new_address", "新居住地址", maxlength=200),
                     field("reason", "迁移原因", maxlength=250),
                 ], hidden={"op": "transfer"}, submit="迁移原档案"),
            dict(title="迁移记录", columns=["原社区", "迁入社区", "迁移时间", "办理人", "原因"],
                 rows=[tuple(row.values()) for row in transfers]),
            dict(title="档案状态", form=[], hidden={"op": "toggle"},
                 submit="停用档案" if data["IsActive"] else "恢复档案"),
        ])
    return workspace(data["FullName"], f"档案 {archive_no} · {data['CommunityName']}", panels)
