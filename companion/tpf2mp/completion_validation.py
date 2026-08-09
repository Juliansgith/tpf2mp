from __future__ import annotations

import re
from typing import Any, Mapping

from .protocol import MAX_PROPOSAL_OUTPUTS, ProtocolError, checksum


def proposal_completion_result_view(payload: Mapping[str, Any]) -> dict[str, Any]:
    return {
        field: payload[field]
        for field in (
            "proposalId", "commitSeq", "proposalDigest", "success", "outputs", "coreDigest",
        )
    }


def operation_completion_result_view(payload: Mapping[str, Any]) -> dict[str, Any]:
    return {
        field: payload[field]
        for field in (
            "operationId", "commitSeq", "operationDigest", "success", "outputs",
            "postcondition", "coreDigest",
        )
    }


def proposal_completion_result_digest(payload: Mapping[str, Any]) -> str:
    return checksum(proposal_completion_result_view(payload))


def operation_completion_result_digest(payload: Mapping[str, Any]) -> str:
    return checksum(operation_completion_result_view(payload))


def proposal_completion_payload(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise ProtocolError("proposal completion payload must be an object")
    allowed = {
        "proposalId", "commitSeq", "proposalDigest", "success", "outputs",
        "financeDelta", "coreDigest", "resultDigest", "errorCode",
    }
    if set(payload) - allowed:
        raise ProtocolError("proposal completion has unknown fields")
    required = allowed - {"errorCode", "financeDelta"}
    if not required <= set(payload):
        raise ProtocolError("proposal completion has missing fields")
    commit_seq = payload.get("commitSeq")
    if not isinstance(commit_seq, int) or isinstance(commit_seq, bool) or commit_seq < 1:
        raise ProtocolError("proposal completion commitSeq must be positive")
    if not isinstance(payload.get("proposalId"), str) or not payload["proposalId"]:
        raise ProtocolError("proposal completion has no proposalId")
    if not isinstance(payload.get("success"), bool):
        raise ProtocolError("proposal completion success must be boolean")
    for field in ("proposalDigest", "coreDigest", "resultDigest"):
        value = payload.get(field)
        if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{8}", value) is None:
            raise ProtocolError(f"proposal completion {field} is not a canonical digest")
    outputs = payload.get("outputs")
    lua_empty_outputs = isinstance(outputs, dict) and not outputs
    if (
        (not isinstance(outputs, list) and not lua_empty_outputs)
        or len(outputs) > MAX_PROPOSAL_OUTPUTS
    ):
        raise ProtocolError("proposal completion outputs are invalid")
    for output in [] if lua_empty_outputs else outputs:
        if not isinstance(output, dict) or set(output) != {"kind", "cid", "slot"}:
            raise ProtocolError("proposal completion output is malformed")
        if output["kind"] not in {
            "node", "edge", "edge_object", "construction", "station",
            "station_group", "depot", "asset",
        }:
            raise ProtocolError("proposal completion output kind is unsupported")
        if not isinstance(output["cid"], str) or not output["cid"].startswith(
            output["kind"] + ":"
        ):
            raise ProtocolError("proposal completion output has a non-canonical id")
        if not isinstance(output["slot"], str) or not output["slot"].startswith(
            output["kind"] + ":"
        ):
            raise ProtocolError("proposal completion output has an invalid slot")
    if "errorCode" in payload and not isinstance(payload["errorCode"], str):
        raise ProtocolError("proposal completion errorCode must be a string")
    if payload["success"]:
        finance_delta = payload.get("financeDelta")
        if not isinstance(finance_delta, int) or isinstance(finance_delta, bool):
            raise ProtocolError("successful proposal completion requires integer financeDelta")
    if payload["resultDigest"] != proposal_completion_result_digest(payload):
        raise ProtocolError("proposal completion resultDigest does not match its physical result")
    return dict(payload)


def operation_completion_payload(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise ProtocolError("operation completion payload must be an object")
    allowed = {
        "operationId", "commitSeq", "operationDigest", "success", "outputs",
        "postcondition", "financeDelta", "coreDigest", "resultDigest", "errorCode",
    }
    if set(payload) - allowed:
        raise ProtocolError("operation completion has unknown fields")
    required = allowed - {"errorCode", "financeDelta"}
    if not required <= set(payload):
        raise ProtocolError("operation completion has missing fields")
    commit_seq = payload.get("commitSeq")
    if not isinstance(commit_seq, int) or isinstance(commit_seq, bool) or commit_seq < 1:
        raise ProtocolError("operation completion commitSeq must be positive")
    if not isinstance(payload.get("operationId"), str) or not payload["operationId"]:
        raise ProtocolError("operation completion has no operationId")
    if not isinstance(payload.get("success"), bool):
        raise ProtocolError("operation completion success must be boolean")
    for field in ("operationDigest", "coreDigest", "resultDigest"):
        value = payload.get(field)
        if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{8}", value) is None:
            raise ProtocolError(f"operation completion {field} is not a canonical digest")
    outputs = payload.get("outputs")
    lua_empty_outputs = isinstance(outputs, dict) and not outputs
    if (not isinstance(outputs, list) and not lua_empty_outputs) or len(outputs) > 1:
        raise ProtocolError("operation completion outputs are invalid")
    for output in [] if lua_empty_outputs else outputs:
        if not isinstance(output, dict) or set(output) != {"kind", "cid", "slot"}:
            raise ProtocolError("operation completion output is malformed")
        if output["kind"] not in {"line", "vehicle"}:
            raise ProtocolError("operation completion output kind is unsupported")
        if not isinstance(output["cid"], str) or not output["cid"].startswith(
            output["kind"] + ":"
        ):
            raise ProtocolError("operation completion output has a non-canonical id")
        if output["slot"] != output["kind"] + ":1":
            raise ProtocolError("operation completion output has an invalid slot")
    if not isinstance(payload.get("postcondition"), dict):
        raise ProtocolError("operation completion postcondition must be an object")
    if "errorCode" in payload and not isinstance(payload["errorCode"], str):
        raise ProtocolError("operation completion errorCode must be a string")
    if payload["success"]:
        finance_delta = payload.get("financeDelta")
        if not isinstance(finance_delta, int) or isinstance(finance_delta, bool):
            raise ProtocolError("successful operation completion requires integer financeDelta")
    if payload["resultDigest"] != operation_completion_result_digest(payload):
        raise ProtocolError("operation completion resultDigest does not match its physical result")
    return dict(payload)
