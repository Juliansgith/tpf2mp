"""Strict legacy/current wire shapes for native-save receipts."""

from __future__ import annotations

from typing import Any, Mapping


def _sha256(value: Any) -> bool:
    return isinstance(value, str) and len(value) == 64 \
        and not any(character not in "0123456789abcdef" for character in value)


def validation_error(action: Mapping[str, Any], maximum: int) -> str | None:
    required = {
        "type", "boundarySeq", "savedAtUnix", "saveSha256",
        "coreDigest", "convergenceKey", "paused",
    }
    if set(action) - (required | {"metadataSha256"}) or required - set(action):
        return "recovery.save_receipt has unknown or missing fields"
    boundary = action["boundarySeq"]
    if not isinstance(boundary, int) or isinstance(boundary, bool) \
            or not 1 <= boundary <= maximum:
        return "recovery.save_receipt boundarySeq is invalid"
    saved_at = action["savedAtUnix"]
    if not isinstance(saved_at, int) or isinstance(saved_at, bool) \
            or not 0 <= saved_at <= maximum:
        return "recovery.save_receipt savedAtUnix is invalid"
    if action["paused"] is not True:
        return "recovery.save_receipt must attest a paused world"
    if not _sha256(action["saveSha256"]):
        return "recovery.save_receipt saveSha256 is not a sha-256 digest"
    metadata_sha = action.get("metadataSha256")
    if metadata_sha is not None and not _sha256(metadata_sha):
        return "recovery.save_receipt metadataSha256 is not a sha-256 digest"
    for field in ("coreDigest", "convergenceKey"):
        value = action[field]
        if not isinstance(value, str) or not value or len(value) > 128:
            return f"recovery.save_receipt {field} is invalid"
    return None
