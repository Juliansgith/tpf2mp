from __future__ import annotations

import copy
import re
from collections.abc import Mapping
from typing import Any

MAX_COUNT = 1_000_000_000
MAX_ACCUMULATOR = 1_000_000_000_000_000


def _add(left: Any, right: Any) -> int:
    return min(MAX_ACCUMULATOR, max(0, int(left or 0)) + max(0, int(right or 0)))


def _identity(row: Mapping[str, Any]) -> tuple[Any, ...]:
    base = (
        row.get("contractDigest"), row.get("sourceIndustryCid"),
        row.get("destinationIndustryCid"), row.get("destinationStockIndex"),
        row.get("cargoType"),
    )
    if row.get("transportSchema") == 2:
        return base + (
            2, row.get("pathDigest"), row.get("legIndex"), row.get("legCount"),
            row.get("sourceKind"), row.get("destinationKind"),
            row.get("sourceStationGroupCid"), row.get("destinationStationGroupCid"),
        )
    return base


def _output_matches(industry: Mapping[str, Any], cargo_type: str) -> bool:
    outputs = industry.get("recipe", {}).get("outputs", [])
    rows = [] if isinstance(outputs, Mapping) and not outputs else outputs
    return isinstance(rows, list) and any(
        isinstance(row, Mapping) and row.get("cargoType") == cargo_type for row in rows
    )


def _input_stock(
    industry: Mapping[str, Any], stock_index: int, cargo_type: str
) -> dict[str, Any] | None:
    stocks = industry.get("inputStock", [])
    rows = [] if isinstance(stocks, Mapping) and not stocks else stocks
    if not isinstance(rows, list):
        return None
    for stock in rows:
        if isinstance(stock, dict) and stock.get("index") == stock_index \
                and stock.get("cargoType") == cargo_type:
            return stock
    return None


