from __future__ import annotations

import json
import math
import re
import time
import zlib
from pathlib import Path
from typing import Any, Mapping

from .bridge import GameBridge, atomic_write
from .protocol import ProtocolError, canonical_json, checksum


SCHEMA_VERSION = 1
MAX_RESOURCES = 1024
MAX_VARIANTS_PER_RESOURCE = 128
MAX_ARTIFACT_BYTES = 2 * 1024 * 1024
_DIGEST = re.compile(r"^[0-9a-f]{8}$")
_RESOURCE = re.compile(r"^[A-Za-z0-9_./-]{1,512}$")


def _integer(
    value: Any,
    label: str,
    maximum: int = 1_000_000_000,
    *,
    minimum: int = 0,
) -> int:
    if not isinstance(value, int) or isinstance(value, bool) \
            or not minimum <= value <= maximum:
        raise ProtocolError(f"{label} must be a bounded integer")
    return value


def _sequence(value: Any, label: str) -> list[Any]:
    # Lua's canonical encoder cannot distinguish an empty array from an empty
    # object. It serializes both as {}, so accept exactly that representation.
    if value == {}:
        return []
    if not isinstance(value, list):
        raise ProtocolError(f"{label} must be a sequence")
    return list(value)


def _portable(value: Any, label: str, depth: int = 6, budget: list[int] | None = None) -> Any:
    if budget is None:
        budget = [0]
    if value is None or isinstance(value, (bool, str)):
        return value
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if not math.isfinite(value):
            raise ProtocolError(f"{label} contains a non-finite number")
        return value
    if depth <= 0:
        raise ProtocolError(f"{label} exceeds the nesting limit")
    if isinstance(value, list):
        result = []
        for item in value:
            budget[0] += 1
            if budget[0] > 2048:
                raise ProtocolError(f"{label} exceeds the item limit")
            result.append(_portable(item, label, depth - 1, budget))
        return result
    if isinstance(value, dict):
        result: dict[str, Any] = {}
        for key, item in value.items():
            if not isinstance(key, str) or len(key) > 256:
                raise ProtocolError(f"{label} has an invalid key")
            budget[0] += 1
            if budget[0] > 2048:
                raise ProtocolError(f"{label} exceeds the item limit")
            result[key] = _portable(item, label, depth - 1, budget)
        return result
    raise ProtocolError(f"{label} contains unsupported {type(value).__name__}")


def _resource_name(value: Any) -> str:
    if not isinstance(value, str) or not _RESOURCE.fullmatch(value) \
            or value.startswith("/") or ".." in value.split("/") \
            or "\\" in value or value.startswith("res/construction/"):
        raise ProtocolError("industry resource has a non-portable name")
    return value


def _validate_declarations(value: Any) -> list[dict[str, Any]]:
    declarations = _sequence(value, "industry parameter declarations")
    if len(declarations) > 32:
        raise ProtocolError("industry declares too many parameters")
    result, keys = [], set()
    for item in declarations:
        expected = {"key", "valueCount", "defaultIndex"}
        if not isinstance(item, dict) or set(item) != expected:
            raise ProtocolError("industry parameter declaration is malformed")
        key = item["key"]
        if not isinstance(key, str) or not key or len(key) > 128 or key in keys:
            raise ProtocolError("industry parameter key is invalid or duplicated")
        keys.add(key)
        count = _integer(item["valueCount"], f"industry parameter {key} valueCount", 1024)
        default = _integer(item["defaultIndex"], f"industry parameter {key} defaultIndex", 1023)
        if count < 1 or default >= count:
            raise ProtocolError(f"industry parameter {key} has an invalid default")
        result.append({"key": key, "valueCount": count, "defaultIndex": default})
    result.sort(key=lambda item: item["key"])
    return result


