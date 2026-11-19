from contextlib import contextmanager

from flask import current_app, g
import mssql_python


def connect(connection_string):
    db = mssql_python.connect(connection_string, autocommit=False)
    cur = db.cursor()
    try:
        cur.execute("""SET ANSI_NULLS ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON;
            SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON;
            SET NUMERIC_ROUNDABORT OFF; SET QUOTED_IDENTIFIER ON;""")
        db.commit()
    except BaseException:
        cur.close()
        db.close()
        raise
    cur.close()
    return db


def connection():
    if "db" not in g:
        g.db = connect(current_app.config["DB_CONNECTION"])
    return g.db


def close_db(_error=None):
    db = g.pop("db", None)
    if db is not None:
        db.close()


@contextmanager
def transaction():
    db = connection()
    depth = g.get("db_depth", 0)
    if depth == 0:
        g.db_failed = False
    g.db_depth = depth + 1
    try:
        yield db
        if depth == 0:
            if g.db_failed:
                raise RuntimeError("嵌套操作已回滚")
            db.commit()
    except BaseException:
        g.db_failed = True
        if depth == 0:
            db.rollback()
        raise
    finally:
        g.db_depth = depth


def _run(sql, params, returned_rows):
    db = connection()
    cur = db.cursor()
    try:
        cur.execute(sql, params) if params else cur.execute(sql)
        if returned_rows:
            while cur.description is None and cur.nextset():
                pass
            if cur.description is None:
                result = []
            else:
                keys = [column[0] for column in cur.description]
                result = [dict(zip(keys, row)) for row in cur.fetchall()]
        else:
            result = cur.rowcount
    except BaseException:
        if g.get("db_depth"):
            g.db_failed = True
        else:
            db.rollback()
        raise
    finally:
        cur.close()
    if not g.get("db_depth"):
        db.commit()
    return result


def query(sql, *params):
    return _run(sql, params, True)


def one(sql, *params):
    rows = query(sql, *params)
    return rows[0] if rows else None


def execute(sql, *params):
    return _run(sql, params, False)


def execute_many(sql, rows):
    db = connection()
    cur = db.cursor()
    try:
        cur.executemany(sql, rows)
        if not g.get("db_depth"):
            db.commit()
    except BaseException:
        if g.get("db_depth"):
            g.db_failed = True
        else:
            db.rollback()
        raise
    finally:
        cur.close()
