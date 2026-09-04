#!/usr/bin/env python3
"""Validate the declared construction corpus and its executable coverage."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any


LIVE_SLICES = {
    "full",
    "connected-terminal",
    "connected-road-depot",
    "connected-tram-depot",
    "second-station",
    "air-route",
    "tram-route",
}
REQUIRED_POSTCONDITIONS = {
    "both-worlds-equal",
    "ownership-equal",
    "finance-delta-equal",
    "canonical-checkpoint-converged",
    "native-fingerprint-converged",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def strings(value: Any, label: str, *, allow_empty: bool = False) -> list[str]:
    require(isinstance(value, list), f"{label} must be an array")
    result: list[str] = []
    for index, item in enumerate(value):
        require(isinstance(item, str) and bool(item), f"{label}[{index}] must be a non-empty string")
        require(item not in result, f"{label} contains duplicate {item!r}")
        result.append(item)
    require(allow_empty or bool(result), f"{label} must not be empty")
    return result


def load(path: Path) -> dict[str, Any]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"cannot read {path}: {exc}") from exc
    require(isinstance(document, dict), f"{path} must contain a JSON object")
    return document


def validate(root: Path, path: Path) -> tuple[int, int, int]:
    document = load(path)
    require(document.get("schemaVersion") == 1, "construction corpus schemaVersion must be 1")
    require(document.get("buildProfile") == "Transport Fever 2 Build 35924 (Windows x64)",
            "construction corpus must pin the supported native build")
    required = strings(document.get("requiredCoverage"), "requiredCoverage")
    declared_postconditions = set(strings(
        document.get("physicalPostconditions"), "physicalPostconditions"))
    require(declared_postconditions == REQUIRED_POSTCONDITIONS,
            "physicalPostconditions must contain the complete two-world proof contract")

    matrices = document.get("matrices")
    require(isinstance(matrices, list) and bool(matrices), "matrices must be a non-empty array")
    matrix_ids: set[str] = set()
    matrix_cases = 0
    for index, matrix in enumerate(matrices):
        require(isinstance(matrix, dict), f"matrices[{index}] must be an object")
        matrix_id = matrix.get("id")
        require(isinstance(matrix_id, str) and bool(matrix_id), f"matrices[{index}].id is invalid")
        require(matrix_id not in matrix_ids, f"duplicate matrix id {matrix_id!r}")
        matrix_ids.add(matrix_id)
        executor = matrix.get("executor")
        require(isinstance(executor, str) and (root / executor).is_file(),
                f"matrix {matrix_id!r} executor is missing: {executor!r}")
        expected = matrix.get("expectedCases")
        require(isinstance(expected, int) and expected > 0,
                f"matrix {matrix_id!r} expectedCases must be positive")
        dimensions = matrix.get("dimensions")
        if dimensions is not None:
            require(isinstance(dimensions, dict) and bool(dimensions),
                    f"matrix {matrix_id!r} dimensions must be an object")
            cardinality = 1
            for name, values in dimensions.items():
                require(isinstance(name, str) and bool(name),
                        f"matrix {matrix_id!r} has an invalid dimension name")
                require(isinstance(values, list) and bool(values),
                        f"matrix {matrix_id!r} dimension {name!r} is empty")
                cardinality *= len(values)
            require(cardinality == expected,
                    f"matrix {matrix_id!r} product {cardinality} != expectedCases {expected}")
        matrix_cases += expected

    cases = document.get("cases")
    require(isinstance(cases, list) and bool(cases), "cases must be a non-empty array")
    case_ids: set[str] = set()
    coverage: set[str] = set()
    live_cases = 0
    for index, case in enumerate(cases):
        require(isinstance(case, dict), f"cases[{index}] must be an object")
        case_id = case.get("id")
        require(isinstance(case_id, str) and bool(case_id), f"cases[{index}].id is invalid")
        require(case_id not in case_ids, f"duplicate case id {case_id!r}")
        case_ids.add(case_id)
        tier = case.get("tier")
        require(tier in {"static", "localhost", "localhost-optional", "external-optional"},
                f"case {case_id!r} has invalid tier {tier!r}")
        proof_scope = case.get("proofScope")
        if proof_scope is not None:
            require(isinstance(proof_scope, str) and bool(proof_scope),
                    f"case {case_id!r} proofScope must be a non-empty string")
        case_coverage = strings(case.get("coverage"), f"case {case_id!r} coverage")
        coverage.update(case_coverage)
        executor = case.get("executor")
        require(isinstance(executor, dict), f"case {case_id!r} executor must be an object")
        kind = executor.get("kind")
        if kind == "lua":
            executor_path = executor.get("path")
            require(isinstance(executor_path, str) and (root / executor_path).is_file(),
                    f"case {case_id!r} Lua executor is missing: {executor_path!r}")
            require(tier == "static", f"case {case_id!r} Lua executor must be static")
        elif kind == "localhost-slice":
            slice_name = executor.get("slice")
            require(slice_name in LIVE_SLICES,
                    f"case {case_id!r} names unsupported localhost slice {slice_name!r}")
            require(tier in {"localhost", "localhost-optional"},
                    f"case {case_id!r} localhost executor has incompatible tier")
            postconditions = set(strings(case.get("postconditions"),
                                         f"case {case_id!r} postconditions"))
            require(postconditions == REQUIRED_POSTCONDITIONS,
                    f"case {case_id!r} lacks the complete two-world postcondition contract")
            active_mods = executor.get("activeMods", [])
            strings(active_mods, f"case {case_id!r} activeMods", allow_empty=True)
            live_cases += 1
        elif kind == "extension-manifest":
            require(tier == "external-optional",
                    f"case {case_id!r} extension executor must be external-optional")
        else:
            raise ValueError(f"case {case_id!r} has unknown executor kind {kind!r}")

    missing = sorted(set(required) - coverage)
    unknown = sorted(coverage - set(required))
    require(not missing, "required construction coverage is undeclared: " + ", ".join(missing))
    require(not unknown, "construction cases use unknown coverage: " + ", ".join(unknown))
    require(live_cases >= 7, "construction corpus must retain all core two-instance slices")
    return len(cases), live_cases, matrix_cases


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path,
                        default=Path(__file__).resolve().parents[1])
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--check", action="store_true",
                        help="accepted for consistency with generated-policy validators")
    args = parser.parse_args()
    root = args.project_root.resolve()
    path = (args.manifest or root / "content" / "construction-corpus-v1.json").resolve()
    cases, live, matrix_cases = validate(root, path)
    print(f"construction_corpus_valid=true cases={cases} "
          f"live_declared={live} static_matrix_cases_declared={matrix_cases}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
