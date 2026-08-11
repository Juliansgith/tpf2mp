"""Strict versioned schema for receipt-bound restore plans."""

from __future__ import annotations

from typing import Any, Mapping

from .protocol import (
    PROTOCOL_VERSION, ProtocolError, validate_vehicle_phase_proof, verify,
)
from .session_identity import derive_resume_session, validate_session_id

RESTORE_PLAN_VERSION = 6
# Version 5 bound the native route phase but omitted the companion station
# round cursor. A resumed active vehicle would therefore report N+1 to a host
# reset to zero. It is deliberately retired rather than guessed at restore.
RETIRED_CURSORLESS_RESTORE_PLAN_VERSION = 5
# Version 4 bound load-bearing save bytes and match policy, but not the
# machine-local native vehicle phase. It is intentionally not accepted: a
# structurally identical pair can otherwise resume on opposite route legs.
RETIRED_UNPHASED_RESTORE_PLAN_VERSION = 4
PROFILE_RESTORE_PLAN_VERSION = 3
LEGACY_RESTORE_PLAN_VERSION = 2
MATCH_PROFILE_AGENT_MODES = {"skeleton", "vanilla", "empty"}


def validate_match_profile(value: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(value, Mapping) or set(value) != {
        "schemaVersion", "agentMode", "townDevelopment",
    }:
        raise ProtocolError("restore plan match-content profile is malformed")
    profile_version = value.get("schemaVersion")
    if not isinstance(profile_version, int) or isinstance(profile_version, bool) \
            or profile_version != 1:
        raise ProtocolError("restore plan match-content profile version is invalid")
    agent_mode = value.get("agentMode")
    if agent_mode not in MATCH_PROFILE_AGENT_MODES:
        raise ProtocolError("restore plan match-content agent mode is invalid")
    if not isinstance(value.get("townDevelopment"), bool):
        raise ProtocolError("restore plan match-content town-development flag is invalid")
    return {
        "schemaVersion": 1,
        "agentMode": agent_mode,
        "townDevelopment": value["townDevelopment"],
    }


def _valid_sha256(value: Any) -> bool:
    return isinstance(value, str) and len(value) == 64 \
        and not any(character not in "0123456789abcdef" for character in value)


def verify_restore_plan(value: Mapping[str, Any]) -> dict[str, Any]:
    plan = verify(value)
    version = plan.get("version")
    if not isinstance(version, int) or isinstance(version, bool) \
            or plan.get("format") != "tpf2mp-restore-plan" \
            or version not in {
                LEGACY_RESTORE_PLAN_VERSION, PROFILE_RESTORE_PLAN_VERSION,
                RESTORE_PLAN_VERSION,
            }:
        raise ProtocolError("unsupported restore plan format")
    protocol = plan.get("protocol")
    if not isinstance(protocol, int) or isinstance(protocol, bool) \
            or protocol != PROTOCOL_VERSION:
        raise ProtocolError("restore plan protocol mismatch")
    allowed = {
        "format", "version", "protocol", "session", "resumeSession",
        "generatedAtUtc", "boundarySeq", "convergenceKey", "coreDigest",
        "requiredPeers", "peerSaves", "steps", "checksum",
    }
    if version in {PROFILE_RESTORE_PLAN_VERSION, RESTORE_PLAN_VERSION}:
        allowed.add("matchContentProfile")
    if version == RESTORE_PLAN_VERSION:
        allowed.add("vehiclePhaseProof")
    if set(plan) != allowed:
        raise ProtocolError("restore plan has unknown or missing fields")
    if version in {PROFILE_RESTORE_PLAN_VERSION, RESTORE_PLAN_VERSION}:
        plan["matchContentProfile"] = validate_match_profile(
            plan.get("matchContentProfile")
        )
    if version == RESTORE_PLAN_VERSION:
        plan["vehiclePhaseProof"] = validate_vehicle_phase_proof(
            plan.get("vehiclePhaseProof")
        )
    session = plan.get("session")
    boundary = plan.get("boundarySeq")
    try:
        session = validate_session_id(session, "restore plan session")
    except ProtocolError as exc:
        raise ProtocolError("restore plan session is invalid") from exc
    if not isinstance(boundary, int) or isinstance(boundary, bool) \
            or not 1 <= boundary <= 9_007_199_254_740_991:
        raise ProtocolError("restore plan boundary is invalid")
    expected_resume = (
        derive_resume_session(session, boundary)
        if version == RESTORE_PLAN_VERSION else f"{session}-r{boundary}"
    )
    try:
        resume_session = validate_session_id(
            plan.get("resumeSession"), "restore plan resume session"
        )
    except ProtocolError as exc:
        raise ProtocolError("restore plan resume session is invalid") from exc
    if resume_session != expected_resume:
        raise ProtocolError("restore plan resume session does not match its boundary")
    for field in ("convergenceKey", "coreDigest"):
        item = plan.get(field)
        if not isinstance(item, str) or not item or len(item) > 128:
            raise ProtocolError(f"restore plan {field} is invalid")
    if not isinstance(plan.get("generatedAtUtc"), str) or not plan["generatedAtUtc"]:
        raise ProtocolError("restore plan generation timestamp is invalid")
    if not isinstance(plan.get("steps"), list) or not plan["steps"] \
            or any(not isinstance(step, str) or not step for step in plan["steps"]):
        raise ProtocolError("restore plan steps are invalid")

    peers = plan.get("requiredPeers")
    saves = plan.get("peerSaves")
    if not isinstance(peers, list) or not peers \
            or any(not isinstance(peer, str) or not peer for peer in peers):
        raise ProtocolError("restore plan has no required peers")
    if len(set(peers)) != len(peers):
        raise ProtocolError("restore plan required peer roster contains duplicates")
    if not isinstance(saves, Mapping) or set(saves) != set(peers):
        raise ProtocolError("restore plan is missing a peer save attestation")
    expected_fields = {
        "saveSha256", "savedAtUnix", "receiptCommitSeq", "boundarySeq",
        "coreDigest", "convergenceKey",
    }
    if version == RESTORE_PLAN_VERSION:
        expected_fields.add("metadataSha256")
    for peer in peers:
        save = saves[peer]
        if not isinstance(save, Mapping) or set(save) != expected_fields:
            raise ProtocolError(f"restore plan {peer} save attestation is malformed")
        if not _valid_sha256(save.get("saveSha256")):
            raise ProtocolError(f"restore plan {peer} save hash is invalid")
        if version == RESTORE_PLAN_VERSION \
                and not _valid_sha256(save.get("metadataSha256")):
            raise ProtocolError(f"restore plan {peer} metadata hash is invalid")
        for field, minimum in (("savedAtUnix", 0), ("receiptCommitSeq", 1)):
            item = save.get(field)
            if not isinstance(item, int) or isinstance(item, bool) \
                    or not minimum <= item <= 9_007_199_254_740_991:
                raise ProtocolError(f"restore plan {peer} {field} is invalid")
        if save.get("boundarySeq") != boundary \
                or save.get("coreDigest") != plan["coreDigest"] \
                or save.get("convergenceKey") != plan["convergenceKey"]:
            raise ProtocolError(f"restore plan {peer} save names a different boundary")
    return plan
