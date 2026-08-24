from __future__ import annotations

import base64
import json
import os
import re
import ssl
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from . import __version__
from .bridge import atomic_write
from .session_identity import validate_session_id


INVITE_PREFIX = "TPF2MP1."
RELAY_SESSION = re.compile(r"mp-[0-9a-f]{16}")
RELAY_TOKEN = re.compile(r"[A-Za-z0-9_-]{40,96}")


class RelayApiError(RuntimeError):
    pass


@dataclass(frozen=True)
class RelayCredentials:
    relay_url: str
    session_id: str
    role: str
    token: str


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req: Any, fp: Any, code: int, msg: str,
                         headers: Any, newurl: str) -> None:
        return None


def validate_relay_url(value: Any, *, allow_insecure_loopback: bool = False) -> str:
    if not isinstance(value, str) or not value or len(value) > 2048:
        raise RelayApiError("relay URL is missing or too long")
    try:
        parsed = urllib.parse.urlsplit(value.rstrip("/"))
    except ValueError as exc:
        raise RelayApiError("relay URL is malformed") from exc
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise RelayApiError("relay URL must not contain credentials, a query, or a fragment")
    if not parsed.hostname or parsed.scheme not in {"https", "http"}:
        raise RelayApiError("relay URL must be an absolute HTTPS URL")
    loopback = parsed.hostname.lower() in {"localhost", "127.0.0.1", "::1"}
    if parsed.scheme != "https" and not (allow_insecure_loopback and loopback):
        raise RelayApiError("relay URL must use HTTPS outside an explicit loopback test")
    if parsed.path not in {"", "/"} and ".." in parsed.path.split("/"):
        raise RelayApiError("relay URL path is unsafe")
    return urllib.parse.urlunsplit((
        parsed.scheme,
        parsed.netloc,
        parsed.path.rstrip("/"),
        "",
        "",
    ))


def websocket_url(base_url: str, session_id: str, channel: str) -> str:
    base = validate_relay_url(
        base_url,
        allow_insecure_loopback=os.environ.get("TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK") == "1",
    )
    session = validate_relay_session(session_id)
    if channel not in {"gameplay", "save"}:
        raise RelayApiError("relay channel is invalid")
    parsed = urllib.parse.urlsplit(base)
    scheme = "wss" if parsed.scheme == "https" else "ws"
    path = parsed.path.rstrip("/") + f"/v1/tunnel/{session}/{channel}"
    return urllib.parse.urlunsplit((scheme, parsed.netloc, path, "", ""))


def validate_relay_session(value: Any) -> str:
    if not isinstance(value, str) or RELAY_SESSION.fullmatch(value) is None:
        raise RelayApiError("relay session id is malformed")
    return validate_session_id(value, "relay session")


def validate_relay_token(value: Any) -> str:
    if not isinstance(value, str) or RELAY_TOKEN.fullmatch(value) is None:
        raise RelayApiError("relay credential is malformed")
    return value


def decode_invite(value: Any) -> tuple[str, str]:
    if not isinstance(value, str) or not value.startswith(INVITE_PREFIX):
        raise RelayApiError("join code has an unsupported format")
    encoded = value[len(INVITE_PREFIX):]
    if not 32 <= len(encoded) <= 256 or re.fullmatch(r"[A-Za-z0-9_-]+", encoded) is None:
        raise RelayApiError("join code is malformed")
    try:
        payload = json.loads(base64.urlsafe_b64decode(
            encoded + "=" * (-len(encoded) % 4)
        ).decode("ascii"))
    except (ValueError, UnicodeError, json.JSONDecodeError) as exc:
        raise RelayApiError("join code is malformed") from exc
    if not isinstance(payload, dict) or set(payload) != {"s", "t"}:
        raise RelayApiError("join code payload is malformed")
    return validate_relay_session(payload["s"]), validate_relay_token(payload["t"])


