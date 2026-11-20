# 北林之家·社区居家养老服务数据库设计

## 需求与用例

系统覆盖社区老人建档、能力评估和照护计划，服务预约、派单与确认，护工排班和工时，健康监测与应急，以及补贴审核和服务监管。老人和家属按关联档案使用服务。社区、机构和监管账号的数据范围分别来自社区、机构和辖区绑定。

~~~mermaid
flowchart LR
    CommunityUser[社区管理员] --> Archive(建档 评估 照护计划)
    CommunityUser --> Dispatch(代预约 派单 改派 复核)
    CommunityUser --> Health(设备绑定 值班待办 应急处置)
    CommunityUser --> Claim(汇总合格订单 提交补贴)
    Family[家属] --> Booking(预约 查进度 确认签字 提交反馈)
    Resident[老人] --> ReadOwn(本人档案 服务与补贴查询)
    Resident --> ResidentBooking(预约 查进度 提交反馈)
    Family --> SOS(呼救和查看应急通知)
    Resident --> SOS
    Caregiver[护工] --> Visit(接单 签到签退 服务记录)
    Caregiver --> Health
    AgencyUser[机构负责人] --> Staff(护工资料 资质 培训 班次)
    AgencyUser --> Correction(异常工时复核 质量整改)
    Street[街道审核员] --> ReviewStreet(初审或退回)
    Civil[民政监管员] --> ReviewCivil(复审和模拟拨付 配置政策)
    Street --> Inspection(质量抽查 整改复查 服务覆盖)
    Civil --> Inspection
~~~

### 鲁棒性分析

界面接收表单和会话，控制层校验角色、数据范围和防伪令牌，数据库过程落实当前评估、计划和派单的约束。存储实体保留服务过程、签字和申报历史。以下为跨业务闭环，实际入口通过服务模块和补贴模块各自的页面调用。

~~~mermaid
sequenceDiagram
    actor F as 家属
    actor C as 社区管理员
    actor W as 护工
    actor R as 街道及民政
    participant UI as 边界 角色工作台
    participant App as 控制 Flask路由与权限
    participant CP as 控制 SQL业务过程
    participant DB as 实体 评估计划订单派单及工时
    participant Finance as 实体 申报明细和审核日志
    F->>UI: 提交预约
    UI->>App: 表单与会话
    App->>CP: 校验授权并创建订单
    CP->>DB: 校验最新评估、照护计划和服务范围
    DB-->>UI: 返回预约结果
    C->>UI: 派单
    W->>UI: 接单、签到、签退并写服务记录
    UI->>App: 业务状态操作
    App->>CP: 校验账户范围
    CP->>DB: 锁定派单与班次并记录工时
    F->>UI: 确认签字
    UI->>App: 请求完成订单
    App->>CP: 通过业务过程记录确认
    CP->>DB: 保存签字和完成状态
    C->>UI: 归集同一老人项目月份的订单
    UI->>App: 提交订单清单
    App->>CP: 申报与分级审核
    CP->>Finance: 核算有效工时及政策和保留快照
    R->>UI: 初审、复审和模拟拨付
    UI->>App: 授权后推进状态
    App->>CP: 提交审核动作
    CP->>Finance: 更新申报及追加审核日志
~~~

## 局部 E-R 图

### 老人档案与照护

