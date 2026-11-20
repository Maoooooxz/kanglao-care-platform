# SQL Server 数据字典

字段、键与约束来自已应用迁移的 SQL Server 元数据。

## AbilityAssessment

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| AssessmentId | int | 否 | 自增  |
| AssessmentNo | varchar(24) | 否 |   |
| ArchiveNo | varchar(20) | 否 |   |
| ScaleCode | varchar(8) | 否 |   |
| Score | decimal(6,2) | 否 |   |
| AbilityLevel | nvarchar(20) | 否 |   |
| EvaluatorName | nvarchar(100) | 否 |   |
| AssessmentDate | date | 否 |   |
| ValidThrough | date | 否 |   |

- FK `FK_AbilityAssessment_ElderArchive` · `ArchiveNo -> ElderArchive(ArchiveNo)`
- PK `PK_AbilityAssessment` · `AssessmentId`
- UNIQUE `UQ_AbilityAssessment_AssessmentNo` · `AssessmentNo`
- CHECK `CK_AbilityAssessment_RequiredText` · `(len([AssessmentNo])>(0) AND len([AbilityLevel])>(0) AND len([EvaluatorName])>(0))`
- CHECK `CK_AbilityAssessment_Scale` · `([ScaleCode]='MMSE' OR [ScaleCode]='ADL')`
- CHECK `CK_AbilityAssessment_Score` · `([Score]>=(0))`
- CHECK `CK_AbilityAssessment_Validity` · `([ValidThrough]>=[AssessmentDate])`

## Agency

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| AgencyId | int | 否 | 自增  |
| AgencyNo | varchar(30) | 否 |   |
| Name | nvarchar(100) | 否 |   |
| District | nvarchar(40) | 否 |   |

- PK `PK__Agency__95C546DB078D7193` · `AgencyId`
- UNIQUE `UQ__Agency__95C0E84A43E429DC` · `AgencyNo`

## AgencyAssessmentSubmission

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| SubmissionId | int | 否 | 自增主键 |
| AgencyId | int | 否 | 外键：Agency |
| District | nvarchar(80) | 否 | 接收监管辖区快照 |
| PeriodMonth | date | 否 | 月份首日；与机构组成唯一键 |
| InspectionCount | bigint | 否 | 实际检查次数 |
| ScoreTotal | bigint | 否 | 检查得分之和 |
| RequiredCount | bigint | 否 | 要求整改的次数 |
| ClosedCount | bigint | 否 | 整改结案次数 |
| ComplaintCount | bigint | 否 | 本月投诉数 |
| EffectiveMinutes | bigint | 否 | 本月有效工时分钟 |
| SubmittedBy | int | 否 | 外键：AppUser |
| SubmittedAt | datetime2(0) | 否 | UTC，默认当前时间 |
| ReviewedBy | int | 是 | 外键：AppUser |
| ReviewedAt | datetime2(0) | 是 | UTC |
| ReviewNote | nvarchar(250) | 是 | 与审阅人和审阅时间同时为空或有值 |

统计数量非负，结案数不超过整改数，整改数不超过检查数，得分不超过检查次数乘以 100。

## AppUser

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| UserId | int | 否 | 自增  |
| Username | varchar(48) | 否 |   |
| DisplayName | nvarchar(80) | 否 |   |
| PasswordHash | varchar(255) | 否 |   |
| Role | varchar(16) | 否 |   |
| CommunityId | int | 是 |   |
| ArchiveNo | varchar(20) | 是 |   |
| WorkerId | int | 是 |   |
| AgencyId | int | 是 |   |
| District | nvarchar(80) | 是 |   |
| Active | bit | 否 |  `((1))` |
| FailedAttempts | int | 否 |  `((0))` |
| LockedUntil | datetime2(0) | 是 |   |

- FK `FK__AppUser__Archive__66603565` · `ArchiveNo -> ElderArchive(ArchiveNo)`
- FK `FK__AppUser__Communi__656C112C` · `CommunityId -> Community(CommunityId)`
- PK `PK__AppUser__1788CC4C88E784EA` · `UserId`
- UNIQUE `UQ__AppUser__536C85E4D75F0203` · `Username`
- CHECK `CK__AppUser__693CA210` · `([Role]='community' AND [CommunityId] IS NOT NULL OR ([Role]='resident' OR [Role]='family') AND [ArchiveNo] IS NOT NULL OR [Role]='caregiver' AND [WorkerId] IS NOT NULL OR [Role]='agency' AND [AgencyId] IS NOT NULL OR ([Role]='civil' OR [Role]='street') AND [District] IS NOT NULL)`
- CHECK `CK__AppUser__Role__6477ECF3` · `([Role]='civil' OR [Role]='street' OR [Role]='agency' OR [Role]='caregiver' OR [Role]='resident' OR [Role]='family' OR [Role]='community')`

## ArchiveAudit

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| AuditId | bigint | 否 | 自增  |
| ArchiveNo | varchar(20) | 否 |   |
| EventType | varchar(20) | 否 |   |
| BeforeCommunityId | int | 是 |   |
| AfterCommunityId | int | 否 |   |
| ActorUserId | int | 是 |   |
| OccurredAt | datetime2(0) | 否 |  `(sysutcdatetime())` |
| TransferReason | nvarchar(250) | 是 | 跨社区迁移原因 |

- FK `FK__ArchiveAu__Actor__6D0D32F4` · `ActorUserId -> AppUser(UserId)`
- FK `FK__ArchiveAu__Archi__6C190EBB` · `ArchiveNo -> ElderArchive(ArchiveNo)`
- PK `PK__ArchiveA__A17F239840A06D23` · `AuditId`

## CarePackage

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| PackageId | int | 否 | 自增  |
| Name | nvarchar(100) | 否 |   |
| AbilityLevel | nvarchar(20) | 否 |   |

- PK `PK__CarePack__322035CC71592714` · `PackageId`
- UNIQUE `UQ__CarePack__737584F67B5AA699` · `Name`

