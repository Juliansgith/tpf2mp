from __future__ import annotations

import math
import re
from typing import Any

from .protocol import ProtocolError, _lua_array, canonical_json, checksum

SCHEMA_VERSION = 1
MAX_INDUSTRIES = 2_048
MAX_RECIPE_ITEMS = 32
MAX_AMOUNT = 1_000_000_000
MAX_BOOTSTRAP_BYTES = 2 * 1024 * 1024

_DIGEST = re.compile(r"[0-9a-f]{8}")
_RESOURCE = re.compile(r"[A-Za-z0-9_./-]+\.con")
_CARGO = re.compile(r"[A-Z][A-Z0-9_]{0,127}")


def _parameter(value: Any, depth: int, budget: list[int]) -> None:
    if value is None or isinstance(value, (str, bool, int)):
        return
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ProtocolError("freight industry parameter is non-finite")
        return
    if not isinstance(value, (dict, list)) or depth <= 0:
        raise ProtocolError("freight industry parameter is opaque or too deep")
    budget[0] += len(value)
    if len(value) > 128 or budget[0] > 512:
        raise ProtocolError("freight industry parameter exceeds its size limit")
    iterator = value.values() if isinstance(value, dict) else value
    for nested in iterator:
        _parameter(nested, depth - 1, budget)


def _industry(value: Any, previous_cid: str | None, seen_cids: set[str]) -> str:
    expected = {
        "cid", "resource", "params", "recipeDigest", "capacity",
        "stocks", "inputs", "outputs",
    }
    if not isinstance(value, dict) or set(value) != expected:
        raise ProtocolError("freight industry record is malformed")
    cid, resource = value.get("cid"), value.get("resource")
    if not isinstance(cid, str) or not cid.startswith("industry:") or len(cid) > 320 \
            or cid in seen_cids or (previous_cid is not None and cid <= previous_cid):
        raise ProtocolError("freight industry id is invalid, duplicated, or unordered")
    if not isinstance(resource, str) or len(resource) > 320 \
            or not _RESOURCE.fullmatch(resource) or ".." in resource:
        raise ProtocolError("freight industry resource is invalid")
    seen_cids.add(cid)

    capacity, recipe_digest = value.get("capacity"), value.get("recipeDigest")
    if isinstance(capacity, bool) or not isinstance(capacity, int) \
            or not 0 <= capacity <= MAX_AMOUNT \
            or not isinstance(recipe_digest, str) or not _DIGEST.fullmatch(recipe_digest):
        raise ProtocolError("freight industry capacity or recipe digest is invalid")
    _parameter(value["params"], 6, [0])

    stocks = _lua_array(value.get("stocks"), empty=True)
    inputs = _lua_array(value.get("inputs"), empty=True)
    outputs = _lua_array(value.get("outputs"), empty=True)
    if len(stocks) > MAX_RECIPE_ITEMS or not 1 <= len(inputs) <= MAX_RECIPE_ITEMS \
            or len(outputs) > MAX_RECIPE_ITEMS:
        raise ProtocolError("freight industry recipe exceeds its item limits")
    cargo_by_stock: dict[int, str] = {}
    for index, stock in enumerate(stocks):
        if not isinstance(stock, dict) or set(stock) != {
            "index", "cargoType", "stockType", "moreCapacity",
        } or stock.get("index") != index:
            raise ProtocolError("freight industry stock is malformed")
        cargo_type, stock_type, more_capacity = (
            stock.get("cargoType"), stock.get("stockType"), stock.get("moreCapacity")
        )
        if not isinstance(cargo_type, str) or not _CARGO.fullmatch(cargo_type) \
                or not isinstance(stock_type, str) or len(stock_type) > 128 \
                or isinstance(more_capacity, bool) or not isinstance(more_capacity, int) \
                or not 0 <= more_capacity <= MAX_AMOUNT:
            raise ProtocolError("freight industry stock metadata is invalid")
        cargo_by_stock[index] = cargo_type

    has_input = False
    for alternative_value in inputs:
        alternative = _lua_array(alternative_value, empty=True)
        if len(alternative) > MAX_RECIPE_ITEMS:
            raise ProtocolError("freight input alternative is too large")
        previous_stock = -1
        for requirement in alternative:
            if not isinstance(requirement, dict) or set(requirement) != {
                "stockIndex", "cargoType", "amount",
            }:
                raise ProtocolError("freight input requirement is malformed")
            stock_index, cargo_type, amount = (
                requirement.get("stockIndex"), requirement.get("cargoType"),
                requirement.get("amount"),
            )
            if isinstance(stock_index, bool) or not isinstance(stock_index, int) \
                    or stock_index <= previous_stock or cargo_by_stock.get(stock_index) != cargo_type \
                    or isinstance(amount, bool) or not isinstance(amount, int) \
                    or not 1 <= amount <= MAX_AMOUNT:
                raise ProtocolError("freight input requirement is invalid or unordered")
            previous_stock = stock_index
            has_input = True

    previous_cargo = ""
    for output in outputs:
        if not isinstance(output, dict) or set(output) != {"cargoType", "amount"}:
            raise ProtocolError("freight output is malformed")
        cargo_type, amount = output.get("cargoType"), output.get("amount")
        if not isinstance(cargo_type, str) or not _CARGO.fullmatch(cargo_type) \
                or cargo_type <= previous_cargo \
                or isinstance(amount, bool) or not isinstance(amount, int) \
                or not 1 <= amount <= MAX_AMOUNT:
            raise ProtocolError("freight output is invalid or unordered")
        previous_cargo = cargo_type
    if not outputs and not has_input:
        raise ProtocolError("freight industry has no positive flow")

    recipe_view = {
        "resource": resource, "params": value["params"],
        "stocks": value["stocks"], "inputs": value["inputs"],
        "outputs": value["outputs"], "capacity": capacity,
    }
    if checksum(recipe_view) != recipe_digest:
        raise ProtocolError("freight industry recipe digest mismatch")
    return cid