def _validate_recipe(value: Any, resource_name: str, params: Mapping[str, Any]) -> dict[str, Any]:
    expected = {"resource", "params", "stocks", "inputs", "outputs", "capacity", "digest"}
    if not isinstance(value, dict) or set(value) != expected:
        raise ProtocolError(f"industry recipe for {resource_name} is malformed")
    if value["resource"] != resource_name:
        raise ProtocolError(f"industry recipe for {resource_name} names another resource")
    projected_params = _portable(value["params"], "industry recipe params")
    if not isinstance(projected_params, dict) or canonical_json(projected_params) != canonical_json(params):
        raise ProtocolError(f"industry recipe for {resource_name} has mismatched params")
    stocks = _sequence(value["stocks"], "industry stocks")
    normal_stocks = []
    for index, stock in enumerate(stocks):
        expected_stock = {"index", "cargoType", "stockType", "moreCapacity"}
        if not isinstance(stock, dict) or set(stock) != expected_stock:
            raise ProtocolError(f"industry stock for {resource_name} is malformed")
        if _integer(stock["index"], "industry stock index", 127) != index:
            raise ProtocolError(f"industry stocks for {resource_name} are not contiguous")
        cargo = stock["cargoType"]
        stock_type = stock["stockType"]
        if not isinstance(cargo, str) or not cargo or len(cargo) > 128 \
                or not isinstance(stock_type, str) or len(stock_type) > 128:
            raise ProtocolError(f"industry stock for {resource_name} has invalid cargo metadata")
        normal_stocks.append({
            "index": index,
            "cargoType": cargo,
            "stockType": stock_type,
            "moreCapacity": _integer(stock["moreCapacity"], "stock moreCapacity"),
        })
    inputs = _sequence(value["inputs"], "industry input alternatives")
    if not inputs or len(inputs) > 128:
        raise ProtocolError(f"industry {resource_name} has no bounded input alternative")
    normal_inputs = []
    for alternative in inputs:
        requirements = _sequence(alternative, "industry input alternative")
        normal_requirements = []
        for requirement in requirements:
            expected_requirement = {"stockIndex", "cargoType", "amount"}
            if not isinstance(requirement, dict) or set(requirement) != expected_requirement:
                raise ProtocolError(f"industry input for {resource_name} is malformed")
            stock_index = _integer(requirement["stockIndex"], "industry input stockIndex", 127)
            if stock_index >= len(normal_stocks) \
                    or requirement["cargoType"] != normal_stocks[stock_index]["cargoType"]:
                raise ProtocolError(f"industry input for {resource_name} references an unknown stock")
            normal_requirements.append({
                "stockIndex": stock_index,
                "cargoType": requirement["cargoType"],
                "amount": _integer(requirement["amount"], "industry input amount", minimum=1),
            })
        normal_inputs.append(normal_requirements)
    outputs = _sequence(value["outputs"], "industry outputs")
    normal_outputs, output_types = [], set()
    for output in outputs:
        if not isinstance(output, dict) or set(output) != {"cargoType", "amount"}:
            raise ProtocolError(f"industry output for {resource_name} is malformed")
        cargo = output["cargoType"]
        if not isinstance(cargo, str) or not cargo or len(cargo) > 128 or cargo in output_types:
            raise ProtocolError(f"industry output for {resource_name} has invalid cargo type")
        output_types.add(cargo)
        normal_outputs.append({
            "cargoType": cargo,
            "amount": _integer(output["amount"], "industry output amount", minimum=1),
        })
    normal_outputs.sort(key=lambda item: item["cargoType"])
    capacity = _integer(value["capacity"], "industry capacity")
    if not normal_outputs and not any(normal_inputs):
        raise ProtocolError(f"industry {resource_name} has no positive flow")
    content = {key: value[key] for key in expected if key != "digest"}
    digest = value["digest"]
    if not isinstance(digest, str) or not _DIGEST.fullmatch(digest) or checksum(content) != digest:
        raise ProtocolError(f"industry recipe digest for {resource_name} is invalid")
    return json.loads(canonical_json(value))