~~~mermaid
erDiagram
    Community ||--o{ ElderArchive : 登记
    ElderArchive ||--o{ AbilityAssessment : 接受评估
    ElderArchive ||--o{ CarePlan : 制定
    ElderArchive ||--o{ ArchiveAudit : 产生
    Worker ||--o{ CarePlan : 负责
    CarePackage ||--o{ CarePlan : 采用
    CarePackage ||--o{ CarePackageService : 包含
    ServiceType ||--o{ CarePackageService : 纳入
    CarePlan ||--o{ CarePlanAudit : 产生
~~~

### 服务预约、派单与确认

~~~mermaid
erDiagram
    ElderArchive ||--o{ ServiceOrder : 预约
    CarePlan ||--o{ ServiceOrder : 支持
    Community ||--o{ ServiceOrder : 归属
    ServiceType ||--o{ ServiceOrder : 分类
    ServiceOrder ||--o{ ServiceDispatch : 派单
    Worker ||--o{ ServiceDispatch : 接受
    WorkerShift ||--o{ ServiceDispatch : 占用
    ServiceDispatch ||--o{ ServiceDispatchAudit : 留痕
    ServiceDispatch ||--o| ServiceVisit : 履约
    ServiceOrder ||--o| ServiceVisit : 确认
~~~

### 护工、排班与工时

~~~mermaid
erDiagram
    Agency ||--o{ Worker : 管理
    Worker ||--o{ WorkerCommunity : 提供覆盖
    Community ||--o{ WorkerCommunity : 接受覆盖
    Worker ||--o{ WorkerService : 获得资质
    ServiceType ||--o{ WorkerService : 要求资质
    Worker ||--o{ WorkerShift : 排班
    Worker ||--o{ ServiceVisit : 记录工时
    Worker ||--o{ WorkerRestriction : 接单限制
    ServiceVisit ||--o{ ServiceVisitAudit : 留痕
~~~

### 健康设备与应急

~~~mermaid
erDiagram
    HealthDevice ||--o{ HealthBinding : 绑定历史
    ElderArchive ||--o{ HealthBinding : 接受绑定
    HealthBinding ||--o{ HealthReading : 归属
    HealthThreshold ||--o{ HealthReading : 指标
    Community ||--o{ HealthResponseRule : 响应规则
    HealthReading ||--o| HealthAlert : 触发待确认
    HealthAlert o|--o| HealthEvent : 产生事件
    ElderArchive ||--o{ HealthEvent : 涉及
    HealthAlert o|--o{ HealthNotice : 通知预审
    HealthEvent o|--o{ HealthNotice : 通知处置
    AppUser ||--o{ HealthNotice : 接收
    HealthEvent ||--o{ HealthEventAudit : 产生
~~~

### 补贴与质量监管

~~~mermaid
erDiagram
    ElderArchive ||--o{ SubsidyClaim : 申报
    Community ||--o{ SubsidyClaim : 管理
    ServiceType ||--o{ SubsidyClaim : 核算项目
    ServiceType ||--o{ SubsidyPolicy : 适用政策
    SubsidyClaim ||--o{ SubsidyClaimOrder : 包含明细
    ServiceOrder ||--o| SubsidyClaimOrder : 纳入
    SubsidyPolicy ||--o{ SubsidyClaimOrder : 核算依据
    SubsidyClaim ||--o{ SubsidyClaimLog : 状态与金额快照
    ServiceOrder o|--o{ ServiceInspection : 可被抽查
    ServiceOrder ||--o{ InspectionBatchOrder : 被抽样
    InspectionBatch ||--|{ InspectionBatchOrder : 固定样本
    InspectionBatch ||--o| InspectionPublication : 公示快照
    Agency ||--o{ AgencyAssessmentSubmission : 提交考核材料
    Worker ||--o{ ServiceInspection : 受检查
    WorkerRestriction o|--o{ ServiceInspection : 对应限制
    ServiceInspection ||--o{ ServiceInspectionLog : 整改留痕
~~~

## 全局 UML 类图

类名对应实际核心关系表。局部 E-R 图给出了审计和通知关系，以下类图展示连接五条业务线的全局对象。详细字段以仓库内迁移脚本和数据字典为准。 [基础表](../sql/01_init.sql) · [评估](../sql/03_add_ability_assessment.sql) · [平台](../sql/05_platform.sql) · [服务与护工](../sql/06_services.sql) · [健康](../sql/07_health.sql) · [补贴](../sql/08_subsidy.sql)

~~~mermaid
classDiagram
    direction LR
    class Community {
      int CommunityId
      string District
    }
    class ElderArchive {
      string IdNumber
      string ArchiveNo
      int CommunityId
      string SubsidyCategory
    }
    class AbilityAssessment {
      int AssessmentId
      string AssessmentNo
      date ValidThrough
    }
    class AppUser {
      int UserId
      string Role
    }
    class CarePlan {
      int PlanId
      date StartsOn
      date EndsOn
      string Status
    }
    class ServiceOrder {
      int OrderId
      int PlanId
      string Status
    }
    class ServiceVisit {
      int OrderId
      int DispatchId
      int EffectiveMinutes
      datetime ConfirmedAt
      string SubsidyCategory
      string SubsidyAbilityLevel
    }
    class HealthBinding {
      int BindingId
      datetime StartsAt
      datetime EndsAt
    }
    class HealthEvent {
      int EventId
      int AlertId
    }
    class SubsidyClaim {
      int ClaimId
      date PeriodMonth
      string Status
    }
    class SubsidyClaimOrder {
      int ClaimId
      int OrderId
      decimal Amount
      string SubsidyCategory
      string SubsidyAbilityLevel
    }
    Community "1" --> "0..*" ElderArchive
    Community "0..1" --> "0..*" AppUser
    ElderArchive "0..1" --> "0..*" AppUser
    ElderArchive "1" --> "0..*" AbilityAssessment
    ElderArchive "1" --> "0..*" CarePlan
    ElderArchive "1" --> "0..*" ServiceOrder
    CarePackage "1" --> "0..*" CarePlan
    CarePackage "1" --> "0..*" CarePackageService
    ServiceType "1" --> "0..*" CarePackageService
    ServiceType "1" --> "0..*" ServiceOrder
    CarePlan "1" --> "0..*" ServiceOrder
    Agency "1" --> "0..*" Worker
    Worker "1" --> "0..*" WorkerShift
    Worker "1" --> "0..*" WorkerCommunity
    Community "1" --> "0..*" WorkerCommunity
    Worker "1" --> "0..*" WorkerService
    ServiceType "1" --> "0..*" WorkerService
    Worker "1" --> "0..*" WorkerRestriction
    Worker "1" --> "0..*" ServiceDispatch
    WorkerShift "1" --> "0..*" ServiceDispatch
    ServiceOrder "1" --> "0..*" ServiceDispatch
    ServiceDispatch "1" --> "0..1" ServiceVisit
    ServiceOrder "1" --> "0..1" ServiceVisit
    HealthDevice "1" --> "0..*" HealthBinding
    ElderArchive "1" --> "0..*" HealthBinding
    HealthBinding "1" --> "0..*" HealthReading
    HealthThreshold "1" --> "0..*" HealthReading
    HealthReading "1" --> "0..1" HealthAlert
    HealthAlert "0..1" --> "0..1" HealthEvent
    HealthEvent "0..1" --> "0..*" HealthNotice
    AppUser "1" --> "0..*" HealthNotice
    ElderArchive "1" --> "0..*" SubsidyClaim
    ServiceType "1" --> "0..*" SubsidyClaim
    ServiceType "1" --> "0..*" SubsidyPolicy
    SubsidyClaim "1" --> "0..*" SubsidyClaimOrder
    ServiceOrder "1" --> "0..1" SubsidyClaimOrder
    SubsidyPolicy "1" --> "0..*" SubsidyClaimOrder
    Worker "1" --> "0..*" ServiceInspection
    ServiceOrder "0..1" --> "0..*" ServiceInspection
    WorkerRestriction "0..1" --> "0..*" ServiceInspection
~~~

## 关系模式与第三范式分析

| 关系 | 候选键与关键函数依赖 |
| --- | --- |
| Community | CommunityId → Name、District（权限辖区）、CityName、AreaName、StreetName、模拟地理范围 |
| ElderArchive | IdNumber、ArchiveNo 均为候选键，各自确定姓名、生日、地址、监护信息和所属社区 |
| AbilityAssessment | AssessmentId 或 AssessmentNo → ArchiveNo、量表、分数、评估日期与截止日 |
| CarePackageService | PackageId、ServiceTypeId 共同确定包内项目，项目名称和价格维护在 ServiceType |
| WorkerCommunity、WorkerService | WorkerId 与 CommunityId 或 ServiceTypeId 组成关联键，项目资质由整组关联键确定 |
| ServiceVisit | OrderId 或 DispatchId → WorkerId、签到签退、工时核算、签字与反馈 |
| HealthBinding、HealthReading | BindingId → DeviceId、ArchiveNo、起止时间，ReadingId → BindingId、指标和采集结果 |
| HealthAlert、HealthEvent | AlertId 和唯一 ReadingId 确定待确认记录，EventId 确定事件生命周期，适用时按 AlertId 唯一 |
| SubsidyPolicy | PolicyId 或 District、ServiceTypeId、BeneficiaryCategory、AbilityLevel、ValidFrom 的组合确定费率和截止日 |
| SubsidyClaim | ClaimId 或 ArchiveNo、ServiceTypeId、PeriodMonth 的组合确定本期申报状态及金额 |
| SubsidyClaimOrder | ClaimId、OrderId 为联合主键，OrderId 还受唯一约束。核算行记录结算时依据和价格快照 |

基础关系依照候选键拆分，社区名称、服务名称和机构名称集中在各自关系表。多对多联系用关联表表示。快照是有意保留的历史事实。订单保存预约发生时的社区、地址和价格，申报明细保存核算时费率、分钟数和金额，审计保存操作发生时的状态。同一个计划的老人编号也在订单中保留，用于范围校验和订单定位，创建过程保证它和计划的档案编号一致。此类快照和冗余字段作为物理设计取舍单独记录。

## 索引设计

| 索引 | 对应查询或约束 |
| --- | --- |
| `IX_ElderArchive_Community` | 按所属社区和启停状态筛选档案，按档案编号分页。 |
| `IX_CarePlan_ArchiveDates` | 按老人查找有效照护计划，并核对计划起止日期是否重叠。 |
| `IX_ServiceDispatch_Quota` | 按班次读取接单和关闭记录，计算剩余名额及派单历史。 |
| `UX_ServiceDispatch_Open` | 为开放派单建立唯一筛选索引，保证一份订单同一时刻只有一个待处理派单。 |
| `IX_HealthAlert_Triage` | 按待确认状态及复核截止时间查找需要转应急的告警。 |
| `UX_HealthEvent_Request` | 为有请求编号的事件约束唯一，支持对同一呼救请求的重复提交。 |
| `IX_SubsidyClaim_Community_Status_Period` | 按社区、审核状态及月份筛选补贴工作队列。 |
| `IX_ServiceInspection_District_Status` | 按辖区和整改状态过滤抽查记录，并按检查时间定位记录。 |

这些索引对应实际页面、任务扫描和并发约束。合成数据规模、参数及统计信息会影响优化器选择。 [实际执行计划对照](query-plans.md)

## 权限、事务与数据保护

| 账户 | 授权范围与职责 |
| --- | --- |
| 社区管理员 | 按 CommunityId 处理本社区档案、照护、服务和申报 |
| 老人、家属 | 按 ArchiveNo 查看关联档案与业务，老人本人或关联家属之一可签字 |
| 护工 | 按 WorkerId 处理本人派单、服务、应急与质量记录 |
| 机构负责人 | 按 AgencyId 管理所属护工、班次、异常工时和整改 |
| 街道审核员、民政监管员 | 按 District 查询辖区，分开推进初审、复审和拨付 |

Flask 路由校验账号和业务范围，DAO 使用参数化 SQL。写入表单有防伪令牌，登录错误计数与临时锁定由数据库保存，会话按配置过期。身份证号的展示取脱敏读视图，监护联系方式由本机密钥加密且按授权读取。演示数据采用合成身份、围栏、阈值和政策。数据库登录和应用密钥在本机配置。

服务过程使用事务和范围锁保护排班、有效照护计划及派单状态。设备绑定保留时间区间，通过绑定标识关联采集的历史归属。应急事件与报警的唯一约束防止同一报警重复创建事件。补贴过程校验同一老人、项目、社区和月份，唯一申报和明细约束保证归集一致性。触发器记录档案、照护、派单、工时、应急、审核和整改的历史。

复核恢复、超时派单归池和应急升级由应用的 SQL 业务过程处理，周期作业与手动运行入口复用同一逻辑。数据库备份与隔离恢复演练见技术验收记录。

新评估由存储过程比较评估日与 80 岁生日（闰日以 SQL Server 年周年日计算），截止日默认评估日加 180 或 90 天，也可指定较早的有效日期。旧评估保留原日期。机构通过存储过程调整本机构护工状态，与接单、签到共用护工锁；请假和离职不覆盖现有派单或已完成记录。

`v_ReassessmentQueue` 读取在册老人的最新评估，提供已过期和 14 天内到期两类待办。工作台按登录账号的社区编号查询。迁移存储过程在同一个事务中更新原档案地址与社区、记录原因和操作人、暂停生效计划并关闭原社区未开始的预约及派单。`v_ElderTransferHistory` 支持迁移历史查询，档案页按当前社区授权读取。订单改派继续通过 `v_ServiceDispatchHistory` 展示每次派单的人员、时间与原因。

暂不做单独的社区主管通知接收配置、数据库账号层权限重构及年龄或工种补贴扩展；若老师要求再按确认后的口径调整。

## 核算与考核口径

- 签退晚于预约结束时间即转入工时复核。签字与工时审核分开：订单可先完成确认，但工时未获通过不能核算补贴。
- 补贴先核对辖区、服务项目和北京时间的服务完成日，再按签到时的对象类别、能力等级匹配，具体对象优先、具体等级其次。金额取有效工时乘费率、订单金额、单笔上限三者中的最小值。候选列表和申报共用 `v_SubsidyApplicableOrder`，已申报的费用和审核快照不随复评更新。
- `v_MonthlyInspectionResults` 按北京时间的抽查月份、辖区和护工归集。机构平均分按实际抽查次数加权；整改结案率以需要整改的抽查为分母，复查通过计入原抽查月。监管侧按辖区过滤后再汇总。
- 确认前，服务对象可按档案查看服务记录；自付只从已核定或已拨付的申报明细计算。每次提交在申报日志保存不可由业务操作覆盖的证明版本，包含记录、有效工时、签字摘要、核算依据等。
- 抽查批次采用已结束的北京时间服务月份和辖区内实际签退的完成订单。事务内按比例向上取整后固化样本；首条同辖区检查计入批次，民政可在完成全部样本后发布不含个人明细的汇总快照。机构考核分别以实际检查、投诉、工时所属自然月为准，监管意见独立留存。
- 设备安装位置属于绑定历史。模拟读数只为启用且绑定合成档案的演示设备生成，读数编号按设备和 UTC 分钟幂等；异常在入库事务内生成三方站内通知。响应和超时升级沿用现有应急规则。