## CarePackageService

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| PackageId | int | 否 |   |
| ServiceTypeId | int | 否 |   |
| VisitsPerWeek | tinyint | 否 |   |

- FK `FK__CarePacka__Packa__2B0A656D` · `PackageId -> CarePackage(PackageId)`
- FK `FK__CarePacka__Servi__2BFE89A6` · `ServiceTypeId -> ServiceType(ServiceTypeId)`
- PK `PK__CarePack__EA8DCF6AD484882B` · `PackageId, ServiceTypeId`
- CHECK `CK__CarePacka__Visit__2CF2ADDF` · `([VisitsPerWeek]>(0))`

## CarePlan

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| PlanId | int | 否 | 自增  |
| PlanNo | varchar(30) | 是 |   |
| ArchiveNo | varchar(20) | 否 |   |
| PackageId | int | 否 |   |
| ResponsibleWorkerId | int | 否 |   |
| StartsOn | date | 否 |   |
| EndsOn | date | 否 |   |
| Status | varchar(12) | 否 |   |
| ChangedReason | nvarchar(250) | 否 |  `(N'新建')` |
| CreatedAt | datetime2(0) | 否 |  `(sysutcdatetime())` |

- FK `FK__CarePlan__Archiv__30C33EC3` · `ArchiveNo -> ElderArchive(ArchiveNo)`
- FK `FK__CarePlan__Packag__31B762FC` · `PackageId -> CarePackage(PackageId)`
- FK `FK__CarePlan__Respon__32AB8735` · `ResponsibleWorkerId -> Worker(WorkerId)`
- PK `PK__CarePlan__755C22B74B334E35` · `PlanId`
- UNIQUE `UQ__CarePlan__755F8C0693F0D4BF` · `PlanNo`
- CHECK `CK__CarePlan__367C1819` · `([EndsOn]>=[StartsOn])`
- CHECK `CK__CarePlan__Status__339FAB6E` · `([Status]='ENDED' OR [Status]='PAUSED' OR [Status]='ACTIVE')`

## CarePlanAudit

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| AuditId | int | 否 | 自增  |
| PlanId | int | 否 |   |
| OldStatus | varchar(12) | 是 |   |
| NewStatus | varchar(12) | 否 |   |
| Reason | nvarchar(250) | 否 |   |
| LoggedAt | datetime2(0) | 否 |  `(sysutcdatetime())` |

- FK `FK__CarePlanA__PlanI__395884C4` · `PlanId -> CarePlan(PlanId)`
- PK `PK__CarePlan__A17F239801E18734` · `AuditId`

## Community

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| CommunityId | int | 否 |   |
| Name | nvarchar(100) | 否 |   |
| District | nvarchar(80) | 否 |  `(N'海淀演示区')` |
| Latitude | decimal(9,6) | 否 |  `((40.008000))` |
| Longitude | decimal(9,6) | 否 |  `((116.341000))` |
| RadiusMeters | int | 否 |  `((3000))` |
| CityName | nvarchar(30) | 是 | 所属城市 |
| AreaName | nvarchar(80) | 是 | 行政区名 |
| StreetName | nvarchar(80) | 是 | 所属街道 |

- PK `PK_Community` · `CommunityId`

## ElderArchive

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| IdNumber | char(18) | 否 |   |
| ArchiveNo | varchar(20) | 否 |   |
| FullName | nvarchar(100) | 否 |   |
| BirthDate | date | 否 |   |
| Address | nvarchar(200) | 否 |   |
| CommunityId | int | 否 |   |
| GuardianName | nvarchar(100) | 是 |   |
| GuardianContactEncrypted | varbinary(1024) | 是 |   |
| IsActive | bit | 否 |  `((1))` |
| Latitude | decimal(9,6) | 否 |  `((40.008000))` |
| Longitude | decimal(9,6) | 否 |  `((116.341000))` |
| Tags | nvarchar(200) | 是 |   |
| SubsidyCategory | varchar(12) | 否 | `GENERAL`（普通，默认）或 `LOW_INCOME`（低保） |

- FK `FK_ElderArchive_Community` · `CommunityId -> Community(CommunityId)`
- PK `PK_ElderArchive` · `IdNumber`
- UNIQUE `UQ_ElderArchive_ArchiveNo` · `ArchiveNo`

## HealthAlert

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| AlertId | int | 否 | 自增  |
| ReadingId | int | 否 |   |
| Severity | tinyint | 否 |   |
| State | varchar(12) | 否 |  `('PENDING')` |
| OpenedAt | datetime2(0) | 否 |   |
| TriageDeadline | datetime2(0) | 否 |   |
| ReviewedAt | datetime2(0) | 是 |   |
| ReviewedBy | int | 是 |   |

- FK `FK__HealthAle__Readi__24285DB4` · `ReadingId -> HealthReading(ReadingId)`
- FK `FK__HealthAle__Revie__27F8EE98` · `ReviewedBy -> AppUser(UserId)`
- PK `PK__HealthAl__EBB16A8DE34ECB8D` · `AlertId`
- UNIQUE `UQ__HealthAl__C80F9C4F34F4DF6D` · `ReadingId`
- CHECK `CK__HealthAle__Sever__251C81ED` · `([Severity]>=(1) AND [Severity]<=(3))`
- CHECK `CK__HealthAle__State__2704CA5F` · `([State]='TIMEOUT' OR [State]='CONFIRMED' OR [State]='FALSE_ALARM' OR [State]='PENDING')`
- CHECK `CK__HealthAlert__28ED12D1` · `([TriageDeadline]>[OpenedAt])`
- CHECK `CK__HealthAlert__29E1370A` · `([State]='PENDING' AND [ReviewedAt] IS NULL AND [ReviewedBy] IS NULL OR ([State]='CONFIRMED' OR [State]='FALSE_ALARM') AND [ReviewedAt] IS NOT NULL AND [ReviewedBy] IS NOT NULL OR [State]='TIMEOUT' AND [ReviewedAt] IS NOT NULL AND [ReviewedBy] IS NULL)`

