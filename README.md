# 康老社区居家养老平台 v1.0

康老提供社区档案与照护、上门服务与派单、人员排班与工时、健康应急，以及补贴与抽查整改。网页按账号展示辖区、机构、派单或家庭范围内的业务。

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

演示账号使用本机 .env 的 KANG_LAO_DEMO_PASSWORD。用户名分别为 community、family、resident、caregiver、agency、street 和 civil。较细的社区、家庭及机构演示账号也由种子命令生成。

    Get-Content .env | Select-String '^KANG_LAO_DEMO_PASSWORD='

在另一个 PowerShell 窗口运行下列命令，每分钟检查评估过期、派单时限和应急响应。演示需要即时推进时，省略 --watch 运行一次。

    $kanglaoPython = Join-Path $env:LOCALAPPDATA 'Kanglao\venv\Scripts\python.exe'
    & $kanglaoPython -m kanglao jobs --watch

演示设备定时上报时，改用 `jobs --watch --simulate-devices`。模拟器只读取合成样例设备并每分钟写入一次，不接收外部设备数据；去掉 `--watch` 可单次演示。绑定或解绑的记录位置保留在设备历史中。

## 演示路径

| 账号 | 可操作的主要入口 |
|---|---|
| community | 建档、查看 14 天内待复评名单、建照护计划、派单及改派、复核与申报补贴、处理异常与投诉 |
| family / resident | 浏览本人或关联老人档案、预约、查看历史、呼救。签退并有服务记录后，由老人本人或关联家属之一签字 |
| caregiver | 查看派单及班次、接单、模拟签到签退和填写服务记录、报告异常、处理整改 |
| agency | 管理护工资质、培训和排班，复核异常工时、提交整改 |
| street / civil | 查看辖区覆盖、抽查整改和月度考核，按街道和民政的权限依次审批，民政维护补贴政策和执行模拟拨付 |

可以用 E0001 录入评估并查看历史，打开照护计划与当前订单。新建演示数据时，每份档案会有一个待派单订单，预约约在初始化后的四小时。社区派给对应护工后，使用护工账号接单并完成签到签退。演示预约时间错过后，请用订单页重新预约，机构账号可补排班。已归档的样例可直接浏览补贴审核、模拟拨付和抽查留痕。

订单页可按状态筛选，每页 30 条。超过预约结束时间签退的服务转人工复核，签字不会自动使该工时有效。新上门记录在签到时保存补贴对象与评估等级；无历史快照的旧订单只匹配通用政策，已申报记录不重算。

- **查阅服务与证明**：老人或家属点击订单编号，查看记录和实际签到签退时间后签字。补贴核定后显示自付金额。社区从申报详情查看每次提交留下的证明材料。
- **演示按比例抽查**：用 `street` 或 `civil` 从「补贴与抽查 → 质量抽查和服务覆盖 → 按比例抽查」生成上一个已结束月份的批次。完成样本检查后，`civil` 发布汇总；登录用户从「抽查公示」查看。已有检查单会直接计入，无需重复录入。
- **查看历史抽查样例**：`civil-course-demo`、`agency-course-demo` 使用相同演示密码，分别查看独立演示辖区的历史公示和机构材料。普通 `agency` 可提交本机构月度考核，也可给本机构的超时派单留下跟进说明。

示例证件号码、地点、告警阈值和补贴标准仅用于课程演示。体征先进入值班待确认队列，主动呼救直接建立事件。业务日期按北京时间显示，事件时间在数据库中以 UTC 保存。

## 验收材料

- [数据库设计、ER 与 UML](docs/database-design.md)
- [数据库字段和约束](docs/data-dictionary.md)
- [15 个查询场景的实际执行计划对照](docs/query-plans.md)
- [测试、升级与备份恢复](docs/verification.md)

SQL 迁移和合成数据在 sql 目录。对照 v0.1 和 v0.2 的 README 与提交历史，可复习建档、社区迁移和评估 SQL 的逐步实现。