def apply_transport(state: dict[str, Any], cargo_lines: Mapping[str, Any]) -> dict[str, Any]:
    from .protocol import ProtocolError

    if state.get("ready") is not True:
        return {"skipped": "not-ready", "lines": 0, "boarded": {}, "delivered": {}}
    if not isinstance(cargo_lines, Mapping):
        raise ProtocolError("freight transport snapshot is malformed")
    industries = state.get("industries")
    if not isinstance(industries, dict):
        raise ProtocolError("freight transport industries are malformed")
    raw_cursors = state.get("transportCursors", {})
    raw_transported = state.get("totalTransported", {})
    raw_delivered = state.get("totalDelivered", {})
    if not isinstance(raw_cursors, Mapping):
        raise ProtocolError("freight transport cursors are malformed")
    if not isinstance(raw_transported, Mapping) or not isinstance(raw_delivered, Mapping):
        raise ProtocolError("freight transport totals are malformed")
    cursors_value = copy.deepcopy(dict(raw_cursors))
    total_transported = copy.deepcopy(dict(raw_transported))
    total_delivered = copy.deepcopy(dict(raw_delivered))
    staged: dict[
        str, tuple[dict[str, Any], dict[str, Any], dict[str, Any], int, int, bool]
    ] = {}
    aggregate: dict[tuple[str, str], int] = {}
    for line_cid in sorted(cargo_lines):
        row = cargo_lines[line_cid]
        if not isinstance(row, Mapping):
            raise ProtocolError("freight transport row is malformed")
        source_cid, destination_cid = row.get("sourceIndustryCid"), row.get("destinationIndustryCid")
        cargo_type, stock_index = row.get("cargoType"), row.get("destinationStockIndex")
        boarded, delivered = row.get("boardedUnits"), row.get("deliveredUnits")
        transport_schema = row.get("transportSchema", 1)
        multihop = transport_schema == 2
        source_kind = row.get("sourceKind") if multihop else "industry"
        destination_kind = row.get("destinationKind") if multihop else "industry"
        if not isinstance(line_cid, str) or not line_cid.startswith("line:") \
                or not isinstance(row.get("contractDigest"), str) \
                or re.fullmatch(r"[0-9a-f]{8}", row["contractDigest"]) is None \
                or not isinstance(source_cid, str) or not isinstance(destination_cid, str) \
                or source_cid == destination_cid \
                or not isinstance(cargo_type, str) \
                or re.fullmatch(r"[A-Z][A-Z0-9_]{0,127}", cargo_type) is None \
                or isinstance(stock_index, bool) or not isinstance(stock_index, int) \
                or not 0 <= stock_index < 32 \
                or isinstance(boarded, bool) or not isinstance(boarded, int) \
                or isinstance(delivered, bool) or not isinstance(delivered, int) \
                or not 0 <= delivered <= boarded <= MAX_COUNT \
                or isinstance(transport_schema, bool) \
                or not isinstance(transport_schema, int) \
                or transport_schema not in {1, 2} \
                or multihop and (
                    not isinstance(row.get("pathDigest"), str)
                    or re.fullmatch(r"[0-9a-f]{8}", row["pathDigest"]) is None
                    or isinstance(row.get("legIndex"), bool)
                    or not isinstance(row.get("legIndex"), int)
                    or isinstance(row.get("legCount"), bool)
                    or not isinstance(row.get("legCount"), int)
                    or not 0 <= row["legIndex"] < row["legCount"] <= 16
                    or source_kind not in {"industry", "station"}
                    or destination_kind not in {"industry", "station"}
                    or not isinstance(row.get("sourceStationGroupCid"), str)
                    or not isinstance(row.get("destinationStationGroupCid"), str)
                ):
            raise ProtocolError("freight transport row is malformed")
        source, destination = industries.get(source_cid), industries.get(destination_cid)
        if source_kind == "industry" and (
            not isinstance(source, dict) or not _output_matches(source, cargo_type)
        ):
            raise ProtocolError(f"freight transport source does not produce {cargo_type}")
        if destination_kind == "industry" and not isinstance(destination, dict):
            raise ProtocolError("freight transport destination is unknown")
        destination_stock = _input_stock(destination, stock_index, cargo_type) \
            if destination_kind == "industry" else None
        if destination_kind == "industry" and destination_stock is None:
            raise ProtocolError(f"freight transport destination stock does not accept {cargo_type}")
        cursor_value = cursors_value.get(line_cid)
        if cursor_value is not None and not isinstance(cursor_value, dict):
            raise ProtocolError("freight transport cursor is malformed")
        cursor = cursor_value if isinstance(cursor_value, dict) else {
            key: copy.deepcopy(value) for key, value in row.items()
            if key not in {"boardedUnits", "deliveredUnits", "earnedRevenueCents"}
        }
        if cursor_value is None:
            cursor["boardedUnits"], cursor["deliveredUnits"] = 0, 0
        if cursor_value is not None and _identity(cursor) != _identity(row):
            raise ProtocolError("freight transport contract changed after movement")
        prior_boarded, prior_delivered = int(cursor["boardedUnits"]), int(cursor["deliveredUnits"])
        if boarded < prior_boarded or delivered < prior_delivered:
            raise ProtocolError("freight transport cursor moved backwards")
        boarded_delta, delivered_delta = boarded - prior_boarded, delivered - prior_delivered
        if source_kind == "industry":
            key = (source_cid, cargo_type)
            aggregate[key] = aggregate.get(key, 0) + boarded_delta
            available = max(0, int(source.get("outputStock", {}).get(cargo_type, 0)))
            if aggregate[key] > available:
                raise ProtocolError("freight transport aggregate exceeds source output stock")
        staged[line_cid] = (
            source if source_kind == "industry" else None,
            destination_stock, cursor, boarded_delta, delivered_delta,
            cursor_value is not None or boarded > 0 or delivered > 0,
            source_kind, destination_kind,
        )

    summary: dict[str, Any] = {
        "lines": 0, "boarded": {}, "delivered": {}, "transferred": {}
    }
    for line_cid in sorted(staged):
        row = cargo_lines[line_cid]
        source, destination_stock, cursor, boarded_delta, delivered_delta, persist_cursor, \
            source_kind, destination_kind = \
            staged[line_cid]
        cargo_type = str(row["cargoType"])
        if source_kind == "industry":
            source["outputStock"][cargo_type] = int(source["outputStock"].get(cargo_type, 0)) \
                - boarded_delta
        if destination_kind == "industry":
            destination_stock["amount"] = _add(destination_stock.get("amount"), delivered_delta)
        cursor["boardedUnits"], cursor["deliveredUnits"] = row["boardedUnits"], row["deliveredUnits"]
        if persist_cursor:
            cursors_value[line_cid] = cursor
        total_transported[cargo_type] = _add(
            total_transported.get(cargo_type), boarded_delta
        )
        if destination_kind == "industry":
            total_delivered[cargo_type] = _add(
                total_delivered.get(cargo_type), delivered_delta
            )
        if persist_cursor:
            summary["lines"] += 1
        summary["boarded"][cargo_type] = _add(summary["boarded"].get(cargo_type), boarded_delta)
        target = summary["delivered"] if destination_kind == "industry" \
            else summary["transferred"]
        target[cargo_type] = _add(target.get(cargo_type), delivered_delta)
    state["transportCursors"] = cursors_value
    state["totalTransported"] = total_transported
    state["totalDelivered"] = total_delivered
    state["lastTransport"] = copy.deepcopy(summary)
    return summary