## HealthBinding

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| BindingId | int | 否 | 自增  |
| DeviceId | int | 否 |   |
| ArchiveNo | varchar(20) | 否 |   |
| StartsAt | datetime2(0) | 否 |   |
| EndsAt | datetime2(0) | 是 |   |
| InstallationLocation | nvarchar(120) | 是 | 该次绑定的安装位置，旧绑定可能未记录 |

- FK `FK__HealthBin__Archi__0F2D40CE` · `ArchiveNo -> ElderArchive(ArchiveNo)`
- FK `FK__HealthBin__Devic__0E391C95` · `DeviceId -> HealthDevice(DeviceId)`
- PK `PK__HealthBi__C9F44A026A4F4633` · `BindingId`
- UNIQUE `UQ_HealthBinding_Start` · `DeviceId, StartsAt`
- UNIQUE `UX_HealthBinding_Open` · `DeviceId`
- CHECK `CK_HealthBinding_Period` · `([EndsAt]>[StartsAt])`

## HealthDevice

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| DeviceId | int | 否 | 自增  |
| DeviceCode | varchar(24) | 否 |   |
| DeviceType | varchar(12) | 否 |   |
| IsEnabled | bit | 否 |  `((1))` |
| IsDemo | bit | 否 | 默认 0；只有演示设备可由本地模拟器上报 |

- PK `PK__HealthDe__49E12311D63A984B` · `DeviceId`
- UNIQUE `UQ__HealthDe__AFFB3E95D2A0E075` · `DeviceCode`
- CHECK `CK_HealthDevice_Type` · `SOS`、`BP_MONITOR`、`ECG_PATCH`、`FALL_RADAR`、兼容旧值 `VITALS`。

## HealthEvent

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| EventId | int | 否 | 自增  |
| ArchiveNo | varchar(20) | 否 |   |
| AlertId | int | 是 |   |
| RequestKey | varchar(64) | 是 |   |
| SourceType | varchar(12) | 否 |   |
| Origin | varchar(24) | 否 |  `('SYSTEM')` |
| Severity | tinyint | 否 |   |
| OpenedAt | datetime2(0) | 否 |   |
| ResponseDeadline | datetime2(0) | 否 |   |
| RespondedAt | datetime2(0) | 是 |   |
| RespondedBy | int | 是 |   |
| ArrivedAt | datetime2(0) | 是 |   |
| ClosedAt | datetime2(0) | 是 |   |
| Resolution | nvarchar(400) | 是 |   |
| EscalatedAt | datetime2(0) | 是 |   |
| LastActorId | int | 是 |   |
| ReportKind | varchar(12) | 是 | 人工上报：`HEALTH` 或 `HOME_RISK` |
| ReportText | nvarchar(400) | 是 | 人工上报分类与说明同时留空或有效 |

- FK `FK__HealthEve__Alert__2DB1C7EE` · `AlertId -> HealthAlert(AlertId)`
- FK `FK__HealthEve__Archi__2CBDA3B5` · `ArchiveNo -> ElderArchive(ArchiveNo)`
- FK `FK__HealthEve__LastA__32767D0B` · `LastActorId -> AppUser(UserId)`
- FK `FK__HealthEve__Respo__318258D2` · `RespondedBy -> AppUser(UserId)`
- PK `PK__HealthEv__7944C810471AFA4E` · `EventId`
- UNIQUE `UX_HealthEvent_Alert` · `AlertId`
- UNIQUE `UX_HealthEvent_Request` · `RequestKey`
- CHECK `CK__HealthEve__Sever__308E3499` · `([Severity]>=(1) AND [Severity]<=(3))`
- CHECK `CK__HealthEve__Sourc__2EA5EC27` · `([SourceType]='MANUAL' OR [SourceType]='SOS' OR [SourceType]='THRESHOLD')`
- CHECK `CK__HealthEvent__336AA144` · `([SourceType]='THRESHOLD' AND [AlertId] IS NOT NULL AND [RequestKey] IS NULL OR ([SourceType]='MANUAL' OR [SourceType]='SOS') AND [AlertId] IS NULL AND [RequestKey] IS NOT NULL)`
- CHECK `CK__HealthEvent__345EC57D` · `([ResponseDeadline]>[OpenedAt])`
- CHECK `CK__HealthEvent__3552E9B6` · `([RespondedAt] IS NULL AND [RespondedBy] IS NULL OR [RespondedAt] IS NOT NULL AND [RespondedAt]>=[OpenedAt] AND [RespondedBy] IS NOT NULL)`
- CHECK `CK__HealthEvent__36470DEF` · `([ArrivedAt] IS NULL OR [RespondedAt] IS NOT NULL AND [ArrivedAt]>=[RespondedAt])`
- CHECK `CK__HealthEvent__373B3228` · `([ClosedAt] IS NULL AND [Resolution] IS NULL OR [ClosedAt] IS NOT NULL AND [RespondedAt] IS NOT NULL AND [ClosedAt]>=coalesce([ArrivedAt],[RespondedAt]) AND [Resolution] IS NOT NULL AND len([Resolution])>(0))`
- CHECK `CK__HealthEvent__382F5661` · `([EscalatedAt] IS NULL OR [EscalatedAt]>=[ResponseDeadline])`

## HealthEventAudit

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| AuditId | int | 否 | 自增  |
| EventId | int | 否 |   |
| ActorUserId | int | 是 |   |
| ActionCode | varchar(12) | 否 |   |
| OccurredAt | datetime2(0) | 否 |   |
| Details | nvarchar(400) | 是 |   |

