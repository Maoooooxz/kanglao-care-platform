# 技术验收与恢复

## 独立验证库

在项目目录中准备 Python 虚拟环境和本机 .env 后，使用与应用相同的命令创建一个带后缀的测试库。SQL 文件按规定的库名替换，应用生产演示仍连接 KanglaoCourse。

    $kanglaoPython = Join-Path $env:LOCALAPPDATA 'Kanglao\venv\Scripts\python.exe'
    & $kanglaoPython -m pip install -r requirements-dev.txt
    & $kanglaoPython -m kanglao --database KanglaoCourse_QA install
    & $kanglaoPython -m kanglao --database KanglaoCourse_QA seed-demo
    & $kanglaoPython -m kanglao --database KanglaoCourse_QA verify-sql
    & $kanglaoPython -m pytest -q
    & $kanglaoPython -m tools.course_evidence --database KanglaoCourse_QA

Python 集成验证使用 KANG_LAO_TEST_DATABASE 指定的测试库，默认 KanglaoCourse_QA。浏览器测试使用 Windows 上的 Edge，桌面和移动视口各测试一次。截图保存在 pytest 打印的本地临时目录中。

编号 02、04、06、07、08 的 verify SQL 覆盖原档案和评估、预约与派单、工时、应急、补贴和整改。事务中的样例变更会回滚。新建和重复执行迁移的业务记录应一致，原版升级只补充必要字段和对象。

## 本机验收记录

- SQL Server Express 17.0.1000.7 从空库安装成功，五组 SQL 校验通过。重复应用增量迁移和样例后，档案、评估、订单、账号、体征和申报六类业务记录数一致。
- v0.2 原地升级逐行校验通过。原有 2 个社区、3 份档案和 3 条评估保留，社区账号可访问全部工作台页面。
- pytest 实测 18 项通过。使用 Edge 验证桌面业务导航、390 像素移动视口和一键呼叫。实际 Flask 路由测试覆盖从建档到家庭签字及补贴资格。并发测试使用两个独立 SQL Server 会话。
- 36 张业务表的合成数据均通过每表至少 20 条检查。15 个查询场景的 30 种写法均返回一致的配对结果，实际算子与逻辑读见[关键查询对照](query-plans.md)。
- 独立恢复演练通过。恢复后的档案、评估、可核算已完成订单、应急事件、补贴申请和抽查数与源库一致。

## 备份与恢复演练

本机课程演示建议每周保留一次完整备份，每日一次差异备份，以一天的数据恢复点和半小时的恢复时间为演练目标。用 SQL Server 的实例备份目录存放文件，定期核对备份日期与可读性。部署密钥单独保管，联系信息解密与对应密钥配套验收。

[恢复验证脚本](../sql/09_verify_restore.sql) 可在有备份与建库权限的 SSMS 会话中运行。它读取独立的 KanglaoCourse_QA，从实例备份目录恢复到带随机后缀的数据库，并比较六类业务记录。

1. 在 SSMS 对测试库运行 BACKUP DATABASE，保存一份带校验和的全量备份。常规差异备份使用该全量备份作为基准。
2. 运行 RESTORE VERIFYONLY 和 RESTORE FILELISTONLY，核对备份及逻辑文件名。用 RESTORE DATABASE 加 MOVE 把数据和日志恢复到独立测试库及新文件路径。
3. 记录开始和结束时间，逐一核对老人档案、现有评估、有效签字订单、应急历史和补贴审核状态，以及所需视图和存储过程。校验后，可对独立演练库执行清理。

## 并发与授权

| 场景 | 通过条件 |
|---|---|
| 同一老人重叠生效计划 | 双连接并发只建立一份计划 |
| 同一班次最后一个名额 | 两个独立订单竞争时只接受一单 |
| 同一请求重复呼救 | 只有一条事件及对应通知 |
| 同一老人同月份同项目申报 | 组合唯一，审核及核算可追溯 |
| 档案和订单访问 | 登录会话按社区、机构、辖区、本人派单和关联档案过滤，越权操作被拒绝 |
| 协同业务 | 家属签字前无法正式完成或核算补贴，审核顺序和整改记录均可追溯 |
