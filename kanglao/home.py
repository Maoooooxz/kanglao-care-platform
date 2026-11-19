from datetime import timedelta

from flask import Blueprint, g, render_template

from .archive import READERS, archive_scope
from .db import one, query
from .web import beijing_today, roles

bp = Blueprint("home", __name__)
WORKSPACES = [
    ("档案", "/archives/", "档", "老人档案与能力评估", READERS),
    ("照护计划", "/services/plans", "护", "服务包与照护计划安排", ("community", "family", "resident", "caregiver", "agency", "street", "civil")),
    ("订单", "/services/orders", "单", "预约、派单与上门服务", ("community", "family", "resident", "caregiver", "agency", "street", "civil")),
    ("人员与排班", "/services/workers", "班", "护工资质、排班与工时复核", ("community", "caregiver", "agency", "street", "civil")),
    ("健康与应急", "/health/", "健", "监测设备、异常与应急响应", ("community", "family", "resident", "caregiver", "agency", "street", "civil")),
    ("补贴与抽查", "/subsidy/", "补", "补贴申报、分级审核和服务监管", ("community", "family", "resident", "caregiver", "agency", "street", "civil")),
    ("抽查公示", "/oversight/bulletins", "公", "查看已发布的脱敏抽查汇总", ("community", "family", "resident", "caregiver", "agency", "street", "civil")),
]


@bp.app_context_processor
def navigation():
    if not g.get("user"):
        return {"navigation": ()}
    return {"navigation": [item[:4] for item in WORKSPACES if g.user["role"] in item[4]]}


@bp.get("/")
@roles()
def index():
    stats = []
    recent = []
    reassessments = None
    if g.user["role"] in READERS:
        scope, params = archive_scope()
        data = one(
            "SELECT COUNT(*) AS total, COUNT(CASE WHEN a.AssessmentStatus=N'有效' THEN 1 END) AS valid, "
            "COUNT(CASE WHEN a.AssessmentStatus=N'已过期' THEN 1 END) AS overdue "
            "FROM dbo.ElderArchive e JOIN dbo.Community c ON c.CommunityId=e.CommunityId "
            "JOIN dbo.v_CurrentAbilityAssessment a ON a.ArchiveNo=e.ArchiveNo "
            f"WHERE e.IsActive=1 AND {scope}", *params,
        )
        stats = [("在册老人", data["total"]), ("评估有效", data["valid"]), ("评估过期", data["overdue"])]
        recent = query(
            "SELECT TOP (5) e.ArchiveNo,e.FullName,c.Name,a.AssessmentStatus "
            "FROM dbo.ElderArchive e JOIN dbo.Community c ON c.CommunityId=e.CommunityId "
            "JOIN dbo.v_CurrentAbilityAssessment a ON a.ArchiveNo=e.ArchiveNo "
            f"WHERE e.IsActive=1 AND {scope} ORDER BY a.AssessmentDate DESC,e.ArchiveNo", *params,
        )
        if g.user["role"] == "community":
            today = beijing_today()
            reassessments = query(
                "SELECT e.ArchiveNo,e.FullName,a.AbilityLevel,a.ValidThrough "
                "FROM dbo.ElderArchive e JOIN dbo.v_CurrentAbilityAssessment a ON a.ArchiveNo=e.ArchiveNo "
                "WHERE e.IsActive=1 AND e.CommunityId=? AND a.ValidThrough BETWEEN ? AND ? "
                "ORDER BY a.ValidThrough,e.ArchiveNo", g.user["community_id"], today, today + timedelta(days=14),
            )
    elif g.user["role"] == "agency":
        count = one("SELECT COUNT(*) AS n FROM dbo.Worker WHERE AgencyId=?", g.user["agency_id"])
        stats = [("机构护工", count["n"])]
    elif g.user["role"] == "caregiver":
        count = one("SELECT COUNT(*) AS n FROM dbo.WorkerRestriction WHERE WorkerId=? AND ResolvedAt IS NULL",
                    g.user["worker_id"])
        stats = [("待整改事项", count["n"])]
    return render_template("dashboard.html", title="工作台", stats=stats, recent=recent, reassessments=reassessments)