def _validate_variant(value: Any, resource_name: str) -> dict[str, Any]:
    expected = {"params", "recipe", "recipeDigests", "ambiguous"}
    if not isinstance(value, dict) or set(value) != expected or not isinstance(value["ambiguous"], bool):
        raise ProtocolError(f"industry variant for {resource_name} is malformed")
    params = _portable(value["params"], "industry variant params")
    if not isinstance(params, dict):
        raise ProtocolError(f"industry variant for {resource_name} has invalid params")
    digests = _sequence(value["recipeDigests"], "industry recipe digests")
    if not digests or len(digests) > 128 or any(
        not isinstance(item, str) or not _DIGEST.fullmatch(item) for item in digests
    ) or digests != sorted(set(digests)):
        raise ProtocolError(f"industry variant digests for {resource_name} are invalid")
    if value["ambiguous"]:
        if value["recipe"] != {} or len(digests) < 2:
            raise ProtocolError(f"ambiguous industry variant for {resource_name} retained a recipe")
        recipe: dict[str, Any] = {}
    else:
        if len(digests) != 1:
            raise ProtocolError(f"industry variant for {resource_name} has multiple recipes")
        recipe = _validate_recipe(value["recipe"], resource_name, params)
        if recipe["digest"] != digests[0]:
            raise ProtocolError(f"industry variant for {resource_name} has inconsistent digests")
    return json.loads(canonical_json(value))


def validate_resource(value: Any) -> dict[str, Any]:
    expected = {"fileName", "parameters", "declarationAmbiguous", "variants"}
    if not isinstance(value, dict) or set(value) != expected \
            or not isinstance(value["declarationAmbiguous"], bool):
        raise ProtocolError("industry resource artifact is malformed")
    name = _resource_name(value["fileName"])
    declarations = _validate_declarations(value["parameters"])
    canonical_declarations: Any = declarations if declarations else {}
    if canonical_json(value["parameters"]) != canonical_json(canonical_declarations):
        raise ProtocolError(f"industry parameter declarations for {name} are not canonical")
    variants = _sequence(value["variants"], f"industry variants for {name}")
    if len(variants) > MAX_VARIANTS_PER_RESOURCE:
        raise ProtocolError(f"industry {name} has too many variants")
    normal_variants, identities, ordered_identities = [], set(), []
    for variant in variants:
        normal = _validate_variant(variant, name)
        identity = canonical_json(normal["params"])
        if identity in identities:
            raise ProtocolError(f"industry {name} duplicates a parameter variant")
        identities.add(identity)
        ordered_identities.append(identity)
        normal_variants.append(normal)
    if ordered_identities != sorted(ordered_identities):
        raise ProtocolError(f"industry {name} variants are not canonically ordered")
    return json.loads(canonical_json(value))


def validate_artifact(value: Any, path: Path | None = None) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != {"schemaVersion", "resource", "digest"} \
            or value.get("schemaVersion") != SCHEMA_VERSION:
        raise ProtocolError("industry artifact has an unknown schema")
    resource = validate_resource(value["resource"])
    content = {"schemaVersion": SCHEMA_VERSION, "resource": value["resource"]}
    digest = value["digest"]
    if not isinstance(digest, str) or not _DIGEST.fullmatch(digest) \
            or checksum(content) != digest:
        raise ProtocolError("industry artifact digest is invalid")
    if path is not None:
        resource_key = f"{zlib.adler32(resource['fileName'].encode('utf-8')) & 0xFFFFFFFF:08x}"
        expected_name = f"{resource_key}-{digest}.json"
        if path.name != expected_name:
            raise ProtocolError(f"industry artifact filename is not content-addressed: {path.name}")
    return {**content, "digest": digest}