def validate_industry_bootstrap(action: dict[str, Any]) -> None:
    expected = {
        "type", "schemaVersion", "contentDigest", "economyEpoch",
        "industries", "digest",
    }
    if set(action) != expected or action.get("schemaVersion") != SCHEMA_VERSION:
        raise ProtocolError("freight industry bootstrap header is invalid")
    content_digest, bootstrap_digest = action.get("contentDigest"), action.get("digest")
    if not isinstance(content_digest, str) or not _DIGEST.fullmatch(content_digest) \
            or not isinstance(bootstrap_digest, str) or not _DIGEST.fullmatch(bootstrap_digest):
        raise ProtocolError("freight industry bootstrap digest is invalid")
    economy_epoch = action.get("economyEpoch")
    if isinstance(economy_epoch, bool) or not isinstance(economy_epoch, int) \
            or not 0 <= economy_epoch <= MAX_AMOUNT:
        raise ProtocolError("freight industry bootstrap economy epoch is invalid")
    industries = _lua_array(action.get("industries"), empty=True)
    if len(industries) > MAX_INDUSTRIES:
        raise ProtocolError("freight industry bootstrap contains too many industries")
    previous_cid: str | None = None
    seen_cids: set[str] = set()
    for industry in industries:
        previous_cid = _industry(industry, previous_cid, seen_cids)
    bootstrap_view = {
        "schemaVersion": SCHEMA_VERSION, "contentDigest": content_digest,
        "economyEpoch": economy_epoch, "industries": action["industries"],
    }
    if checksum(bootstrap_view) != bootstrap_digest:
        raise ProtocolError("freight industry bootstrap digest mismatch")
    if len(canonical_json(action).encode("utf-8")) > MAX_BOOTSTRAP_BYTES:
        raise ProtocolError("freight industry bootstrap exceeds 2 MiB")
