import os
import importlib
from pathlib import Path


def _load_main_with_root(tmp_path):
    """Import dashboard.main with MH_ROOT pointed at a temp tree (constants resolve at import)."""
    os.environ["MH_ROOT"] = str(tmp_path)
    import main  # noqa: E402
    return importlib.reload(main)


def test_read_exposures_parses_and_skips_comments(tmp_path):
    reg = tmp_path / "registry"
    reg.mkdir()
    (reg / "exposures.tsv").write_text(
        "# name\tfqdn\tzone\tport\n"
        "smoke\tsmoke.dev.example.com\tdev\t8011\n"
        "api\tapi.example.com\tprod\t8012\n"
    )
    main = _load_main_with_root(tmp_path)
    exp = main.read_exposures()
    assert exp["smoke"] == {"fqdn": "smoke.dev.example.com", "zone": "dev", "domain": ""}
    assert exp["api"] == {"fqdn": "api.example.com", "zone": "prod", "domain": ""}
    assert "#" not in exp


def test_read_exposures_empty_when_missing(tmp_path):
    (tmp_path / "registry").mkdir()
    main = _load_main_with_root(tmp_path)
    assert main.read_exposures() == {}


def test_env_payload_shapes_and_filters(tmp_path):
    import json
    main = _load_main_with_root(tmp_path)
    # keeps valid pairs, trims names, coerces values to str, drops nameless/garbage entries
    out = main.env_payload({"env": [
        {"name": " S3_BUCKET ", "value": "b"},
        {"name": "N", "value": 5},
        {"name": "", "value": "skip"},
        {"value": "no name"},
        "not a dict",
    ]})
    assert json.loads(out) == [
        {"name": "S3_BUCKET", "value": "b"},
        {"name": "N", "value": "5"},
    ]


def test_env_payload_empty_when_absent_or_bad(tmp_path):
    import json
    main = _load_main_with_root(tmp_path)
    assert json.loads(main.env_payload({})) == []
    assert json.loads(main.env_payload({"env": None})) == []
    assert json.loads(main.env_payload({"env": "nope"})) == []


def test_read_domains_orders_and_defaults(tmp_path):
    reg = tmp_path / "registry"
    reg.mkdir()
    (reg / "domains.tsv").write_text(
        "# domain\tdev_base\n"
        "example.com\tdev.example.com\n"
        "example.org\n"          # missing dev_base column -> derived dev.example.org
    )
    main = _load_main_with_root(tmp_path)
    doms = main.read_domains()
    assert doms == [
        {"domain": "example.com", "dev_base": "dev.example.com"},
        {"domain": "example.org", "dev_base": "dev.example.org"},
    ]


def test_read_domains_empty_when_missing(tmp_path):
    (tmp_path / "registry").mkdir()
    main = _load_main_with_root(tmp_path)
    assert main.read_domains() == []


def test_read_exposures_domain_column(tmp_path):
    reg = tmp_path / "registry"
    reg.mkdir()
    (reg / "exposures.tsv").write_text(
        "old\told.example.com\tprod\t8011\n"                    # legacy 4-col row
        "new\tnew.example.org\tprod\t8012\texample.org\n"       # 5-col row
    )
    main = _load_main_with_root(tmp_path)
    exp = main.read_exposures()
    assert exp["old"]["domain"] == ""
    assert exp["new"]["domain"] == "example.org"


def _control_client(main):
    from starlette.testclient import TestClient
    main.app.dependency_overrides[main.require_control] = lambda: None
    return TestClient(main.app)


def test_expose_passes_domain_argv_only_when_present(tmp_path, monkeypatch):
    main = _load_main_with_root(tmp_path)
    calls = []

    class _Out:
        def __aiter__(self):
            return self
        async def __anext__(self):
            raise StopAsyncIteration

    class _Proc:
        stdout = _Out()
        async def wait(self):
            return 0

    async def fake_exec(*argv, **kw):
        calls.append(argv)
        return _Proc()

    monkeypatch.setattr(main.asyncio, "create_subprocess_exec", fake_exec)
    client = _control_client(main)
    try:
        r = client.post("/expose", json={"name": "smoke", "zone": "prod", "domain": "example.org"})
        assert r.status_code == 200
        assert calls[0] == ("sudo", main.EXPOSE, "smoke", "prod", "example.org")
        calls.clear()
        r = client.post("/expose", json={"name": "smoke", "zone": "dev"})
        assert r.status_code == 200
        assert calls[0] == ("sudo", main.EXPOSE, "smoke", "dev")
    finally:
        main.app.dependency_overrides.clear()