def _merge_resource(target: dict[str, Any], source: Mapping[str, Any]) -> dict[str, Any]:
    if target["fileName"] != source["fileName"]:
        raise ProtocolError("cannot merge different industry resources")
    if canonical_json(target["parameters"]) != canonical_json(source["parameters"]):
        target["declarationAmbiguous"] = True
        target["parameters"] = {}
    target["declarationAmbiguous"] = (
        target["declarationAmbiguous"] or source["declarationAmbiguous"]
    )
    by_params = {
        canonical_json(item["params"]): item
        for item in _sequence(target["variants"], "merged industry variants")
    }
    for source_variant in _sequence(source["variants"], "merged source industry variants"):
        identity = canonical_json(source_variant["params"])
        existing = by_params.get(identity)
        if existing is None:
            by_params[identity] = json.loads(canonical_json(source_variant))
            continue
        if canonical_json(existing) == canonical_json(source_variant):
            continue
        digests = sorted(set(existing["recipeDigests"]) | set(source_variant["recipeDigests"]))
        existing.update({"recipe": {}, "recipeDigests": digests, "ambiguous": True})
    if len(by_params) > MAX_VARIANTS_PER_RESOURCE:
        raise ProtocolError(f"industry {target['fileName']} exceeds the merged variant limit")
    target["variants"] = [by_params[key] for key in sorted(by_params)] if by_params else {}
    return target


