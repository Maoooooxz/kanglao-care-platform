from threading import Thread

import pytest
from playwright.sync_api import sync_playwright
from werkzeug.serving import make_server


@pytest.fixture(scope="module")
def website(application):
    server = make_server("127.0.0.1", 0, application, threaded=True)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        thread.join(timeout=5)
        server.server_close()


def login(page, website, username, password):
    page.goto(f"{website}/login")
    page.get_by_label("用户名").fill(username)
    page.get_by_label("密码").fill(password)
    page.get_by_role("button", name="登录", exact=True).click()
    page.wait_for_url(f"{website}/")


def test_desktop_and_mobile_browser(website, password, tmp_path, monkeypatch):
    browser_temp = tmp_path / "browser-runtime"
    browser_temp.mkdir()
    monkeypatch.setenv("TEMP", str(browser_temp))
    monkeypatch.setenv("TMP", str(browser_temp))
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(channel="msedge", headless=True, timeout=15000)
        try:
            desktop = browser.new_page(viewport={"width": 1440, "height": 1000})
            login(desktop, website, "community", password)
            desktop.locator("main h1").wait_for()
            desktop.screenshot(path=tmp_path / "community-desktop.png")
            nav = desktop.get_by_role("navigation", name="工作台导航")
            for label in ("档案", "照护计划", "订单", "人员与排班", "健康与应急", "补贴与抽查"):
                with desktop.expect_navigation() as result:
                    nav.get_by_role("link", name=label, exact=True).click()
                assert result.value.ok, label
                assert desktop.locator("main h1").is_visible()
            desktop.close()
            mobile = browser.new_page(viewport={"width": 390, "height": 844}, is_mobile=True,
                                      has_touch=True, device_scale_factor=2)
            login(mobile, website, "family", password)
            response = mobile.goto(f"{website}/health/")
            assert response.ok
            assert mobile.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
            report = mobile.get_by_role("region", name="一键呼叫", exact=True)
            with mobile.expect_navigation() as outcome:
                report.get_by_role("button", name="立即呼叫").click()
            assert outcome.value.ok
            assert "一键呼叫" in mobile.get_by_role("region", name="应急事件", exact=True).inner_text()
            mobile.screenshot(path=tmp_path / "family-mobile.png")
        finally:
            browser.close()
