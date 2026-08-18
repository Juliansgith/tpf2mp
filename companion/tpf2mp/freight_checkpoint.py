from __future__ import annotations

import copy
import re
from collections.abc import Mapping
from typing import Any

MAX_COUNT = 1_000_000_000
MAX_ACCUMULATOR = 1_000_000_000_000_000


def _fail(message: str) -> None:
    from .protocol import ProtocolError
    raise ProtocolError(message)


def _integer(value: Any, maximum: int = MAX_ACCUMULATOR) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= maximum:
        _fail("checkpoint freight counter is invalid")
    return value


def _array(value: Any, label: str) -> list[Any]:
    if isinstance(value, Mapping) and not value:
        return []
    if not isinstance(value, list):
        _fail(f"checkpoint freight {label} is not an array")
    return value


def _cargo(value: Any) -> str:
    if not isinstance(value, str) or re.fullmatch(r"[A-Z][A-Z0-9_]{0,127}", value) is None:
        _fail("checkpoint freight cargo type is invalid")
    return value


def _counters(value: Any, label: str) -> dict[str, int]:
    if not isinstance(value, Mapping):
        _fail(f"checkpoint freight {label} is not an object")
    result: dict[str, int] = {}
    for key, count in value.items():
        result[_cargo(key)] = _integer(count)
    return result


def _add(target: dict[str, int], cargo: str, amount: int) -> None:
    target[cargo] = min(MAX_ACCUMULATOR, target.get(cargo, 0) + amount)


def _empty_state(state: Mapping[str, Any]) -> dict[str, Any]:
    fields = ["industries", "totalProduced", "totalConsumed", "transportCursors",
              "totalTransported", "totalDelivered"]
    if state.get("schemaVersion") == 3:
        fields += ["retiredTransported", "retiredDelivered"]
    for field in fields:
        if not isinstance(state.get(field), Mapping) or state[field]:
            _fail("checkpoint unready freight state contains authored inventory")
    return dict(state)


