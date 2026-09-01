from __future__ import annotations

import copy
from datetime import date, timedelta
from typing import Any, Mapping

from .protocol import ProtocolError


SCHEMA_VERSION = 1
DEFAULT_MILLIS_PER_DAY = 2000
MIN_YEAR = 1400
MAX_YEAR = 9999


def _integer(value: Any, name: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise ProtocolError(f"{name} is invalid")
    return value


def normalize_date(value: Any) -> dict[str, int]:
    if not isinstance(value, Mapping) or set(value) != {"year", "month", "day"}:
        raise ProtocolError("calendar date must contain year, month, and day")
    year = _integer(value.get("year"), "calendar year", MIN_YEAR, MAX_YEAR)
    month = _integer(value.get("month"), "calendar month", 1, 12)
    day_value = _integer(value.get("day"), "calendar day", 1, 31)
    try:
        native = date(year, month, day_value)
    except ValueError as exc:
        raise ProtocolError("calendar date is invalid") from exc
    return {"year": native.year, "month": native.month, "day": native.day}


def add_days(value: Any, delta: int) -> dict[str, int]:
    current = normalize_date(value)
    _integer(delta, "calendar day delta", 0, 10_000_000)
    try:
        advanced = date(current["year"], current["month"], current["day"]) + timedelta(days=delta)
    except (OverflowError, ValueError) as exc:
        raise ProtocolError("calendar advancement exceeds the supported native range") from exc
    if not MIN_YEAR <= advanced.year <= MAX_YEAR:
        raise ProtocolError("calendar advancement exceeds the supported native range")
    return {"year": advanced.year, "month": advanced.month, "day": advanced.day}


def new_state() -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "managed": False,
        "initialized": False,
        "millisPerDay": DEFAULT_MILLIS_PER_DAY,
        "startDate": None,
        "currentDate": None,
        "elapsedDays": 0,
        "residualMillis": 0,
        "lastEpoch": 0,
    }


def migrate(value: Any) -> dict[str, Any]:
    result = new_state()
    if not isinstance(value, Mapping):
        return result
    result["managed"] = value.get("managed") is True
    result["initialized"] = value.get("initialized") is True
    result["millisPerDay"] = _integer(
        value.get("millisPerDay", DEFAULT_MILLIS_PER_DAY),
        "calendar milliseconds per day", 0, 86_400_000,
    )
    result["elapsedDays"] = _integer(value.get("elapsedDays", 0), "calendar elapsed days", 0, 10_000_000)
    result["residualMillis"] = _integer(
        value.get("residualMillis", 0), "calendar residual milliseconds", 0, 86_400_000,
    )
    result["lastEpoch"] = _integer(value.get("lastEpoch", 0), "calendar last epoch", 0, 1_000_000_000)
    if result["millisPerDay"] > 0:
        if result["residualMillis"] >= result["millisPerDay"]:
            raise ProtocolError("calendar residual milliseconds exceed one native day")
    elif result["residualMillis"] != 0:
        raise ProtocolError("paused calendar cannot carry a residual")
    if value.get("startDate") is not None:
        result["startDate"] = normalize_date(value["startDate"])
    if value.get("currentDate") is not None:
        result["currentDate"] = normalize_date(value["currentDate"])
    if result["initialized"] and (result["startDate"] is None or result["currentDate"] is None):
        raise ProtocolError("initialized calendar is missing a date")
    return result


def prepare_settlement(
    current_value: Any,
    economy_epoch: int,
    scheduled: bool,
    epoch_seconds: int,
) -> tuple[dict[str, Any], dict[str, Any]]:
    current = migrate(current_value)
    if current["initialized"] is not True:
        raise ProtocolError("authored calendar is not initialised")
    epoch = _integer(economy_epoch, "calendar economy epoch", 1, 1_000_000_000)
    if epoch != current["lastEpoch"] + 1:
        raise ProtocolError("calendar settlement is not the next economy epoch")
    seconds = _integer(epoch_seconds, "calendar epoch duration", 1, 86_400)
    candidate = copy.deepcopy(current)
    advanced_days = 0
    if candidate["managed"] and scheduled and candidate["millisPerDay"] > 0:
        accumulated = candidate["residualMillis"] + seconds * 1000
        advanced_days, candidate["residualMillis"] = divmod(accumulated, candidate["millisPerDay"])
        if advanced_days:
            candidate["currentDate"] = add_days(candidate["currentDate"], advanced_days)
            candidate["elapsedDays"] += advanced_days
    candidate["lastEpoch"] = epoch
    payload = {
        "schemaVersion": SCHEMA_VERSION,
        "economyEpoch": epoch,
        "advanced": candidate["managed"] and scheduled,
        "advancedDays": advanced_days,
        "elapsedDays": candidate["elapsedDays"],
        "residualMillis": candidate["residualMillis"],
        "date": copy.deepcopy(candidate["currentDate"]),
    }
    return candidate, payload


def validate_payload(value: Any) -> dict[str, Any]:
    if not isinstance(value, Mapping) or set(value) != {
        "schemaVersion", "economyEpoch", "advanced", "advancedDays",
        "elapsedDays", "residualMillis", "date",
    }:
        raise ProtocolError("economy.settle calendar payload is malformed")
    if value.get("schemaVersion") != SCHEMA_VERSION:
        raise ProtocolError("economy.settle calendar schema is unsupported")
    if not isinstance(value.get("advanced"), bool):
        raise ProtocolError("economy.settle calendar advanced flag is invalid")
    result = {
        "schemaVersion": SCHEMA_VERSION,
        "economyEpoch": _integer(value.get("economyEpoch"), "calendar economy epoch", 1, 1_000_000_000),
        "advanced": value["advanced"],
        "advancedDays": _integer(value.get("advancedDays"), "calendar advanced days", 0, 10_000_000),
        "elapsedDays": _integer(value.get("elapsedDays"), "calendar elapsed days", 0, 10_000_000),
        "residualMillis": _integer(value.get("residualMillis"), "calendar residual milliseconds", 0, 86_400_000),
        "date": normalize_date(value.get("date")),
    }
    return result


def validate_match_rules(rules: Mapping[str, Any]) -> None:
    if "calendarMillisPerDay" in rules:
        _integer(rules.get("calendarMillisPerDay"),
                 "match.initialise calendarMillisPerDay", 0, 86_400_000)
    if "calendarStartDate" in rules:
        normalize_date(rules.get("calendarStartDate"))


def apply_settlement(model: dict[str, Any], action: Mapping[str, Any], economy_epoch: int, epoch_seconds: int) -> None:
    received = validate_payload(action.get("calendar"))
    candidate, expected = prepare_settlement(
        model.get("calendar"), economy_epoch, action.get("scheduled") is True, epoch_seconds,
    )
    if received != expected:
        raise ProtocolError("economy.settle calendar payload diverges from deterministic replay")
    model["calendar"] = candidate
