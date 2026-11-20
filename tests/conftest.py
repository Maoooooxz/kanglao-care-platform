import os

import pytest
from dotenv import load_dotenv

from kanglao import ROOT, create_app
from kanglao.__main__ import DEMO_COMMUNITY_PASSWORD, database_config


@pytest.fixture(scope="session")
def application():
    load_dotenv(ROOT / ".env")
    database = os.getenv("KANG_LAO_TEST_DATABASE", "KanglaoCourse_QA")
    if not database.startswith("KanglaoCourse_"):
        raise ValueError("集成测试需要独立的北林之家测试数据库")
    return create_app({"TESTING": True, **database_config(database)})


@pytest.fixture(scope="session")
def password(application):
    class DemoPassword(str):
        def __repr__(self):
            return "<demo password>"

    return DemoPassword(os.environ["KANG_LAO_DEMO_PASSWORD"])


def log_in(client, username, password):
    assert client.get("/login").status_code == 200
    with client.session_transaction() as session:
        token = session["csrf"]
    result = client.post("/login", data=dict(username=username, password=login_password(username, password), csrf_token=token))
    assert result.status_code == 302, result.get_data(as_text=True)
    assert client.get("/").status_code == 200


def login_password(username, password):
    return DEMO_COMMUNITY_PASSWORD if username == "community" else password


def submit(client, path, **fields):
    with client.session_transaction() as session:
        token = session["csrf"]
    return client.post(path, data={"csrf_token": token, **fields})