- FK `FK__HealthEve__Actor__42ACE4D4` · `ActorUserId -> AppUser(UserId)`
- FK `FK__HealthEve__Event__41B8C09B` · `EventId -> HealthEvent(EventId)`
- PK `PK__HealthEv__A17F23986115EFB1` · `AuditId`
- CHECK `CK__HealthEve__Actio__43A1090D` · `([ActionCode]='ESCALATED' OR [ActionCode]='CLOSED' OR [ActionCode]='ARRIVED' OR [ActionCode]='RESPONDED' OR [ActionCode]='OPENED')`

## HealthNotice

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| NoticeId | int | 否 | 自增  |
| RecipientUserId | int | 否 |   |
| AlertId | int | 是 |   |
| EventId | int | 是 |   |
| Kind | varchar(12) | 否 |   |
| CreatedAt | datetime2(0) | 否 |   |
| ReadAt | datetime2(0) | 是 |   |

- FK `FK__HealthNot__Alert__3BFFE745` · `AlertId -> HealthAlert(AlertId)`
- FK `FK__HealthNot__Event__3CF40B7E` · `EventId -> HealthEvent(EventId)`
- FK `FK__HealthNot__Recip__3B0BC30C` · `RecipientUserId -> AppUser(UserId)`
- PK `PK__HealthNo__CE83CBE5A73AADF5` · `NoticeId`
- UNIQUE `UX_HealthNotice_Alert` · `RecipientUserId, AlertId`
- UNIQUE `UX_HealthNotice_Event` · `RecipientUserId, EventId, Kind`
- CHECK `CK__HealthNoti__Kind__3DE82FB7` · `([Kind]='ESCALATED' OR [Kind]='EVENT' OR [Kind]='TRIAGE')`
- CHECK `CK__HealthNotice__3EDC53F0` · `([Kind]='TRIAGE' AND [AlertId] IS NOT NULL AND [EventId] IS NULL OR ([Kind]='ESCALATED' OR [Kind]='EVENT') AND [AlertId] IS NULL AND [EventId] IS NOT NULL)`

## HealthReading

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| ReadingId | int | 否 | 自增  |
| BindingId | int | 否 |   |
| PacketKey | varchar(64) | 否 |   |
| MetricCode | varchar(24) | 否 |   |
| MeasuredValue | decimal(10,2) | 否 |   |
| CapturedAt | datetime2(0) | 否 |   |
| ReceivedAt | datetime2(0) | 否 |   |
| SourceType | varchar(12) | 否 |   |
| IsAbnormal | bit | 否 |   |

- FK `FK__HealthRea__Bindi__1D7B6025` · `BindingId -> HealthBinding(BindingId)`
- FK `FK__HealthRea__Metri__1E6F845E` · `MetricCode -> HealthThreshold(MetricCode)`
- PK `PK__HealthRe__C80F9C4E9DCDD794` · `ReadingId`
- UNIQUE `UQ__HealthRe__91D47772404CB8CD` · `PacketKey`
- CHECK `CK__HealthRea__Sourc__1F63A897` · `([SourceType]='MANUAL' OR [SourceType]='DEVICE')`
- CHECK `CK__HealthReading__2057CCD0` · `([CapturedAt]<=[ReceivedAt])`

## HealthResponseRule

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| CommunityId | int | 否 |   |
| Severity | tinyint | 否 |   |
| ResponseMinutes | smallint | 否 |   |

- FK `FK__HealthRes__Commu__17C286CF` · `CommunityId -> Community(CommunityId)`
- PK `PK__HealthRe__85C507B822642BCD` · `CommunityId, Severity`
- CHECK `CK__HealthRes__Respo__19AACF41` · `([ResponseMinutes]>(0))`
- CHECK `CK__HealthRes__Sever__18B6AB08` · `([Severity]>=(1) AND [Severity]<=(3))`

## HealthThreshold

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| MetricCode | varchar(24) | 否 |   |
| MetricName | nvarchar(60) | 否 |   |
| UnitLabel | nvarchar(16) | 否 |   |
| MinimumValue | decimal(10,2) | 否 |   |
| MaximumValue | decimal(10,2) | 否 |   |
| TriageMinutes | smallint | 否 |   |
| Severity | tinyint | 否 |   |

- PK `PK__HealthTh__8F1381DDC9FA5484` · `MetricCode`
- CHECK `CK__HealthThr__Sever__13F1F5EB` · `([Severity]>=(1) AND [Severity]<=(3))`
- CHECK `CK__HealthThr__Triag__12FDD1B2` · `([TriageMinutes]>(0))`
- CHECK `CK__HealthThreshold__14E61A24` · `([MaximumValue]>=[MinimumValue])`

## InspectionBatch

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| BatchId | int | 否 | 自增主键 |
| ReviewDistrict | nvarchar(80) | 否 | 抽查辖区 |
| PeriodMonth | date | 否 | 服务月份首日，与辖区组成唯一键 |
| SampleRate | tinyint | 否 | 百分比 1–100 |
| PopulationCount | int | 否 | 生成时辖区完成订单总体 |
| TargetCount | int | 否 | 对总体按比例向上取整；不能超过总体 |
| CreatedBy | int | 否 | 外键：AppUser |
| CreatedAt | datetime2(0) | 否 | UTC，默认当前时间 |

## InspectionBatchOrder

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| BatchId | int | 否 | 外键：InspectionBatch |
| OrderId | int | 否 | 外键：ServiceOrder |

联合主键为 `BatchId, OrderId`，重复生成时不替换既有样本。

## InspectionPublication

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| BatchId | int | 否 | 主键兼外键：InspectionBatch |
| InspectionCount | bigint | 否 | 公示时已检查的样本数，至少 1 |
| ScoreTotal | bigint | 否 | 样本分数加总 |
| RequiredCount | bigint | 否 | 需整改数 |
| ClosedCount | bigint | 否 | 公示时已结案的整改数 |
| PublishedBy | int | 否 | 外键：AppUser；仅本辖区民政可发布 |
| PublishedAt | datetime2(0) | 否 | UTC，默认当前时间 |

