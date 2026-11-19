"""从已装载的 SQL Server 数据库生成数据字典和实际执行计划对照。"""

import argparse
import re
from collections import Counter, defaultdict
from pathlib import Path
from xml.etree import ElementTree

from kanglao import LOCAL_CONNECTION, ROOT
from kanglao.__main__ import database_name
from kanglao.db import connect

VARIANT = re.compile(r"^-- (?:写法 )?([AB])(?:[ \t：:，、]|$).*$", re.MULTILINE)
PLAN_NS = {"p": "http://schemas.microsoft.com/sqlserver/2004/07/showplan"}
COMMON_NOISE = re.compile(
    r"^(?:USE .*;|GO|SET (?:NOCOUNT|STATISTICS [A-Z]+) (?:ON|OFF);)\s*$", re.M | re.I
)


def results(db, statement):
    cursor = db.cursor()
    try:
        cursor.execute(statement)
        while True:
            if cursor.description:
                keys = [column[0] for column in cursor.description]
                yield keys, [tuple(row) for row in cursor.fetchall()]
            if not cursor.nextset():
                break
    finally:
        cursor.close()
        db.rollback()


def data_dictionary(db):
    sections = defaultdict(list)
    _, columns = next(results(db, """SELECT t.name,c.name,ty.name,c.max_length,c.precision,c.scale,
        c.is_nullable,c.is_identity,ISNULL(d.definition,N'') FROM sys.tables t
        JOIN sys.columns c ON c.object_id=t.object_id JOIN sys.types ty ON ty.user_type_id=c.user_type_id
        LEFT JOIN sys.default_constraints d ON d.object_id=c.default_object_id
        WHERE t.schema_id=SCHEMA_ID('dbo') ORDER BY t.name,c.column_id;"""))
    for table, name, kind, length, precision, scale, nullable, identity, default in columns:
        if kind in {"nvarchar", "nchar", "varchar", "char", "varbinary", "binary"}:
            kind += f"({('max' if length < 0 else length // 2 if kind.startswith('n') else length)})"
        elif kind in {"decimal", "numeric"}:
            kind += f"({precision},{scale})"
        elif kind in {"datetime2", "datetimeoffset", "time"}:
            kind += f"({scale})"
        sections[table].append(f"| {name} | {kind} | {'是' if nullable else '否'} | "
                               f"{'自增' if identity else ''} {'\x60' + default + '\x60' if default else ''} |")

    _, relations = next(results(db, """SELECT t.name,i.name,
        CASE WHEN i.is_primary_key=1 THEN 'PK' ELSE 'UNIQUE' END,
        STRING_AGG(c.name,', ') WITHIN GROUP (ORDER BY ic.key_ordinal)
        FROM sys.tables t JOIN sys.indexes i ON i.object_id=t.object_id
        JOIN sys.index_columns ic ON ic.object_id=i.object_id AND ic.index_id=i.index_id AND ic.key_ordinal>0
        JOIN sys.columns c ON c.object_id=t.object_id AND c.column_id=ic.column_id
        WHERE (i.is_primary_key=1 OR i.is_unique=1) AND t.schema_id=SCHEMA_ID('dbo')
        GROUP BY t.name,i.name,i.is_primary_key
        UNION ALL
        SELECT t.name,f.name,'FK',
           STRING_AGG(c.name,', ') WITHIN GROUP (ORDER BY fc.constraint_column_id)
           + ' -> ' + OBJECT_NAME(f.referenced_object_id) + '('
           + STRING_AGG(r.name,', ') WITHIN GROUP (ORDER BY fc.constraint_column_id) + ')'
        FROM sys.foreign_keys f JOIN sys.tables t ON t.object_id=f.parent_object_id
        JOIN sys.foreign_key_columns fc ON fc.constraint_object_id=f.object_id
        JOIN sys.columns c ON c.object_id=fc.parent_object_id AND c.column_id=fc.parent_column_id
        JOIN sys.columns r ON r.object_id=fc.referenced_object_id AND r.column_id=fc.referenced_column_id
        WHERE t.schema_id=SCHEMA_ID('dbo')
        GROUP BY t.name,f.name,f.referenced_object_id ORDER BY 1,3,2;"""))
    _, checks = next(results(db, """SELECT OBJECT_NAME(parent_object_id),name,definition
        FROM sys.check_constraints
        WHERE OBJECT_SCHEMA_NAME(parent_object_id)='dbo' ORDER BY 1,2;"""))
    descriptions = defaultdict(list)
    for table, key, category, field_names in relations:
        descriptions[table].append(f"- {category} \x60{key}\x60 · \x60{field_names}\x60")
    for table, key, expression in checks:
        descriptions[table].append(f"- CHECK \x60{key}\x60 · \x60{expression.replace(chr(10), ' ').replace(chr(13), ' ')}\x60")

    report = ["# SQL Server 数据字典", "", "字段、键与约束来自已应用迁移的 SQL Server 元数据。", ""]
    for table, rows in sections.items():
        report += [f"## {table}", "", "| 字段 | 类型 | 可空 | 默认值或属性 |", "|---|---|---|---|", *rows, ""]
        report += [*descriptions[table], ""]
    return "\n".join(report)