def build_registry(artifact_directory: Path | str) -> dict[str, Any]:
    directory = Path(artifact_directory).expanduser().resolve()
    resources: dict[str, dict[str, Any]] = {}
    artifact_count = 0
    for path in sorted(directory.glob("*.json")):
        try:
            if path.stat().st_size > MAX_ARTIFACT_BYTES:
                raise ProtocolError(f"industry artifact is too large: {path.name}")
            value = json.loads(path.read_text(encoding="utf-8-sig"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ProtocolError(f"cannot read industry artifact {path.name}: {exc}") from exc
        artifact = validate_artifact(value, path)
        artifact_count += 1
        resource = artifact["resource"]
        name = resource["fileName"]
        if name in resources:
            resources[name] = _merge_resource(resources[name], resource)
        else:
            resources[name] = json.loads(canonical_json(resource))
    # Non-flow helpers such as industry/extension/field.con are construction
    # resources, but not authored freight nodes. Keep their artifacts for audit
    # and omit them from the authoritative recipe registry.
    selected = [
        resources[name] for name in sorted(resources)
        if _sequence(resources[name]["variants"], "industry variants")
    ]
    if not selected:
        raise ProtocolError("no industry recipe artifacts are available")
    if len(selected) > MAX_RESOURCES:
        raise ProtocolError("industry resource registry exceeds its resource limit")
    view = {"schemaVersion": SCHEMA_VERSION, "overflow": False, "resources": selected}
    ambiguous = sum(
        1 for resource in selected
        for variant in _sequence(resource["variants"], "industry variants")
        if resource["declarationAmbiguous"] or variant["ambiguous"]
    )
    return {
        "schemaVersion": SCHEMA_VERSION,
        "digest": checksum(view),
        "resourceCount": len(selected),
        "variantCount": sum(
            len(_sequence(item["variants"], "industry variants")) for item in selected
        ),
        "ambiguousCount": ambiguous,
        "artifactCount": artifact_count,
        "view": view,
    }


class IndustryContentCoordinator:
    """Validate loader artifacts and publish one engine-readable registry."""

    def __init__(self, bridge: GameBridge, quiet_seconds: float = 0.75) -> None:
        self.bridge = bridge
        self.quiet_seconds = max(0.0, float(quiet_seconds))
        self.output = bridge.state_dir / "industry_registry.json"
        self._snapshot: tuple[tuple[str, int, int], ...] | None = None
        self._changed_at = time.monotonic()
        self._published_digest: str | None = None
        self.registry: dict[str, Any] | None = None
        self.error: str | None = None

    def _files(self) -> tuple[tuple[str, int, int], ...]:
        return tuple(
            (path.name, path.stat().st_size, path.stat().st_mtime_ns)
            for path in sorted(self.bridge.industry_content_dir.glob("*.json"))
        )

    def refresh(self, now: float | None = None) -> bool:
        current_time = time.monotonic() if now is None else float(now)
        try:
            snapshot = self._files()
        except OSError as exc:
            self.error = f"cannot inspect industry artifacts: {exc}"
            return False
        if snapshot != self._snapshot:
            self._snapshot = snapshot
            self._changed_at = current_time
            self.error = None
            return True
        if not snapshot or current_time - self._changed_at < self.quiet_seconds:
            return False
        try:
            registry = build_registry(self.bridge.industry_content_dir)
        except ProtocolError as exc:
            error = str(exc)
            changed = error != self.error
            self.error = error
            self.registry = None
            return changed
        if registry["digest"] == self._published_digest and self.error is None:
            return False
        payload = {
            **registry,
            "session": self.bridge.session,
            "peer": self.bridge.peer,
            "generatedAtUnixMs": int(time.time() * 1000),
        }
        atomic_write(self.output, (canonical_json(payload) + "\n").encode("utf-8"))
        self.registry = registry
        self._published_digest = registry["digest"]
        self.error = None
        return True

    def status(self) -> dict[str, Any]:
        value = self.registry or {}
        return {
            "industryContentReady": self.registry is not None and self.error is None,
            "industryContentDigest": value.get("digest"),
            "industryContentResources": value.get("resourceCount", 0),
            "industryContentVariants": value.get("variantCount", 0),
            "industryContentAmbiguous": value.get("ambiguousCount", 0),
            "industryContentArtifacts": value.get(
                "artifactCount", len(self._snapshot or ()),
            ),
            "industryContentError": self.error,
        }


class IndustryContentConsensus:
    """Mirror ordered in-game content attestations at the host boundary."""

    def __init__(self, host: Any) -> None:
        self.host = host
        self.attestations: dict[str, dict[str, Any]] = {}
        self.result: dict[str, Any] = {"ready": False, "digest": None, "error": None}

    def before_commit(self, action: Mapping[str, Any], origin: str) -> None:
        if action.get("type") != "content.industry_attest":
            return
        if action.get("peer") != origin or origin not in self.host.required_peers:
            raise ProtocolError("industry content attestation has an unexpected origin")

    def observe(
        self,
        action: Mapping[str, Any],
        origin: str,
        *,
        restoring: bool = False,
    ) -> dict[str, Any]:
        self.before_commit(action, origin)
        if action.get("type") != "content.industry_attest":
            return dict(self.result)
        peer = str(action["peer"])
        value = {
            "peer": peer,
            "digest": str(action["digest"]),
            "resourceCount": int(action["resourceCount"]),
            "variantCount": int(action["variantCount"]),
            "ambiguousCount": int(action["ambiguousCount"]),
        }
        previous = self.attestations.get(peer)
        error: str | None = None
        if previous is not None and previous != value:
            error = "industry-content-peer-conflict"
        else:
            self.attestations[peer] = value
        if value["ambiguousCount"] > 0:
            error = error or "industry-content-ambiguous"
        required = set(self.host.required_peers)
        if error is None and required <= set(self.attestations):
            selected = [self.attestations[name] for name in self.host.required_peers]
            signatures = {
                (
                    item["digest"], item["resourceCount"],
                    item["variantCount"], item["ambiguousCount"],
                )
                for item in selected
            }
            if len(signatures) != 1:
                error = "industry-content-mismatch"
            else:
                first = selected[0]
                self.result = {
                    "ready": True,
                    "digest": first["digest"],
                    "resourceCount": first["resourceCount"],
                    "variantCount": first["variantCount"],
                    "ambiguousCount": first["ambiguousCount"],
                    "error": None,
                }
        if error is not None:
            self.result = {"ready": False, "digest": None, "error": error}
            self.host.session_fault = error
            if not restoring:
                self.host.last_error = error
        return dict(self.result)

    def status(self) -> dict[str, Any]:
        return {
            "industryContentConsensusReady": self.result.get("ready", False),
            "industryContentConsensusDigest": self.result.get("digest"),
            "industryContentConsensusError": self.result.get("error"),
            "industryContentAttestedPeers": sorted(self.attestations),
        }