公示快照不含个人和订单明细。一批至多发布一次。

## ServiceDispatch

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| DispatchId | int | 否 | 自增  |
| OrderId | int | 否 |   |
| WorkerId | int | 否 |   |
| ShiftId | int | 否 |   |
| OfferedAt | datetime2(0) | 否 |   |
| OfferExpiresAt | datetime2(0) | 否 |   |
| AcceptedAt | datetime2(0) | 是 |   |
| ClosedAt | datetime2(0) | 是 |   |
| CloseReason | nvarchar(250) | 是 |   |
| TimeoutFollowedUpAt | datetime2(0) | 是 | 机构处理超时记录的时间 |
| TimeoutFollowedUpBy | int | 是 | 外键：AppUser |
| TimeoutFollowupNote | nvarchar(250) | 是 | 机构说明；不改变状态或重派权限 |

- FK `FK__ServiceDi__Order__4A8310C6` · `OrderId -> ServiceOrder(OrderId)`
- FK `FK__ServiceDi__Shift__4C6B5938` · `ShiftId -> WorkerShift(ShiftId)`
- FK `FK__ServiceDi__Worke__4B7734FF` · `WorkerId -> Worker(WorkerId)`
- PK `PK__ServiceD__434DBD55935678DD` · `DispatchId`
- UNIQUE `UX_ServiceDispatch_Open` · `OrderId`
- CHECK `CK__ServiceDispatch__4D5F7D71` · `([OfferExpiresAt]>[OfferedAt])`
- CHECK `CK__ServiceDispatch__4E53A1AA` · `([AcceptedAt]>=[OfferedAt])`
- CHECK `CK__ServiceDispatch__4F47C5E3` · `([ClosedAt]>=[OfferedAt])`
- CHECK `CK_ServiceDispatch_Close` · `([ClosedAt] IS NULL AND [CloseReason] IS NULL OR [ClosedAt] IS NOT NULL AND [CloseReason] IS NOT NULL)`

## ServiceDispatchAudit

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| AuditId | int | 否 | 自增  |
| DispatchId | int | 否 |   |
| Action | varchar(12) | 否 |   |
| Reason | nvarchar(250) | 是 |   |
| LoggedAt | datetime2(0) | 否 |  `(sysutcdatetime())` |

- FK `FK__ServiceDi__Dispa__531856C7` · `DispatchId -> ServiceDispatch(DispatchId)`
- PK `PK__ServiceD__A17F23988B8DBE83` · `AuditId`

## ServiceInspection

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| InspectionId | int | 否 | 自增  |
| OrderId | int | 是 |   |
| WorkerId | int | 否 |   |
| ReviewDistrict | nvarchar(80) | 否 |   |
| InspectorId | int | 是 |   |
| Score | tinyint | 否 |   |
| Finding | nvarchar(250) | 否 |   |
| RestrictionId | int | 是 |   |
| Status | varchar(12) | 否 |   |
| InspectedAt | datetime2(0) | 否 |   |
| Correction | nvarchar(250) | 是 |   |
| CorrectedAt | datetime2(0) | 是 |   |
| ClosedAt | datetime2(0) | 是 |   |
| ChangedBy | int | 是 |   |
| InspectionMethod | varchar(10) | 是 | `PHONE`（电话回访）或 `VISIT`（上门核查）；旧记录可为空 |
| IssueTag | nvarchar(60) | 是 | 可选问题标签 |
| CorrectionRequirement | nvarchar(250) | 是 | 新增低于 60 分的抽查必须填写，历史可为空 |

- FK `FK__ServiceIn__Chang__093F5D4E` · `ChangedBy -> AppUser(UserId)`
- FK `FK__ServiceIn__Inspe__075714DC` · `InspectorId -> AppUser(UserId)`
- FK `FK__ServiceIn__Order__056ECC6A` · `OrderId -> ServiceOrder(OrderId)`
- FK `FK__ServiceIn__Restr__084B3915` · `RestrictionId -> WorkerRestriction(RestrictionId)`
- FK `FK__ServiceIn__Worke__0662F0A3` · `WorkerId -> Worker(WorkerId)`
- PK `PK__ServiceI__30B2DC083573B275` · `InspectionId`
- CHECK `CK_ServiceInspection_Score` · `([Score]>=(0) AND [Score]<=(100))`
- CHECK `CK_ServiceInspection_Status` · `([Status]='CLOSED' OR [Status]='CORRECTED' OR [Status]='OPEN')`

## ServiceInspectionLog

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| LogId | bigint | 否 | 自增  |
| InspectionId | int | 否 |   |
| PreviousStatus | varchar(12) | 是 |   |
| CurrentStatus | varchar(12) | 否 |   |
| ActorId | int | 是 |   |
| ChangedAt | datetime2(0) | 否 |  `(sysutcdatetime())` |
| Correction | nvarchar(250) | 是 |   |

- FK `FK__ServiceIn__Actor__0EF836A4` · `ActorId -> AppUser(UserId)`
- FK `FK__ServiceIn__Inspe__0E04126B` · `InspectionId -> ServiceInspection(InspectionId)`
- PK `PK__ServiceI__5E548648CEBE7653` · `LogId`

## ServiceOrder

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| OrderId | int | 否 | 自增  |
| OrderNo | varchar(30) | 是 |   |
| ArchiveNo | varchar(20) | 否 |   |
| PlanId | int | 否 |   |
| ServiceTypeId | int | 否 |   |
| CommunityId | int | 否 |   |
| Status | varchar(24) | 否 |   |
| Price | decimal(12,2) | 否 |   |
| AppointmentStart | datetime2(0) | 否 |   |
| AppointmentEnd | datetime2(0) | 否 |   |
| Address | nvarchar(200) | 否 |   |
| Latitude | decimal(9,6) | 否 |   |
| Longitude | decimal(9,6) | 否 |   |
| Channel | varchar(12) | 否 |   |
| CreatedAt | datetime2(0) | 否 |  `(sysutcdatetime())` |
| DispatchDeadline | datetime2(0) | 否 |   |
| ReviewReason | nvarchar(250) | 是 |   |

