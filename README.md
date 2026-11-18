# 康老系统 v0.2

社区居家养老智慧服务平台的 SQL Server 版本。v0.1 完成建库、建档、脱敏查询和跨社区迁移，v0.2 增加能力评估录入、历史查询和有效期判断。

## 运行

在 SSMS 中用 Windows 身份连接本机 `.\SQLEXPRESS`，依次打开并执行以下完整脚本。首次运行需要建库权限。已有 v0.1 数据库时，从第 3 步开始即可。

1. [01_init.sql](sql/01_init.sql) 创建 `KanglaoCourse`、社区表、老人档案表和档案摘要视图，加入 2 个社区和 3 份模拟档案。
2. [02_verify.sql](sql/02_verify.sql) 验证建档、脱敏查询、重复证件号和档案编号、社区外键及跨社区迁移。测试写入在事务内回滚，成功时显示 `PASS` 和 3 份样例档案。
3. [03_add_ability_assessment.sql](sql/03_add_ability_assessment.sql) 建立评估表、录入存储过程和两个评估视图，加入 3 条模拟评估。
4. [04_verify_assessment.sql](sql/04_verify_assessment.sql) 验证录入、历史记录、到期边界和约束。验证数据在事务内回滚。

也可以在项目目录使用 Windows 上的 `sqlcmd` 执行。逐条确认成功后再执行下一条。`-C` 用于信任本机开发实例的证书。

```powershell
sqlcmd -S 'lpc:.\SQLEXPRESS' -E -C -b -f 65001 -i '.\sql\01_init.sql'
sqlcmd -S 'lpc:.\SQLEXPRESS' -E -C -b -f 65001 -i '.\sql\02_verify.sql'
sqlcmd -S 'lpc:.\SQLEXPRESS' -E -C -b -f 65001 -i '.\sql\03_add_ability_assessment.sql'
sqlcmd -S 'lpc:.\SQLEXPRESS' -E -C -b -f 65001 -i '.\sql\04_verify_assessment.sql'
```

## 查询和迁移示例

在 SSMS 查询窗口执行以下语句。`E0001` 的证件号显示为 `**************0001`。迁移更新原档案的社区，档案编号仍为 `E0001`。示例最后回滚，方便反复演示。

```sql
USE [KanglaoCourse];
GO

SELECT ArchiveNo, FullName, CommunityName, MaskedIdNumber
FROM dbo.v_ElderArchiveSummary
WHERE ArchiveNo = 'E0001';

BEGIN TRANSACTION;

UPDATE dbo.ElderArchive
SET CommunityId = 2
WHERE ArchiveNo = 'E0001';

SELECT ArchiveNo, CommunityName, MaskedIdNumber
FROM dbo.v_ElderArchiveSummary
WHERE ArchiveNo = 'E0001';

ROLLBACK TRANSACTION;
```

`ElderArchive.IdNumber` 是主键，`ArchiveNo` 设有唯一约束，`CommunityId` 引用社区表。日常演示查询使用脱敏视图。样例姓名、地址和证件号均为模拟数据。再次执行初始化脚本会跳过已存在的样例档案。

## 录入与查询能力评估

用 `dbo.usp_RecordAbilityAssessment` 按唯一评估编号录入。量表代码为 `ADL` 或 `MMSE`，能力等级由评估员录入，样例分数和等级仅用于演示。以下示例为 `E0003` 添加评估，在事务内查看结果后回滚。

```sql
USE [KanglaoCourse];
GO

DECLARE @Today date = CONVERT(date, SYSDATETIME());
DECLARE @ValidThrough date = DATEADD(day, 30, @Today);

BEGIN TRANSACTION;

EXEC dbo.usp_RecordAbilityAssessment
    @AssessmentNo = 'DEMO-ASMT-MANUAL', @ArchiveNo = 'E0003', @ScaleCode = 'ADL',
    @Score = 75, @AbilityLevel = N'轻度失能', @EvaluatorName = N'演示评估员',
    @AssessmentDate = @Today, @ValidThrough = @ValidThrough;

SELECT ArchiveNo, AssessmentNo, AbilityLevel, ValidThrough, AssessmentStatus
FROM dbo.v_CurrentAbilityAssessment
ORDER BY ArchiveNo;

SELECT AssessmentNo, ScaleCode, Score, AbilityLevel, AssessmentDate, ValidThrough
FROM dbo.v_AbilityAssessmentHistory
WHERE ArchiveNo = 'E0001'
ORDER BY AssessmentDate DESC, AssessmentId DESC;

ROLLBACK TRANSACTION;
```

当前状态按 SQL Server 本机日期计算。先取截至当天的最新评估，同日以录入顺序为准，再判断有效期。截止日当天仍有效，次日显示「已过期」。无记录则显示「未评估」。样例截止日期只在首次添加记录时计算，重复升级沿用原日期。
