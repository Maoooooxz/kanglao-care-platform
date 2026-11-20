# 北林之家·社区居家养老服务

北林之家提供社区档案与照护、上门服务与派单、人员排班与工时、健康应急，以及补贴与抽查整改。网页按账号展示辖区、机构、派单或家庭范围内的业务。

## 在本机启动

需要 Windows、Python 3.12、SQL Server Express 和能运行 Windows 身份连接的 sqlcmd。默认实例为 .\SQLEXPRESS，默认数据库为 KanglaoCourse。首次安装或从 v0.2 升级时，在项目目录的 PowerShell 中执行。

    $kanglaoRuntime = Join-Path $env:LOCALAPPDATA 'Kanglao\venv'
    python -m venv $kanglaoRuntime
    $kanglaoPython = Join-Path $kanglaoRuntime 'Scripts\python.exe'
    & $kanglaoPython -m pip install -r requirements.txt
    & $kanglaoPython -m kanglao configure
    & $kanglaoPython -m kanglao install
    & $kanglaoPython -m kanglao seed-demo
    & $kanglaoPython -m kanglao serve

浏览器打开 [本机工作台](http://127.0.0.1:8080)。已有数据库先备份，再重新运行 `install`，无需重新建库。演示数据由独立的种子命令加入。备用端口可用 serve --port 8081。

Windows 上的 SQL Server 驱动依赖原生库。使用上面的英文虚拟环境目录，可避免项目路径包含中文时驱动无法加载。若用户配置目录也包含中文，可将 $kanglaoRuntime 改为有写入权限的英文路径。

本机课设演示账号 `community` 的密码为 `123456`，运行 `seed-demo` 后生效，仅适用于本机演示。其他账号（family、resident、caregiver、agency、street、civil 和分社区账号）继续使用本机 .env 中的 KANG_LAO_DEMO_PASSWORD。已有演示库按 `install`、`seed-demo`、`serve` 的顺序升级和启动。

    Get-Content .env | Select-String '^KANG_LAO_DEMO_PASSWORD='

在另一个 PowerShell 窗口运行下列命令，每分钟检查评估过期、派单时限和应急响应。演示需要即时推进时，省略 --watch 运行一次。

    $kanglaoPython = Join-Path $env:LOCALAPPDATA 'Kanglao\venv\Scripts\python.exe'
    & $kanglaoPython -m kanglao jobs --watch

演示设备定时上报时，改用 `jobs --watch --simulate-devices`。模拟器只读取合成样例设备并每分钟写入一次，不接收外部设备数据；去掉 `--watch` 可单次演示。绑定或解绑的记录位置保留在设备历史中。

## 演示路径

| 账号 | 可操作的主要入口 |
|---|---|
| community | 建档及跨社区迁移、登记复评、建照护计划、派单及改派、复核与申报补贴、处理异常与投诉 |
| family / resident | 浏览本人或关联老人档案、预约、查看历史、呼救。签退并有服务记录后，由老人本人或关联家属之一签字 |
| caregiver | 查看派单及班次、接单、模拟签到签退和填写服务记录、报告异常、处理整改 |
| agency | 管理护工资质、培训、排班和在岗／请假／离职状态，复核异常工时、提交整改 |
| street / civil | 查看辖区覆盖、抽查整改和月度考核，按街道和民政的权限依次审批，民政维护补贴政策和执行模拟拨付 |

1. **搬迁**。用 `community` 打开「档案 → 周秀兰（E0001） → 跨社区迁移」，选择六道口社区，填写新演示住址和原因。系统以迁入社区中心点作为模拟位置。提交后用 `community02` 查看原档案和迁移记录。原住址尚未开始的预约会取消，已开始或已完成的订单可沿原流程查阅和处理。新社区复核并恢复照护计划后，可按新住址预约。原责任护工未覆盖新社区时，需结束旧计划并用当地护工建立新计划。
2. **到期复评**。用 `community` 从工作台「已过期待复评」点击刘建民（E0002），登记一条新评估。历史可查，工作台按新有效期刷新。未满 80 岁最长 180 天，满 80 岁最长 90 天（课设演示口径），截止日留空采用上限。若需现场展示到期计划转为暂停，登记复评前执行一次 `jobs`。同等级且责任护工仍符合条件时，可在「照护计划」复核恢复。
3. **护工改派**。用 `community02` 打开「订单」，筛选「已接单」后找到沈桂芳（E0003）的最新陪诊订单。预约开始前可以改派给陈立新并填写原因，例如「林瑞霞家中临时有事」。随后用 `caregiver002` 接单。在同一订单查看两次派单。改派样例首次初始化按当天生成。

另外，`seed-demo` 会补充 E0021 至 E0060 的北京社区案例，涵盖未评估、已过期、即将到期和仍有效的老人档案，并为部分老人关联照护计划与预约。用 `community` 登录可查看本社区档案分页。

订单页可按状态筛选，每页 30 条。「新建预约」一并展示服务项目、指导价和补贴资格；派单、接单、签到、签退、签字和复核从订单详情办理。新建演示数据时，多数档案有约四小时后的预约；错过预约可在订单详情重新预约，机构可补班。护工请假或离职不接新单，原派单由社区手动改派，已经开始的服务仍可签退。

超过预约结束时间签退的服务转人工复核，签字不会自动使该工时有效。新上门记录在签到时保存补贴对象与评估等级；无历史快照的旧订单只匹配通用政策，已申报记录不重算。

- **查阅服务与证明**：老人或家属点击订单编号，查看记录和实际签到签退时间后签字。补贴核定后显示自付金额。社区从申报详情查看每次提交留下的证明材料。
- **演示按比例抽查**：用 `street` 或 `civil` 从「补贴与抽查 → 质量抽查和服务覆盖 → 按比例抽查」生成上一个已结束月份的批次。完成样本检查后，`civil` 发布汇总；登录用户从「补贴与抽查」内的「抽查结果公示」查看。已有检查单会直接计入，无需重复录入。
- **查看历史抽查样例**：`civil-course-demo`、`agency-course-demo` 使用相同演示密码，分别查看独立演示辖区的历史公示和机构材料。普通 `agency` 可提交本机构月度考核，也可给本机构的超时派单留下跟进说明。

社区名称取自[海淀区学院路街道名录](https://zyk.bjhd.gov.cn/jbdt/auto4542_51838/auto4542_56412/auto4542/auto4542_56425/202011/t20201103_4431943.shtml)和[花园路街道的公开名单](https://zyk.bjhd.gov.cn/jbdt/auto4549_51845/auto4549_57032/auto4549/auto4549/202206/t20220620_4531897.shtml?type=computer)。人物、证件号、住址、围栏、告警阈值和补贴标准均为演示数据。体征先进入值班待确认队列，主动呼救直接建立事件。业务日期按北京时间显示，事件时间在数据库中以 UTC 保存。

## 验收材料

- [数据库设计、ER 与 UML](docs/database-design.md)
- [数据库字段和约束](docs/data-dictionary.md)
- [15 个查询场景的实际执行计划对照](docs/query-plans.md)
- [测试、升级与备份恢复](docs/verification.md)

SQL 迁移和合成数据在 sql 目录。对照 v0.1 和 v0.2 的 README 与提交历史，可复习建档、社区迁移和评估 SQL 的逐步实现。