- FK `FK__ServiceOr__Archi__3E1D39E1` · `ArchiveNo -> ElderArchive(ArchiveNo)`
- FK `FK__ServiceOr__Commu__40F9A68C` · `CommunityId -> Community(CommunityId)`
- FK `FK__ServiceOr__PlanI__3F115E1A` · `PlanId -> CarePlan(PlanId)`
- FK `FK__ServiceOr__Servi__40058253` · `ServiceTypeId -> ServiceType(ServiceTypeId)`
- PK `PK__ServiceO__C3905BCFD070CB63` · `OrderId`
- UNIQUE `UQ__ServiceO__C3907C7543BBCE3A` · `OrderNo`
- CHECK `CK__ServiceOr__Chann__45BE5BA9` · `([Channel]='COMMUNITY' OR [Channel]='FAMILY' OR [Channel]='PHONE')`
- CHECK `CK__ServiceOr__Latit__43D61337` · `([Latitude]>=(-90) AND [Latitude]<=(90))`
- CHECK `CK__ServiceOr__Longi__44CA3770` · `([Longitude]>=(-180) AND [Longitude]<=(180))`
- CHECK `CK__ServiceOr__Price__42E1EEFE` · `([Price]>=(0))`
- CHECK `CK__ServiceOr__Statu__41EDCAC5` · `([Status]='CANCELLED' OR [Status]='RESCHEDULE' OR [Status]='REVIEW' OR [Status]='COMPLETED' OR [Status]='AWAITING_CONFIRMATION' OR [Status]='IN_SERVICE' OR [Status]='ACCEPTED' OR [Status]='OFFERED' OR [Status]='POOL' OR [Status]='NEW')`
- CHECK `CK__ServiceOrder__47A6A41B` · `([AppointmentEnd]>[AppointmentStart])`

## ServiceType

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| ServiceTypeId | int | 否 | 自增  |
| Code | varchar(30) | 否 |   |
| Name | nvarchar(100) | 否 |   |
| Unit | nvarchar(8) | 否 |   |
| Rate | decimal(10,2) | 否 |   |
| StandardMinutes | smallint | 否 |   |
| Subsidizable | bit | 否 |  `((1))` |
| CategoryCode | varchar(12) | 是 | 助餐、助浴、陪诊、家政、康复护理；旧记录可为空 |

- PK `PK__ServiceT__8ADFAA6C80D5876F` · `ServiceTypeId`
- UNIQUE `UQ__ServiceT__737584F62A846AA3` · `Name`
- UNIQUE `UQ__ServiceT__A25C5AA7D335E911` · `Code`
- CHECK `CK__ServiceTy__Stand__06CD04F7` · `([StandardMinutes]>(0))`
- CHECK `CK__ServiceTyp__Rate__05D8E0BE` · `([Rate]>=(0))`
- CHECK `CK__ServiceTyp__Unit__04E4BC85` · `([Unit]=N'小时' OR [Unit]=N'次')`

## ServiceVisit

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| OrderId | int | 否 |   |
| DispatchId | int | 否 |   |
| WorkerId | int | 否 |   |
| CheckInAt | datetime2(0) | 否 |   |
| CheckOutAt | datetime2(0) | 是 |   |
| InLatitude | decimal(9,6) | 否 |   |
| InLongitude | decimal(9,6) | 否 |   |
| OutLatitude | decimal(9,6) | 是 |   |
| OutLongitude | decimal(9,6) | 是 |   |
| InFence | bit | 否 |   |
| OutFence | bit | 是 |   |
| InShift | bit | 否 |   |
| OutShift | bit | 是 |   |
| ExpiredDuringVisit | bit | 否 |  `((0))` |
| ServiceRecord | nvarchar(500) | 是 |   |
| WorkStatus | varchar(12) | 否 |   |
| EffectiveMinutes | int | 是 |   |
| ReviewReason | nvarchar(250) | 是 |   |
| ConfirmedAt | datetime2(0) | 是 |   |
| ConfirmedBy | int | 是 |   |
| ConfirmationText | nvarchar(200) | 是 |   |
| ConfirmationHash | varbinary(32) | 是 |   |
| SubsidyCategory | varchar(12) | 是 | 签到时的补贴对象类别；与等级快照同时有值或同时为空 |
| SubsidyAbilityLevel | nvarchar(20) | 是 | 签到时有效评估的能力等级；旧记录可为空 |
| FeedbackScore | tinyint | 是 |   |
| Feedback | nvarchar(300) | 是 |   |
| ComplaintText | nvarchar(300) | 是 |   |
| ComplainedAt | datetime2(0) | 是 |   |
| ComplainedBy | int | 是 |   |
| ComplaintResolution | nvarchar(300) | 是 |   |
| ComplaintResolvedAt | datetime2(0) | 是 |   |
| ComplaintResolvedBy | int | 是 |   |