def capture(db, prefix, statement):
    rows = []
    plans = []
    for keys, values in results(db, f"{prefix}\nSET STATISTICS XML ON;\n{statement}\nSET STATISTICS XML OFF;"):
        if len(keys) == 1 and values and "ShowPlanXML" in str(values[0][0]):
            plans.extend(ElementTree.fromstring(row[0]) for row in values)
        else:
            rows.extend(values)
    if not plans:
        raise AssertionError("SQL Server 未返回实际执行计划")
    operators = set()
    indexes = set()
    reads = 0
    for plan in plans:
        operators.update(rel.get("PhysicalOp") for rel in plan.findall(".//p:RelOp", PLAN_NS))
        indexes.update(obj.get("Index") for obj in plan.findall(".//p:Object", PLAN_NS) if obj.get("Index"))
        reads += sum(int(item.get("ActualLogicalReads", 0)) for item in
                     plan.findall(".//p:RunTimeCountersPerThread", PLAN_NS))
    return Counter(rows), "、".join(sorted(operators)), "、".join(sorted(indexes)) or "—", reads


def comparison_report(db):
    rows = ["# 关键查询对照", "",
            "在 SQL Server Express 17 的合成数据上逐条执行两种写法。逐行比较结果多重集合，并记录实际执行计划中的算子、索引和逻辑读。逻辑读为计划中各运行线程计数之和，执行结果可随数据规模和统计信息变化。",
            "", "| 脚本与场景 | 行数 | A 写法的算子和索引 | B 写法的算子和索引 | 逻辑读 A / B |",
            "|---|---:|---|---|---:|"]
    pairs = 0
    for path in sorted((ROOT / "sql").glob("*_queries_*.sql")):
        body = COMMON_NOISE.sub("", path.read_text(encoding="utf-8-sig"))
        markers = list(VARIANT.finditer(body))
        if not markers or [m[1] for m in markers] != ["A", "B"] * (len(markers) // 2):
            raise ValueError(f"{path.name} 应按 A/B 顺序标记查询。")
        prefix = body[:markers[0].start()]
        readings = []
        for i, marker in enumerate(markers):
            next_position = markers[i + 1].start() if i + 1 < len(markers) else len(body)
            statement = body[marker.end():next_position].strip()
            readings.append(capture(db, prefix, statement))
        for i in range(0, len(readings), 2):
            count_a, operators_a, indexes_a, reads_a = readings[i]
            count_b, operators_b, indexes_b, reads_b = readings[i+1]
            if count_a != count_b:
                raise AssertionError(f"{path.name} 场景 {i // 2 + 1} 两种结果不同")
            pairs += 1
            rows.append(f"| [{path.stem}](../sql/{path.name}) · {i // 2 + 1} | {sum(count_a.values())} | "
                        f"{operators_a} · {indexes_a} | {operators_b} · {indexes_b} | "
                        f"{reads_a} / {reads_b} |")
    if pairs != 15:
        raise AssertionError(f"预期 15 个查询对，实际 {pairs}")
    rows.extend(["", "五条业务线的查询覆盖当前评估、派单历史、班次工时、体征事件和补贴明细。"
                 "按档案、班次、待处理状态或辖区执行筛选，索引设计见数据库设计说明。", ""])
    print(f"已验证 {pairs} 个 SQL 查询场景的两种写法。")
    return "\n".join(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", type=database_name, default="KanglaoCourse_QA")
    parser.add_argument("--out", type=Path, default=ROOT / "docs")
    args = parser.parse_args()
    db = connect(LOCAL_CONNECTION.replace("Database=KanglaoCourse;", f"Database={args.database};"))
    try:
        dictionary = data_dictionary(db)
        comparisons = comparison_report(db)
    finally:
        db.close()
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "data-dictionary.md").write_text(dictionary, encoding="utf-8", newline="\n")
    (args.out / "query-plans.md").write_text(comparisons, encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main()
