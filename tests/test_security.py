"""Security and functional tests for the API."""
import json
import pytest
from werkzeug.security import check_password_hash
from app import db
from app.models import User


BASE = "/api/v1"

VALID_USER = {
    "username": "testuser",
    "email": "test@example.com",
    "password": "Str0ng!Pass#2024",
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def post_user(client, payload=None):
    payload = payload or VALID_USER
    return client.post(
        f"{BASE}/users",
        data=json.dumps(payload),
        content_type="application/json",
    )


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

def test_health_returns_200(client):
    resp = client.get(f"{BASE}/health")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "healthy"


# ---------------------------------------------------------------------------
# User creation — happy path
# ---------------------------------------------------------------------------

def test_create_user_success(client):
    resp = post_user(client)
    assert resp.status_code == 201
    data = resp.get_json()
    assert data["username"] == VALID_USER["username"]
    assert data["email"] == VALID_USER["email"]


def test_create_user_response_omits_password_hash(client):
    resp = post_user(client)
    data = resp.get_json()
    assert "password" not in data
    assert "password_hash" not in data


def test_password_stored_as_hash(client, app):
    post_user(client)
    with app.app_context():
        user = User.query.filter_by(email=VALID_USER["email"]).first()
        assert user is not None
        assert user.password_hash != VALID_USER["password"]
        assert check_password_hash(user.password_hash, VALID_USER["password"])


# ---------------------------------------------------------------------------
# Duplicate detection
# ---------------------------------------------------------------------------

def test_duplicate_email_returns_409(client):
    post_user(client)
    resp = post_user(client)
    assert resp.status_code == 409


def test_duplicate_username_different_email(client):
    post_user(client)
    payload = {**VALID_USER, "email": "other@example.com"}
    resp = post_user(client, payload)
    # username uniqueness depends on DB constraint — at minimum no 500
    assert resp.status_code in (201, 409)


# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("password", [
    "short1!A",       # < 12 chars
    "tooshort",
    "12345678901",    # 11 chars
])
def test_short_password_rejected(client, password):
    payload = {**VALID_USER, "password": password}
    resp = post_user(client, payload)
    assert resp.status_code == 400


@pytest.mark.parametrize("email", [
    "notanemail",
    "missing@",
    "@nodomain.com",
    "spaces in@email.com",
])
def test_invalid_email_rejected(client, email):
    payload = {**VALID_USER, "email": email}
    resp = post_user(client, payload)
    assert resp.status_code == 400


@pytest.mark.parametrize("username", [
    "ab",             # too short (< 3)
    "",
    "a" * 81,         # too long (> 80)
])
def test_invalid_username_rejected(client, username):
    payload = {**VALID_USER, "username": username}
    resp = post_user(client, payload)
    assert resp.status_code == 400


def test_missing_required_fields_returns_400(client):
    resp = client.post(
        f"{BASE}/users",
        data=json.dumps({}),
        content_type="application/json",
    )
    assert resp.status_code == 400


def test_non_json_body_returns_400(client):
    resp = client.post(
        f"{BASE}/users",
        data="not-json",
        content_type="text/plain",
    )
    assert resp.status_code in (400, 415)


# ---------------------------------------------------------------------------
# Injection & XSS
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("payload_override,field", [
    ({"username": "' OR '1'='1"}, "username"),
    ({"username": "admin'; DROP TABLE users;--"}, "username"),
    ({"email": "x' OR '1'='1'@x.com"}, "email"),
])
def test_sql_injection_payload_does_not_crash(client, payload_override, field):
    """Injections should return 400 (validation) or 201, never 500."""
    payload = {**VALID_USER, **payload_override}
    resp = post_user(client, payload)
    assert resp.status_code != 500


@pytest.mark.parametrize("xss", [
    "<script>alert(1)</script>",
    "javascript:alert(1)",
    "<img src=x onerror=alert(1)>",
])
def test_xss_payload_does_not_crash(client, xss):
    payload = {**VALID_USER, "username": xss}
    resp = post_user(client, payload)
    assert resp.status_code != 500


# ---------------------------------------------------------------------------
# Error handling — no stack trace leakage
# ---------------------------------------------------------------------------

def test_404_returns_json(client):
    resp = client.get("/api/v1/nonexistent")
    assert resp.content_type == "application/json"
    assert resp.status_code == 404


def test_method_not_allowed_returns_json(client):
    resp = client.delete(f"{BASE}/health")
    assert resp.status_code == 405
    assert resp.content_type == "application/json"


def test_500_response_does_not_expose_traceback(client, monkeypatch):
    from app import routes
    def boom():
        raise RuntimeError("internal error")
    monkeypatch.setattr(routes, "create_user", lambda: boom())
    resp = client.post(
        f"{BASE}/users",
        data=json.dumps(VALID_USER),
        content_type="application/json",
    )
    # Stack trace must not appear in response body
    body = resp.get_data(as_text=True)
    assert "Traceback" not in body
    assert "RuntimeError" not in body