- FK `FK__ServiceVi__Dispa__58D1301D` · `DispatchId -> ServiceDispatch(DispatchId)`
- FK `FK__ServiceVi__Order__57DD0BE4` · `OrderId -> ServiceOrder(OrderId)`
- FK `FK__ServiceVi__Worke__59C55456` · `WorkerId -> Worker(WorkerId)`
- PK `PK__ServiceV__C3905BCFABD8AE08` · `OrderId`
- UNIQUE `UQ__ServiceV__434DBD544F7C8108` · `DispatchId`
- CHECK `CK__ServiceVi__Effec__607251E5` · `([EffectiveMinutes]>=(0))`
- CHECK `CK__ServiceVi__Feedb__6166761E` · `([FeedbackScore]>=(1) AND [FeedbackScore]<=(5))`
- CHECK `CK__ServiceVi__InLat__5AB9788F` · `([InLatitude]>=(-90) AND [InLatitude]<=(90))`
- CHECK `CK__ServiceVi__InLon__5BAD9CC8` · `([InLongitude]>=(-180) AND [InLongitude]<=(180))`
- CHECK `CK__ServiceVi__OutLa__5CA1C101` · `([OutLatitude]>=(-90) AND [OutLatitude]<=(90))`
- CHECK `CK__ServiceVi__OutLo__5D95E53A` · `([OutLongitude]>=(-180) AND [OutLongitude]<=(180))`
- CHECK `CK__ServiceVi__WorkS__5F7E2DAC` · `([WorkStatus]='REJECTED' OR [WorkStatus]='REVIEW' OR [WorkStatus]='VALID' OR [WorkStatus]='OPEN')`
- CHECK `CK__ServiceVisit__625A9A57` · `([CheckOutAt]>=[CheckInAt])`
- CHECK `CK_ServiceVisit_Confirmation` · `([ConfirmedAt] IS NULL AND [ConfirmedBy] IS NULL AND [ConfirmationText] IS NULL AND [ConfirmationHash] IS NULL OR [ConfirmedAt] IS NOT NULL AND [ConfirmedAt]>=[CheckOutAt] AND [CheckOutAt] IS NOT NULL AND [ConfirmedBy] IS NOT NULL AND len([ConfirmationText])>(0) AND [ConfirmationText] IS NOT NULL AND [ConfirmationHash] IS NOT NULL)`

## ServiceVisitAudit

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| AuditId | int | 否 | 自增  |
| OrderId | int | 否 |   |
| OldStatus | varchar(12) | 是 |   |
| NewStatus | varchar(12) | 否 |   |
| Reason | nvarchar(250) | 是 |   |
| LoggedAt | datetime2(0) | 否 |  `(sysutcdatetime())` |

- FK `FK__ServiceVi__Order__662B2B3B` · `OrderId -> ServiceVisit(OrderId)`
- PK `PK__ServiceV__A17F2398999D7FDD` · `AuditId`

## SubsidyClaim

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| ClaimId | int | 否 | 自增  |
| ArchiveNo | varchar(20) | 否 |   |
| CommunityId | int | 否 |   |
| ServiceTypeId | int | 否 |   |
| PeriodMonth | date | 否 |   |
| Status | varchar(12) | 否 |  `('DRAFT')` |
| TotalAmount | decimal(14,2) | 否 |  `((0))` |
| SubmittedAt | datetime2(0) | 是 |   |
| ApprovedAt | datetime2(0) | 是 |   |
| PaidAt | datetime2(0) | 是 |   |
| ChangedBy | int | 是 |   |
| ChangeNote | nvarchar(250) | 否 |  `(N'')` |

- FK `FK__SubsidyCl__Archi__6E8B6712` · `ArchiveNo -> ElderArchive(ArchiveNo)`
- FK `FK__SubsidyCl__Chang__73501C2F` · `ChangedBy -> AppUser(UserId)`
- FK `FK__SubsidyCl__Commu__6F7F8B4B` · `CommunityId -> Community(CommunityId)`
- FK `FK__SubsidyCl__Servi__7073AF84` · `ServiceTypeId -> ServiceType(ServiceTypeId)`
- PK `PK__SubsidyC__EF2E139B8DDF1A33` · `ClaimId`
- UNIQUE `UQ_SubsidyClaim_Period` · `ArchiveNo, ServiceTypeId, PeriodMonth`
- CHECK `CK_SubsidyClaim_Period` · `(datepart(day,[PeriodMonth])=(1))`
- CHECK `CK_SubsidyClaim_Status` · `([Status]='PAID' OR [Status]='APPROVED' OR [Status]='RETURNED' OR [Status]='CIVIL' OR [Status]='STREET' OR [Status]='DRAFT')`
- CHECK `CK_SubsidyClaim_Total` · `([TotalAmount]>=(0))`

## SubsidyClaimLog

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| LogId | bigint | 否 | 自增  |
| ClaimId | int | 否 |   |
| PreviousStatus | varchar(12) | 是 |   |
| CurrentStatus | varchar(12) | 否 |   |
| ActorId | int | 是 |   |
| ChangedAt | datetime2(0) | 否 |  `(sysutcdatetime())` |
| Note | nvarchar(250) | 否 |   |
| TotalAmount | decimal(14,2) | 否 |   |
| OrderSnapshot | nvarchar(max) | 否 |   |
| EvidenceSnapshot | nvarchar(max) | 是 | 每次提交时生成的 JSON 数组；旧版本无证明快照 |

- FK `FK__SubsidyCl__Actor__019E3B86` · `ActorId -> AppUser(UserId)`
- FK `FK__SubsidyCl__Claim__00AA174D` · `ClaimId -> SubsidyClaim(ClaimId)`
- PK `PK__SubsidyC__5E548648E39BBDBF` · `LogId`

## SubsidyClaimOrder

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| ClaimId | int | 否 |   |
| OrderId | int | 否 |   |
| PolicyId | int | 否 |   |
| ServiceCompletedAt | datetime2(0) | 否 |   |
| ConfirmedAt | datetime2(0) | 否 |   |
| EffectiveMinutes | int | 否 |   |
| OrderPrice | decimal(14,2) | 否 |   |
| HourlyRate | decimal(10,2) | 否 |   |
| MaxPerOrder | decimal(10,2) | 否 |   |
| Amount | decimal(14,2) | 否 |   |
| SubsidyCategory | varchar(12) | 是 | 本次申报使用的对象类别快照 |
| SubsidyAbilityLevel | nvarchar(20) | 是 | 本次申报使用的能力等级快照 |

