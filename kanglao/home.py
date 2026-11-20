from flask import Blueprint, g, url_for

from .archive import READERS
from .db import query
from .web import ROLE_NAMES, roles, workspace

bp = Blueprint("home", __name__)
WORKSPACES = [
    ("档案", "/archives/", READERS),
    ("照护计划", "/services/plans", ()),
    ("订单", "/services/orders", ()),
    ("人员与排班", "/services/workers", ("community", "caregiver", "agency", "street", "civil")),
    ("健康与应急", "/health/", ()),
    ("补贴与抽查", "/subsidy/", ()),
]


@bp.app_context_processor
def navigation():
    if not g.get("user"):
        return {"navigation": ()}
    return {"navigation": [(label, href) for label, href, allowed in WORKSPACES
                           if not allowed or g.user["role"] in allowed]}


@bp.get("/")
@roles()
def index():
    user = g.user
    panels = []
    if user["role"] == "community":
        reassessments = query(
            "SELECT ArchiveNo,FullName,AbilityLevel,ValidThrough,QueueStatus "
            "FROM dbo.v_ReassessmentQueue WHERE CommunityId=? ORDER BY ValidThrough,ArchiveNo",
            user["community_id"],
        )
        pending = query(
            "SELECT TOP (10) OrderId,ArchiveNo,ServiceName,AppointmentStart,Status FROM dbo.v_ServiceOrderOverview "
            "WHERE CommunityId=? AND Status IN ('NEW','POOL') ORDER BY AppointmentStart,OrderId", user["community_id"],
        )
        for status, title in (("OVERDUE", "已过期待复评"), ("DUE_SOON", "14 天内到期待复评")):
            entries = [row for row in reassessments if row["QueueStatus"] == status]
            panels.append(dict(
                title=title, columns=["档案编号", "姓名", "能力等级", "截止日期"],
                rows=[(row["ArchiveNo"], row["FullName"], row["AbilityLevel"], row["ValidThrough"]) for row in entries],
                row_links=[url_for("archive.detail", archive_no=row["ArchiveNo"], _anchor="assessment-form")
                           for row in entries],
            ))
        panels.append(
            dict(title="待派单", columns=["订单", "档案", "服务项目", "预约时间", "状态"],
                 rows=[(row["OrderId"], row["ArchiveNo"], row["ServiceName"], row["AppointmentStart"],
                        "待派单" if row["Status"] == "NEW" else "人工调度") for row in pending],
                 row_links=[url_for("services.order_detail", order_id=row["OrderId"]) for row in pending],
                 links=[("查看待派单", url_for("services.orders", status="NEW")),
                        ("查看人工调度", url_for("services.orders", status="POOL"))]),
        )
    return workspace("工作台", f'{user["display_name"]} · {ROLE_NAMES[user["role"]]}', panels)
