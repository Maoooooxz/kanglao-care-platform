# 康老系统 v0.1

社区居家养老智慧服务平台的第一版，使用 SQL Server Express 完成建库、建档、脱敏查询和跨社区迁移。

## 运行

在 SSMS 中用 Windows 身份连接本机 `.\SQLEXPRESS`，依次打开并执行以下两个完整脚本。首次运行需要建库权限。

1. [01_init.sql](sql/01_init.sql) 创建 `KanglaoCourse`、社区表、老人档案表和档案摘要视图，加入 2 个社区和 3 份模拟档案。
2. [02_verify.sql](sql/02_verify.sql) 验证建档、脱敏查询、重复证件号和档案编号、社区外键及跨社区迁移。测试写入在事务内回滚，成功时显示 `PASS` 和 3 份样例档案。

也可以在项目目录使用 Windows 上的 `sqlcmd` 执行。第一条命令成功后再执行第二条。`-C` 用于信任本机开发实例的证书。

```powershell
sqlcmd -S 'lpc:.\SQLEXPRESS' -E -C -b -f 65001 -i '.\sql\01_init.sql'
sqlcmd -S 'lpc:.\SQLEXPRESS' -E -C -b -f 65001 -i '.\sql\02_verify.sql'
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