- FK `FK__SubsidyCl__Claim__7AF13DF7` · `ClaimId -> SubsidyClaim(ClaimId)`
- FK `FK__SubsidyCl__Order__7BE56230` · `OrderId -> ServiceOrder(OrderId)`
- FK `FK__SubsidyCl__Polic__7CD98669` · `PolicyId -> SubsidyPolicy(PolicyId)`
- PK `PK_SubsidyClaimOrder` · `ClaimId, OrderId`
- UNIQUE `UQ_SubsidyClaimOrder_Order` · `OrderId`
- CHECK `CK_SubsidyClaimOrder_Values` · `([EffectiveMinutes]>(0) AND [OrderPrice]>=(0) AND [Amount]>=(0) AND [Amount]<=[OrderPrice] AND [Amount]<=[MaxPerOrder])`

## SubsidyPolicy

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| PolicyId | int | 否 | 自增  |
| PolicyName | nvarchar(100) | 否 |   |
| District | nvarchar(80) | 否 |   |
| ServiceTypeId | int | 否 |   |
| ValidFrom | date | 否 |   |
| ValidThrough | date | 否 |   |
| HourlyRate | decimal(10,2) | 否 |   |
| MaxPerOrder | decimal(10,2) | 否 |   |
| BeneficiaryCategory | varchar(12) | 否 | `ANY`（通用，默认）、`GENERAL` 或 `LOW_INCOME` |
| AbilityLevel | nvarchar(20) | 否 | 五种能力等级或「通用」（默认） |
| SettlementCycle | varchar(8) | 否 | `MONTH`，北京时间自然月 |

- FK `FK__SubsidyPo__Servi__68D28DBC` · `ServiceTypeId -> ServiceType(ServiceTypeId)`
- PK `PK__SubsidyP__2E1339A46B40CC65` · `PolicyId`
- UNIQUE `UQ_SubsidyPolicy_BasisStart` · `District, ServiceTypeId, BeneficiaryCategory, AbilityLevel, ValidFrom`
- CHECK `CK_SubsidyPolicy_Dates` · `([ValidThrough]>=[ValidFrom])`
- CHECK `CK_SubsidyPolicy_Rates` · `([HourlyRate]>(0) AND [MaxPerOrder]>(0))`

## Worker

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| WorkerId | int | 否 | 自增  |
| WorkerNo | varchar(30) | 否 |   |
| AgencyId | int | 否 |   |
| Name | nvarchar(100) | 否 |   |
| Grade | nvarchar(40) | 否 |   |
| Rating | decimal(3,2) | 否 |  `((5))` |
| TrainingCompletedOn | date | 是 |   |
| EmploymentStatus | varchar(10) | 否 | `ON_DUTY`（在岗，默认）、`ON_LEAVE`（请假）、`LEFT`（离职） |

- FK `FK__Worker__AgencyId__0E6E26BF` · `AgencyId -> Agency(AgencyId)`
- PK `PK__Worker__077C882643AE5EE4` · `WorkerId`
- UNIQUE `UQ__Worker__077F569C4A7EF9EB` · `WorkerNo`
- CHECK `CK__Worker__Rating__10566F31` · `([Rating]>=(0) AND [Rating]<=(5))`
- CHECK `CK_Worker_EmploymentStatus` · 仅允许在岗、请假、离职。

## WorkerCommunity

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| WorkerId | int | 否 |   |
| CommunityId | int | 否 |   |

- FK `FK__WorkerCom__Commu__151B244E` · `CommunityId -> Community(CommunityId)`
- FK `FK__WorkerCom__Worke__14270015` · `WorkerId -> Worker(WorkerId)`
- PK `PK__WorkerCo__8BB62D90380F82B7` · `WorkerId, CommunityId`

## WorkerRestriction

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| RestrictionId | int | 否 | 自增  |
| WorkerId | int | 否 |   |
| Reason | nvarchar(250) | 否 |   |
| CreatedAt | datetime2(0) | 否 |  `(sysutcdatetime())` |
| ResolvedAt | datetime2(0) | 是 |   |

- FK `FK__WorkerRes__Worke__1CBC4616` · `WorkerId -> Worker(WorkerId)`
- PK `PK__WorkerRe__529D86BABBCA58D8` · `RestrictionId`
- CHECK `CK__WorkerRestrictio__1EA48E88` · `([ResolvedAt]>=[CreatedAt])`

## WorkerService

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| WorkerId | int | 否 |   |
| ServiceTypeId | int | 否 |   |
| CredentialNo | nvarchar(60) | 否 |   |
| ValidFrom | date | 否 |   |
| ValidThrough | date | 否 |   |
| CredentialType | nvarchar(40) | 是 | 证书类型；旧记录可为空 |
| CredentialLevel | nvarchar(40) | 是 | 证书等级；旧记录可为空 |

- FK `FK__WorkerSer__Servi__18EBB532` · `ServiceTypeId -> ServiceType(ServiceTypeId)`
- FK `FK__WorkerSer__Worke__17F790F9` · `WorkerId -> Worker(WorkerId)`
- PK `PK__WorkerSe__DFD172801451E847` · `WorkerId, ServiceTypeId`
- CHECK `CK__WorkerService__19DFD96B` · `([ValidThrough]>=[ValidFrom])`

## WorkerShift

| 字段 | 类型 | 可空 | 默认值或属性 |
|---|---|---|---|
| ShiftId | int | 否 | 自增  |
| WorkerId | int | 否 |   |
| StartsAt | datetime2(0) | 否 |   |
| EndsAt | datetime2(0) | 否 |   |
| Capacity | int | 否 |   |
| IsOpen | bit | 否 |  `((1))` |

- FK `FK__WorkerShi__Worke__22751F6C` · `WorkerId -> Worker(WorkerId)`
- PK `PK__WorkerSh__C0A838812D942195` · `ShiftId`
- UNIQUE `UQ__WorkerSh__2D7D19384AED56E2` · `WorkerId, StartsAt`
- CHECK `CK__WorkerShi__Capac__236943A5` · `([Capacity]>(0))`
- CHECK `CK__WorkerShift__25518C17` · `([EndsAt]>[StartsAt])`
