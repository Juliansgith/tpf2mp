from __future__ import annotations

import copy
from collections.abc import Mapping
from typing import Any

SCHEMA_VERSION = 3
BOOTSTRAP_SCHEMA_VERSION = 1
MAX_AMOUNT = 1_000_000_000
MAX_ACCUMULATOR = 1_000_000_000_000_000


def _lua_array(value: Any) -> list[Any]:
    if isinstance(value, list):
        return value
    if isinstance(value, Mapping) and not value:
        return []
    raise ValueError("freight value is not a Lua-compatible sequence")


def new_state() -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "ready": False,
        "contentDigest": None,
        "bootstrapDigest": None,
        "bootstrapEpoch": 0,
        "productionEpoch": 0,
        "industries": {},
        "totalProduced": {},
        "totalConsumed": {},
        "transportCursors": {},
        "totalTransported": {},
        "totalDelivered": {},
        "retiredTransported": {},
        "retiredDelivered": {},
        "lastTransport": None,
        "lastAdvance": None,
    }


def _state_industry(recipe: Mapping[str, Any]) -> dict[str, Any]:
    stocks = _lua_array(recipe.get("stocks", {}))
    input_stock: list[dict[str, Any]] | dict[str, Any] = [
        {"index": int(stock["index"]), "cargoType": str(stock["cargoType"]), "amount": 0}
        for stock in stocks
    ]
    if not input_stock:
        input_stock = {}
    return {
        "cid": str(recipe["cid"]),
        "recipe": copy.deepcopy(dict(recipe)),
        "inputStock": input_stock,
        "outputStock": {},
        "productionResid": 0,
        "totalProduced": {},
        "totalConsumed": {},
        "lastCycles": 0,
    }


def apply_bootstrap(
    state: dict[str, Any], action: Mapping[str, Any], industry_content: Mapping[str, Any]
) -> dict[str, Any]:
    # Import lazily: protocol validation also defines this action and importing
    # it at module load time would create a cycle through checkpoint.py.
    from .protocol import ProtocolError, validate_action

    validated = validate_action(copy.deepcopy(dict(action)))
    if validated.get("type") != "freight.industry_bootstrap":
        raise ProtocolError("freight bootstrap action has the wrong type")
    if industry_content.get("ready") is not True \
            or industry_content.get("digest") != validated["contentDigest"]:
        raise ProtocolError("freight bootstrap does not match agreed industry content")
    if state.get("ready") is True:
        if state.get("bootstrapDigest") == validated["digest"]:
            return digest_view(state)
        raise ProtocolError("freight industries cannot change after bootstrap")
    industries: dict[str, Any] = {}
    for recipe in _lua_array(validated["industries"]):
        industries[str(recipe["cid"])] = _state_industry(recipe)
    state.clear()
    state.update({
        "schemaVersion": SCHEMA_VERSION,
        "ready": True,
        "contentDigest": validated["contentDigest"],
        "bootstrapDigest": validated["digest"],
        "bootstrapEpoch": int(validated["economyEpoch"]),
        "productionEpoch": int(validated["economyEpoch"]),
        "industries": industries,
        "totalProduced": {},
        "totalConsumed": {},
        "transportCursors": {},
        "totalTransported": {},
        "totalDelivered": {},
        "retiredTransported": {},
        "retiredDelivered": {},
        "lastTransport": None,
        "lastAdvance": None,
    })
    return digest_view(state)


def _saturating_add(left: Any, right: Any) -> int:
    return min(MAX_ACCUMULATOR, max(0, int(left or 0)) + max(0, int(right or 0)))