def _request_json(
    method: str,
    url: str,
    *,
    token: str | None = None,
    access_token: str | None = None,
    payload: Mapping[str, Any] | None = None,
    timeout: float = 15.0,
) -> dict[str, Any]:
    body = None if payload is None else json.dumps(
        payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    headers = {
        "Accept": "application/json",
        "User-Agent": f"TPF2MP/{__version__}",
    }
    if body is not None:
        headers["Content-Type"] = "application/json"
    if token is not None:
        headers["Authorization"] = "Bearer " + validate_relay_token(token)
    if access_token:
        if any(character in access_token for character in "\r\n"):
            raise RelayApiError("relay access credential is malformed")
        headers["X-TPF2MP-Relay-Access"] = access_token
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    opener = urllib.request.build_opener(
        _NoRedirect(), urllib.request.HTTPSHandler(context=ssl.create_default_context())
    )
    try:
        with opener.open(request, timeout=max(1.0, min(float(timeout), 120.0))) as response:
            raw = response.read(1024 * 1024 + 1)
            if len(raw) > 1024 * 1024:
                raise RelayApiError("relay response exceeded 1 MiB")
            value = json.loads(raw.decode("utf-8"))
    except urllib.error.HTTPError as exc:
        try:
            value = json.loads(exc.read(16 * 1024).decode("utf-8"))
            detail = str(value.get("error", "request rejected"))[:300]
        except Exception:
            detail = "request rejected"
        raise RelayApiError(f"relay returned HTTP {exc.code}: {detail}") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise RelayApiError(f"relay connection failed: {exc.reason if hasattr(exc, 'reason') else exc}") from exc
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RelayApiError("relay returned invalid JSON") from exc
    if not isinstance(value, dict):
        raise RelayApiError("relay returned a non-object response")
    return value


def create_session(
    relay_url: str,
    *,
    display_name: str = "TPF2MP match",
    access_token: str | None = None,
    allow_insecure_loopback: bool = False,
) -> dict[str, Any]:
    base = validate_relay_url(
        relay_url, allow_insecure_loopback=allow_insecure_loopback
    )
    value = _request_json(
        "POST",
        base + "/v1/sessions",
        access_token=access_token,
        payload={"clientVersion": __version__, "displayName": display_name[:64]},
    )
    if value.get("schemaVersion") != 1:
        raise RelayApiError("relay session response has an unsupported schema")
    session_id = validate_relay_session(value.get("sessionId"))
    host_token = validate_relay_token(value.get("hostToken"))
    invite_session, _ = decode_invite(value.get("joinCode"))
    if invite_session != session_id:
        raise RelayApiError("relay join code names another session")
    returned_url = validate_relay_url(
        value.get("relayUrl"), allow_insecure_loopback=allow_insecure_loopback
    )
    if returned_url != base:
        raise RelayApiError("relay response changed the configured relay URL")
    return {
        "schemaVersion": 1,
        "relayUrl": base,
        "sessionId": session_id,
        "supportId": session_id,
        "hostToken": host_token,
        "joinCode": str(value["joinCode"]),
        "expiresAt": str(value.get("expiresAt", ""))[:64],
    }


def write_credentials(path: Path | str, credentials: RelayCredentials) -> Path:
    destination = Path(path).expanduser().resolve()
    value = {
        "schemaVersion": 1,
        "relayUrl": validate_relay_url(
            credentials.relay_url,
            allow_insecure_loopback=os.environ.get("TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK") == "1",
        ),
        "sessionId": validate_relay_session(credentials.session_id),
        "role": credentials.role,
        "token": validate_relay_token(credentials.token),
    }
    if credentials.role not in {"host", "join"}:
        raise RelayApiError("relay credential role is invalid")
    atomic_write(
        destination,
        (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8"),
        durable=True,
    )
    try:
        os.chmod(destination, 0o600)
    except OSError:
        pass
    return destination


def read_credentials(path: Path | str) -> RelayCredentials:
    source = Path(path).expanduser().resolve()
    try:
        value = json.loads(source.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise RelayApiError("relay credential file is unreadable") from exc
    if not isinstance(value, dict) or set(value) != {
        "schemaVersion", "relayUrl", "sessionId", "role", "token"
    } or value.get("schemaVersion") != 1:
        raise RelayApiError("relay credential file has an invalid schema")
    role = value.get("role")
    if role not in {"host", "join"}:
        raise RelayApiError("relay credential file has an invalid role")
    return RelayCredentials(
        validate_relay_url(
            value["relayUrl"],
            allow_insecure_loopback=os.environ.get("TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK") == "1",
        ),
        validate_relay_session(value["sessionId"]),
        str(role),
        validate_relay_token(value["token"]),
    )


def upload_diagnostics(
    credentials: RelayCredentials,
    events: list[Mapping[str, Any]],
    *,
    timeout: float = 15.0,
) -> int:
    if not 1 <= len(events) <= 256:
        raise RelayApiError("diagnostic batch must contain 1-256 events")
    value = _request_json(
        "POST",
        credentials.relay_url
        + f"/v1/sessions/{credentials.session_id}/diagnostics",
        token=credentials.token,
        payload={"schemaVersion": 1, "events": events},
        timeout=timeout,
    )
    accepted = value.get("accepted")
    if not isinstance(accepted, int) or isinstance(accepted, bool) \
            or not 0 <= accepted <= len(events):
        raise RelayApiError("relay returned an invalid diagnostic receipt")
    return accepted


def close_session(credentials: RelayCredentials, *, timeout: float = 15.0) -> bool:
    if credentials.role != "host":
        raise RelayApiError("only host relay credentials may close a session")
    value = _request_json(
        "DELETE",
        credentials.relay_url + f"/v1/sessions/{credentials.session_id}",
        token=credentials.token,
        timeout=timeout,
    )
    if value.get("sessionId") != credentials.session_id or value.get("closed") is not True:
        raise RelayApiError("relay returned an invalid close receipt")
    return True
