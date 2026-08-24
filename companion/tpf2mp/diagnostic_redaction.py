from __future__ import annotations

import ipaddress
import re
from typing import Any, Mapping


SECRET_KEYS = re.compile(
    r"authorization|cookie|credential|invite|password|secret|token|"
    r"api[_-]?key|private[_-]?key",
    re.IGNORECASE,
)
WINDOWS_USER_PATH = re.compile(
    r"(?i)\b[A-Z]:\\Users\\[^\\\s\"']+(?:\\[^\r\n\"']*)?"
)
UNIX_HOME_PATH = re.compile(
    r"(?<![A-Za-z0-9_.-])/(?:home|Users)/[^/\s]+(?:/[^\s\"']*)?"
)
IPV4 = re.compile(
    r"(?<![0-9])(?:25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})"
    r"(?:\.(?:25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})){3}(?![0-9])"
)
IPV6_CANDIDATE = re.compile(
    r"(?<![0-9A-Fa-f:])\[?[0-9A-Fa-f:]*:[0-9A-Fa-f:]+\]?(?![0-9A-Fa-f:])"
)
BEARER = re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~-]+")
INVITE = re.compile(r"\bTPF2MP1\.[A-Za-z0-9_-]+")


def _redact_ipv6(match: re.Match[str]) -> str:
    candidate = match.group(0)
    unwrapped = candidate[1:-1] if candidate.startswith("[") \
        and candidate.endswith("]") else candidate
    try:
        address = ipaddress.ip_address(unwrapped)
    except ValueError:
        return candidate
    return "[REDACTED-IP]" if address.version == 6 else candidate


def redact_text(value: str, maximum: int = 4096) -> str:
    value = value.replace("\x00", "")[:maximum]
    value = BEARER.sub("Bearer [REDACTED]", value)
    value = INVITE.sub("[REDACTED-INVITE]", value)
    value = WINDOWS_USER_PATH.sub("[REDACTED-LOCAL-PATH]", value)
    value = UNIX_HOME_PATH.sub("[REDACTED-LOCAL-PATH]", value)
    value = IPV4.sub("[REDACTED-IP]", value)
    return IPV6_CANDIDATE.sub(_redact_ipv6, value)


def redact(value: Any, *, depth: int = 0) -> Any:
    if depth > 8:
        return "[TRUNCATED-DEPTH]"
    if value is None or isinstance(value, (bool, int, float)):
        return value
    if isinstance(value, str):
        return redact_text(value)
    if isinstance(value, list):
        return [redact(item, depth=depth + 1) for item in value[:64]]
    if isinstance(value, Mapping):
        result: dict[str, Any] = {}
        for index, (key, item) in enumerate(value.items()):
            if index >= 64:
                result["_truncated"] = True
                break
            safe_key = redact_text(str(key), maximum=128)
            result[safe_key] = (
                "[REDACTED]" if SECRET_KEYS.search(safe_key)
                else redact(item, depth=depth + 1)
            )
        return result
    return redact_text(repr(value), maximum=512)