def advance(state: dict[str, Any], epoch: int, period_seconds: int) -> dict[str, Any]:
    from .protocol import ProtocolError

    if state.get("ready") is not True:
        return {"skipped": "not-ready"}
    if isinstance(epoch, bool) or not isinstance(epoch, int) \
            or epoch != int(state.get("productionEpoch", 0)) + 1 \
            or not 1 <= epoch <= MAX_AMOUNT:
        raise ProtocolError("freight production epoch is not the next authored epoch")
    if isinstance(period_seconds, bool) or not isinstance(period_seconds, int) \
            or not 60 <= period_seconds <= 86_400:
        raise ProtocolError("freight production period is invalid")
    summary: dict[str, Any] = {
        "epoch": epoch,
        "periodSeconds": period_seconds,
        "industries": {},
        "produced": {},
        "consumed": {},
    }
    industries = state.setdefault("industries", {})
    for cid in sorted(industries):
        industry = industries[cid]
        recipe = industry["recipe"]
        numerator = int(industry.get("productionResid", 0)) \
            + int(recipe["capacity"]) * period_seconds
        quota, industry["productionResid"] = divmod(numerator, 3600)
        stocks = {
            int(stock["index"]): stock for stock in _lua_array(industry.get("inputStock", {}))
        }
        cycles = 0
        for alternative_value in _lua_array(recipe["inputs"]):
            alternative = _lua_array(alternative_value)
            feasible = quota
            for requirement in alternative:
                stock = stocks.get(int(requirement["stockIndex"]))
                if stock is None:
                    feasible = 0
                    break
                feasible = min(feasible, int(stock["amount"]) // int(requirement["amount"]))
            if feasible > 0 or (not alternative and quota == 0):
                cycles = feasible
                if cycles:
                    for requirement in alternative:
                        stock = stocks[int(requirement["stockIndex"])]
                        consumed = cycles * int(requirement["amount"])
                        stock["amount"] = int(stock["amount"]) - consumed
                        cargo = str(requirement["cargoType"])
                        industry["totalConsumed"][cargo] = _saturating_add(
                            industry["totalConsumed"].get(cargo), consumed
                        )
                        state["totalConsumed"][cargo] = _saturating_add(
                            state["totalConsumed"].get(cargo), consumed
                        )
                        summary["consumed"][cargo] = _saturating_add(
                            summary["consumed"].get(cargo), consumed
                        )
                break
        if cycles:
            for output in _lua_array(recipe["outputs"]):
                cargo = str(output["cargoType"])
                produced = cycles * int(output["amount"])
                industry["outputStock"][cargo] = _saturating_add(
                    industry["outputStock"].get(cargo), produced
                )
                industry["totalProduced"][cargo] = _saturating_add(
                    industry["totalProduced"].get(cargo), produced
                )
                state["totalProduced"][cargo] = _saturating_add(
                    state["totalProduced"].get(cargo), produced
                )
                summary["produced"][cargo] = _saturating_add(
                    summary["produced"].get(cargo), produced
                )
        industry["lastCycles"] = cycles
        summary["industries"][cid] = {
            "quota": quota,
            "cycles": cycles,
            "productionResid": int(industry["productionResid"]),
        }
    state["productionEpoch"] = epoch
    state["lastAdvance"] = copy.deepcopy(summary)
    return summary


def deposit_input_at_stock(
    state: dict[str, Any], cid: str, stock_index: int, cargo_type: str, amount: int
) -> int:
    from .protocol import ProtocolError

    if state.get("ready") is not True or isinstance(amount, bool) \
            or not isinstance(amount, int) or not 1 <= amount <= MAX_AMOUNT \
            or isinstance(stock_index, bool) or not isinstance(stock_index, int) \
            or not 0 <= stock_index < 32:
        raise ProtocolError("freight input deposit is invalid")
    industry = state.get("industries", {}).get(cid)
    if not isinstance(industry, dict):
        raise ProtocolError("freight input industry is unknown")
    for stock in _lua_array(industry.get("inputStock", {})):
        if stock.get("index") == stock_index and stock.get("cargoType") == cargo_type:
            stock["amount"] = _saturating_add(stock.get("amount"), amount)
            return int(stock["amount"])
    raise ProtocolError(f"industry stock does not accept cargo {cargo_type}")


def deposit_input(state: dict[str, Any], cid: str, cargo_type: str, amount: int) -> int:
    industry = state.get("industries", {}).get(cid)
    stocks = _lua_array(industry.get("inputStock", {})) if isinstance(industry, dict) else []
    matches = [int(stock["index"]) for stock in stocks if stock.get("cargoType") == cargo_type]
    if len(matches) > 1:
        from .protocol import ProtocolError
        raise ProtocolError("industry cargo target is ambiguous; stock index is required")
    return deposit_input_at_stock(state, cid, matches[0] if matches else -1, cargo_type, amount)


def withdraw_output(state: dict[str, Any], cid: str, cargo_type: str, amount: int) -> int:
    from .protocol import ProtocolError

    if state.get("ready") is not True or isinstance(amount, bool) \
            or not isinstance(amount, int) or not 1 <= amount <= MAX_AMOUNT:
        raise ProtocolError("freight output withdrawal is invalid")
    industry = state.get("industries", {}).get(cid)
    if not isinstance(industry, dict):
        raise ProtocolError("freight output industry is unknown")
    available = max(0, int(industry.get("outputStock", {}).get(cargo_type, 0)))
    if available < amount:
        raise ProtocolError("industry output stock is insufficient")
    industry["outputStock"][cargo_type] = available - amount
    return available - amount


def apply_transport(state: dict[str, Any], cargo_lines: Mapping[str, Any]) -> dict[str, Any]:
    from .freight_transport import apply_transport as apply
    return apply(state, cargo_lines)


def digest_view(state: Mapping[str, Any]) -> dict[str, Any]:
    industries: dict[str, Any] = {}
    raw_industries = state.get("industries", {})
    if isinstance(raw_industries, Mapping):
        for cid in sorted(raw_industries):
            value = raw_industries[cid]
            industries[str(cid)] = {
                "cid": str(cid),
                "recipe": copy.deepcopy(value.get("recipe")),
                "inputStock": copy.deepcopy(value.get("inputStock", {})),
                "outputStock": copy.deepcopy(value.get("outputStock", {})),
                "productionResid": max(0, int(value.get("productionResid", 0))),
                "totalProduced": copy.deepcopy(value.get("totalProduced", {})),
                "totalConsumed": copy.deepcopy(value.get("totalConsumed", {})),
                "lastCycles": max(0, int(value.get("lastCycles", 0))),
            }
    result = {
        "schemaVersion": SCHEMA_VERSION,
        "ready": state.get("ready") is True,
        "contentDigest": state.get("contentDigest"),
        "bootstrapDigest": state.get("bootstrapDigest"),
        "bootstrapEpoch": max(0, int(state.get("bootstrapEpoch", 0))),
        "productionEpoch": max(0, int(state.get("productionEpoch", 0))),
        "industries": industries,
        "totalProduced": copy.deepcopy(state.get("totalProduced", {})),
        "totalConsumed": copy.deepcopy(state.get("totalConsumed", {})),
        "transportCursors": copy.deepcopy(state.get("transportCursors", {})),
        "totalTransported": copy.deepcopy(state.get("totalTransported", {})),
        "totalDelivered": copy.deepcopy(state.get("totalDelivered", {})),
        "retiredTransported": copy.deepcopy(state.get("retiredTransported", {})),
        "retiredDelivered": copy.deepcopy(state.get("retiredDelivered", {})),
        "lastAdvance": copy.deepcopy(state.get("lastAdvance")),
    }
    if state.get("lastTransport") is not None:
        result["lastTransport"] = copy.deepcopy(state.get("lastTransport"))
    return result