def validate_freight_state(value: Any) -> dict[str, Any]:
    if not isinstance(value, Mapping) or value.get("schemaVersion") not in {2, 3} \
            or not isinstance(value.get("ready"), bool):
        _fail("checkpoint freight state header is invalid")
    state = dict(value)
    _integer(state.get("bootstrapEpoch"), MAX_COUNT)
    production_epoch = _integer(state.get("productionEpoch"), MAX_COUNT)
    if state["ready"] is not True:
        return _empty_state(state)
    if not isinstance(state.get("contentDigest"), str) \
            or re.fullmatch(r"[0-9a-f]{8}", state["contentDigest"]) is None \
            or not isinstance(state.get("bootstrapDigest"), str) \
            or re.fullmatch(r"[0-9a-f]{8}", state["bootstrapDigest"]) is None \
            or production_epoch < state["bootstrapEpoch"]:
        _fail("checkpoint freight bootstrap identity is invalid")
    industries_value = state.get("industries")
    if not isinstance(industries_value, Mapping):
        _fail("checkpoint freight industries are malformed")
    recipes, produced_sum, consumed_sum = [], {}, {}
    input_stocks: dict[str, dict[int, str]] = {}
    output_types: dict[str, set[str]] = {}
    industry_fields = {"cid", "recipe", "inputStock", "outputStock", "productionResid",
                       "totalProduced", "totalConsumed", "lastCycles"}
    for cid in sorted(industries_value):
        item = industries_value[cid]
        if not isinstance(cid, str) or not cid.startswith("industry:") \
                or not isinstance(item, Mapping) or set(item) != industry_fields \
                or item.get("cid") != cid or not isinstance(item.get("recipe"), Mapping):
            _fail("checkpoint freight industry record is malformed")
        recipe = copy.deepcopy(dict(item["recipe"]))
        recipes.append(recipe)
        stocks = _array(item["inputStock"], "input stock")
        recipe_stocks = _array(recipe.get("stocks", {}), "recipe stocks")
        if len(stocks) != len(recipe_stocks):
            _fail("checkpoint freight input stock disagrees with its recipe")
        input_stocks[cid] = {}
        for index, (stock, expected) in enumerate(zip(stocks, recipe_stocks)):
            if not isinstance(stock, Mapping) or set(stock) != {"index", "cargoType", "amount"} \
                    or stock.get("index") != index \
                    or stock.get("index") != expected.get("index") \
                    or stock.get("cargoType") != expected.get("cargoType"):
                _fail("checkpoint freight input stock identity is invalid")
            input_stocks[cid][index] = _cargo(stock["cargoType"])
            _integer(stock["amount"])
        outputs = _array(recipe.get("outputs", {}), "recipe outputs")
        output_types[cid] = {_cargo(row.get("cargoType")) for row in outputs
                             if isinstance(row, Mapping)}
        if len(output_types[cid]) != len(outputs) or not isinstance(item["outputStock"], Mapping):
            _fail("checkpoint freight output recipe is malformed")
        for cargo, amount in item["outputStock"].items():
            if _cargo(cargo) not in output_types[cid]:
                _fail("checkpoint freight output stock is not produced by its recipe")
            _integer(amount)
        if _integer(item["productionResid"], 3599) != item["productionResid"]:
            _fail("checkpoint freight production residual is invalid")
        _integer(item["lastCycles"], MAX_COUNT)
        produced = _counters(item["totalProduced"], "industry produced totals")
        consumed = _counters(item["totalConsumed"], "industry consumed totals")
        for cargo, amount in produced.items():
            if cargo not in output_types[cid]:
                _fail("checkpoint freight produced total has an impossible cargo type")
            _add(produced_sum, cargo, amount)
        for cargo, amount in consumed.items():
            _add(consumed_sum, cargo, amount)

    from .protocol import validate_action
    bootstrap = validate_action({
        "type": "freight.industry_bootstrap", "schemaVersion": 1,
        "contentDigest": state["contentDigest"], "economyEpoch": state["bootstrapEpoch"],
        "industries": recipes, "digest": state["bootstrapDigest"],
    })
    if bootstrap["digest"] != state["bootstrapDigest"]:
        _fail("checkpoint freight bootstrap digest is invalid")
    if _counters(state.get("totalProduced"), "produced totals") != produced_sum \
            or _counters(state.get("totalConsumed"), "consumed totals") != consumed_sum:
        _fail("checkpoint freight production totals disagree with industries")

    cursors_value = state.get("transportCursors")
    if not isinstance(cursors_value, Mapping):
        _fail("checkpoint freight transport cursors are malformed")
    transported_sum, delivered_sum = {}, {}
    cursor_fields = {"contractDigest", "sourceIndustryCid", "destinationIndustryCid",
                     "destinationStockIndex", "cargoType", "boardedUnits", "deliveredUnits"}
    multihop_fields = cursor_fields | {
        "transportSchema", "pathDigest", "legIndex", "legCount", "sourceKind",
        "destinationKind", "sourceStationGroupCid", "destinationStationGroupCid",
    }
    for line_cid in sorted(cursors_value):
        cursor = cursors_value[line_cid]
        if not isinstance(line_cid, str) or not line_cid.startswith("line:") \
                or not isinstance(cursor, Mapping) or frozenset(cursor) not in {
                    frozenset(cursor_fields), frozenset(multihop_fields)
                } \
                or not isinstance(cursor["contractDigest"], str) \
                or re.fullmatch(r"[0-9a-f]{8}", cursor["contractDigest"]) is None:
            _fail("checkpoint freight transport cursor is malformed")
        source, destination, cargo = cursor["sourceIndustryCid"], \
            cursor["destinationIndustryCid"], _cargo(cursor["cargoType"])
        stock_index = _integer(cursor["destinationStockIndex"], 31)
        boarded, delivered = _integer(cursor["boardedUnits"], MAX_COUNT), \
            _integer(cursor["deliveredUnits"], MAX_COUNT)
        transport_schema = cursor.get("transportSchema", 1)
        multihop = transport_schema == 2
        source_kind = cursor.get("sourceKind") if multihop else "industry"
        destination_kind = cursor.get("destinationKind") if multihop else "industry"
        if isinstance(transport_schema, bool) or not isinstance(transport_schema, int) \
                or transport_schema not in {1, 2} \
                or source == destination \
                or source_kind == "industry" and cargo not in output_types.get(source, set()) \
                or destination_kind == "industry" \
                    and input_stocks.get(destination, {}).get(stock_index) != cargo \
                or delivered > boarded:
            _fail("checkpoint freight transport cursor disagrees with industry recipes")
        if multihop and (
            not isinstance(cursor.get("pathDigest"), str)
            or re.fullmatch(r"[0-9a-f]{8}", cursor["pathDigest"]) is None
            or cursor.get("sourceKind") not in {"industry", "station"}
            or cursor.get("destinationKind") not in {"industry", "station"}
            or not isinstance(cursor.get("sourceStationGroupCid"), str)
            or not isinstance(cursor.get("destinationStationGroupCid"), str)
            or not isinstance(cursor.get("legIndex"), int)
            or not isinstance(cursor.get("legCount"), int)
            or not 0 <= cursor["legIndex"] < cursor["legCount"] <= 16
        ):
            _fail("checkpoint freight multi-hop cursor is malformed")
        _add(transported_sum, cargo, boarded)
        if destination_kind == "industry":
            _add(delivered_sum, cargo, delivered)
    total_transported = _counters(state.get("totalTransported"), "transported totals")
    total_delivered = _counters(state.get("totalDelivered"), "delivered totals")
    retired_transported = _counters(
        state.get("retiredTransported", {}), "retired transported totals"
    ) if state["schemaVersion"] >= 3 else {}
    retired_delivered = _counters(
        state.get("retiredDelivered", {}), "retired delivered totals"
    ) if state["schemaVersion"] >= 3 else {}
    for cargo, amount in retired_transported.items():
        _add(transported_sum, cargo, amount)
    for cargo, amount in retired_delivered.items():
        _add(delivered_sum, cargo, amount)
    if total_transported != transported_sum or total_delivered != delivered_sum:
        _fail("checkpoint freight transport totals disagree with cursors")
    last = state.get("lastTransport")
    if last is not None:
        line_count = _integer(last.get("lines"), MAX_COUNT) \
            if isinstance(last, Mapping) else 0
        if not isinstance(last, Mapping) or set(last) not in (
                {"lines", "boarded", "delivered"},
                {"lines", "boarded", "delivered", "transferred"}) \
                or state["schemaVersion"] >= 3 and line_count > len(cursors_value):
            _fail("checkpoint last freight transport summary is malformed")
        for cargo, amount in _counters(last["boarded"], "last boarded").items():
            if amount > transported_sum.get(cargo, 0):
                _fail("checkpoint last freight transport exceeds cumulative totals")
        for cargo, amount in _counters(last["delivered"], "last delivered").items():
            if amount > delivered_sum.get(cargo, 0):
                _fail("checkpoint last freight transport exceeds cumulative totals")
    return state
