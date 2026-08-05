from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Mapping

from .protocol import decode_line, validate_envelope


def latest_research(bridge_root: Path | str, session: str) -> dict[str, Any]:
    outbox = Path(bridge_root).expanduser().resolve() / "game_outbox"
    selected: dict[str, Any] | None = None
    selected_key = (-1, -1)
    for path in outbox.glob("*.json"):
        try:
            message = decode_line(path.read_bytes())
            validate_envelope(message, session)
            sequence = int(message.get("local_seq", -1))
            candidate_key = (path.stat().st_mtime_ns, sequence)
        except (OSError, TypeError, ValueError):
            continue
        if message.get("kind") == "research" and candidate_key > selected_key:
            payload = message.get("payload")
            if isinstance(payload, dict):
                selected = payload
                selected_key = candidate_key
    if selected is None:
        raise ValueError(f"no research export for session {session!r} in {outbox}")
    return selected


def _value(value: Any) -> str:
    if isinstance(value, bool):
        return "yes" if value else "no"
    if value is None:
        return "unknown"
    return str(value)


def _tag_summary(value: Any) -> str:
    if not isinstance(value, list) or not value:
        return "none"
    parts: list[str] = []
    for entry in value:
        if isinstance(entry, Mapping):
            parts.append(f"{_value(entry.get('name'))}={_value(entry.get('count'))}")
    return ", ".join(parts) or "none"


def render_markdown(report: Mapping[str, Any]) -> str:
    capabilities = report.get("capabilities", {})
    structural = report.get("structural", {})
    ownership = report.get("ownership", {})
    capture = report.get("capture", {})
    gui_capabilities = report.get("guiCapabilities", {})
    native_hook = report.get("nativeHook", {})
    mobility = report.get("mobility", {})
    match = report.get("match", {})
    checkpoint = report.get("checkpoint", {})
    proposals = report.get("proposals", {})
    consensus = report.get("proposalConsensus", {})
    checkpoint_consensus = report.get("checkpointConsensus", {})
    lines = [
        "# TPF2MP runtime investigation report",
        "",
        f"- Session: `{_value(report.get('sessionId'))}`",
        f"- Peer: `{_value(report.get('peerId'))}`",
        f"- Mode: `{_value(report.get('networkMode'))}`",
        f"- Engine tick: `{_value(report.get('tick'))}`",
            f"- Structural digest: `{_value(structural.get('digest'))}`",
            f"- Model/core digest: `{_value(report.get('modelDigest'))}` / `{_value(report.get('coreDigest'))}`",
            f"- Match: `{_value(match.get('status') if isinstance(match, Mapping) else None)}`; "
            f"winner `{_value(match.get('winnerCid') if isinstance(match, Mapping) else None)}`",
            f"- Baseline checkpoints exported: `{_value(checkpoint.get('exports') if isinstance(checkpoint, Mapping) else None)}`",
        "",
        "## Capability probe",
        "",
        "| Capability | Result |",
        "|---|---:|",
    ]
    if isinstance(capabilities, Mapping):
        for key in sorted(capabilities):
            lines.append(f"| `{key}` | {_value(capabilities[key])} |")

    lines.extend(["", "## GUI-state capability probe", "", "| Capability | Result |", "|---|---:|"])
    if isinstance(gui_capabilities, Mapping) and gui_capabilities:
        for key in sorted(gui_capabilities):
            lines.append(f"| `{key}` | {_value(gui_capabilities[key])} |")
    else:
        lines.append("| _not reported_ | unknown |")

    lines.extend(
        [
            "",
            "## World inventory",
            "",
            f"- Towns: {_value(len(structural.get('towns', [])) if isinstance(structural, Mapping) else None)}",
            f"- Lines: {_value(len(structural.get('lines', [])) if isinstance(structural, Mapping) else None)}",
            f"- Vehicles: {_value(structural.get('vehicleCount') if isinstance(structural, Mapping) else None)}",
            f"- Depots: {_value(structural.get('depotCount') if isinstance(structural, Mapping) else None)}",
            f"- Constructions: {_value(structural.get('constructionCount') if isinstance(structural, Mapping) else None)}",
            "",
            "## Native hook and mobility",
            "",
            f"- Hook available/active: {_value(native_hook.get('available') if isinstance(native_hook, Mapping) else None)} / "
            f"{_value(native_hook.get('active') if isinstance(native_hook, Mapping) else None)}",
            f"- Hook stage: `{_value(native_hook.get('stage') if isinstance(native_hook, Mapping) else None)}`",
            f"- Hook version: `{_value(native_hook.get('hookVersion') if isinstance(native_hook, Mapping) else None)}`",
            f"- Hook profile: `{_value(native_hook.get('profile') if isinstance(native_hook, Mapping) else None)}`",
            f"- Exact-build validation/signatures: "
            f"{_value(native_hook.get('validation', {}).get('valid') if isinstance(native_hook, Mapping) and isinstance(native_hook.get('validation'), Mapping) else None)} / "
            f"{_value(native_hook.get('validation', {}).get('signatureCount') if isinstance(native_hook, Mapping) and isinstance(native_hook.get('validation'), Mapping) else None)}",
            f"- Setup calls / Lua states / wrapped states / forwarded commands: "
            f"{_value(native_hook.get('setupCalls') if isinstance(native_hook, Mapping) else None)} / "
            f"{_value(native_hook.get('luaStateCount') if isinstance(native_hook, Mapping) else None)} / "
            f"{_value(native_hook.get('wrappedStateCount') if isinstance(native_hook, Mapping) else None)} / "
            f"{_value(native_hook.get('commandCalls') if isinstance(native_hook, Mapping) else None)}",
            f"- Native pre-issue observer states: "
            f"{_value(native_hook.get('commandObserverStateCount') if isinstance(native_hook, Mapping) else None)}",
            f"- Native queue swaps / non-empty batches / commands: "
            f"{_value(native_hook.get('commandList', {}).get('swapCalls') if isinstance(native_hook, Mapping) and isinstance(native_hook.get('commandList'), Mapping) else None)} / "
            f"{_value(native_hook.get('commandList', {}).get('nonEmptyBatches') if isinstance(native_hook, Mapping) and isinstance(native_hook.get('commandList'), Mapping) else None)} / "
            f"{_value(native_hook.get('commandList', {}).get('commands') if isinstance(native_hook, Mapping) and isinstance(native_hook.get('commandList'), Mapping) else None)}",
            f"- Applied commands succeeded / failed / unknown: "
            f"{_value(native_hook.get('applyCommand', {}).get('succeeded') if isinstance(native_hook, Mapping) and isinstance(native_hook.get('applyCommand'), Mapping) else None)} / "
            f"{_value(native_hook.get('applyCommand', {}).get('failed') if isinstance(native_hook, Mapping) and isinstance(native_hook.get('applyCommand'), Mapping) else None)} / "
            f"{_value(native_hook.get('applyCommand', {}).get('unknown') if isinstance(native_hook, Mapping) and isinstance(native_hook.get('applyCommand'), Mapping) else None)}",
            f"- Direct engine-state applies (queue bypass): "
            f"{_value(native_hook.get('applyCommand', {}).get('direct') if isinstance(native_hook, Mapping) and isinstance(native_hook.get('applyCommand'), Mapping) else None)}",
            f"- Queued command tags: "
            f"{_tag_summary(native_hook.get('commandList', {}).get('tagCounts') if isinstance(native_hook, Mapping) and isinstance(native_hook.get('commandList'), Mapping) else None)}",
            f"- Applied command tags: "
            f"{_tag_summary(native_hook.get('applyCommand', {}).get('tagCounts') if isinstance(native_hook, Mapping) and isinstance(native_hook.get('applyCommand'), Mapping) else None)}",
            f"- Retained native command timeline entries: "
            f"{_value(len(native_hook.get('commandEvents', [])) if isinstance(native_hook, Mapping) and isinstance(native_hook.get('commandEvents'), list) else None)}",
            f"- Vehicle capture queued / captured / consumed / invalid / dropped: "
            f"{_value(native_hook.get('suppressedVehicleCommands', {}).get('queued') if isinstance(native_hook, Mapping) and isinstance(native_hook.get('suppressedVehicleCommands'), Mapping) else None)} / "
            f"{_value(native_hook.get('suppressedVehicleCommands', {}).get('captured') if isinstance(native_hook, Mapping) and isinstance(native_hook.get('suppressedVehicleCommands'), Mapping) else None)} / "
            f"{_value(native_hook.get('suppressedVehicleCommands', {}).get('consumed') if isinstance(native_hook, Mapping) and isinstance(native_hook.get('suppressedVehicleCommands'), Mapping) else None)} / "
            f"{_value(native_hook.get('suppressedVehicleCommands', {}).get('invalid') if isinstance(native_hook, Mapping) and isinstance(native_hook.get('suppressedVehicleCommands'), Mapping) else None)} / "
            f"{_value(native_hook.get('suppressedVehicleCommands', {}).get('dropped') if isinstance(native_hook, Mapping) and isinstance(native_hook.get('suppressedVehicleCommands'), Mapping) else None)}",
            f"- BuildProposal gate enabled / suppressed / authorized-through: "
            f"{_value(native_hook.get('gates', {}).get('buildProposal', {}).get('enabled') if isinstance(native_hook, Mapping) and isinstance(native_hook.get('gates'), Mapping) and isinstance(native_hook.get('gates', {}).get('buildProposal'), Mapping) else None)} / "
            f"{_value(native_hook.get('gates', {}).get('buildProposal', {}).get('suppressed') if isinstance(native_hook, Mapping) and isinstance(native_hook.get('gates'), Mapping) and isinstance(native_hook.get('gates', {}).get('buildProposal'), Mapping) else None)} / "
            f"{_value(native_hook.get('gates', {}).get('buildProposal', {}).get('allowed') if isinstance(native_hook, Mapping) and isinstance(native_hook.get('gates'), Mapping) and isinstance(native_hook.get('gates', {}).get('buildProposal'), Mapping) else None)}",
            f"- Consequential command visitors enabled / hooked / suppressed / authorized-through / mismatches: "
            f"{_value(native_hook.get('gates', {}).get('commandVisitors', {}).get('enabled') if isinstance(native_hook, Mapping) and isinstance(native_hook.get('gates'), Mapping) and isinstance(native_hook.get('gates', {}).get('commandVisitors'), Mapping) else None)} / "
            f"{_value(native_hook.get('gates', {}).get('commandVisitors', {}).get('hooked') if isinstance(native_hook, Mapping) and isinstance(native_hook.get('gates'), Mapping) and isinstance(native_hook.get('gates', {}).get('commandVisitors'), Mapping) else None)} / "
            f"{_value(native_hook.get('gates', {}).get('commandVisitors', {}).get('suppressedTotal') if isinstance(native_hook, Mapping) and isinstance(native_hook.get('gates'), Mapping) and isinstance(native_hook.get('gates', {}).get('commandVisitors'), Mapping) else None)} / "
            f"{_value(native_hook.get('gates', {}).get('commandVisitors', {}).get('allowedTotal') if isinstance(native_hook, Mapping) and isinstance(native_hook.get('gates'), Mapping) and isinstance(native_hook.get('gates', {}).get('commandVisitors'), Mapping) else None)} / "
            f"{_value(native_hook.get('gates', {}).get('commandVisitors', {}).get('tagMismatches') if isinstance(native_hook, Mapping) and isinstance(native_hook.get('gates'), Mapping) and isinstance(native_hook.get('gates', {}).get('commandVisitors'), Mapping) else None)}",
            f"- Hook scope: {_value(native_hook.get('scope') if isinstance(native_hook, Mapping) else None)}",
            f"- Mobility digest: `{_value(mobility.get('digest') if isinstance(mobility, Mapping) else None)}`",
            f"- Vehicle lifecycle / route-phase digests: "
            f"`{_value(mobility.get('vehicleLifecycleDigest') if isinstance(mobility, Mapping) else None)}` / "
            f"`{_value(mobility.get('vehiclePhaseDigest') if isinstance(mobility, Mapping) else None)}`",
            f"- Native total persons: {_value(mobility.get('totalPersons') if isinstance(mobility, Mapping) else None)}",
            f"- Passenger/cargo line uses: "
            f"{_value(mobility.get('totals', {}).get('passengerLineUses') if isinstance(mobility, Mapping) and isinstance(mobility.get('totals'), Mapping) else None)} / "
            f"{_value(mobility.get('totals', {}).get('cargoLineUses') if isinstance(mobility, Mapping) and isinstance(mobility.get('totals'), Mapping) else None)}",
            "",
            "## Logical ownership",
            "",
        ]
    )
    companies = ownership.get("companies", {}) if isinstance(ownership, Mapping) else {}
    if isinstance(companies, Mapping) and companies:
        for company_id in sorted(companies):
            company = companies[company_id]
            by_kind = company.get("byKind", {}) if isinstance(company, Mapping) else {}
            detail = ", ".join(f"{key}={by_kind[key]}" for key in sorted(by_kind)) or "none"
            lines.append(f"- `{company_id}`: {company.get('total', 0)} assets ({detail})")
    else:
        lines.append("- No company-owned entities were observed.")
    ownership_errors = ownership.get("errors", []) if isinstance(ownership, Mapping) else []
    if isinstance(ownership_errors, list):
        lines.extend(f"- Ownership enumeration error: `{item}`" for item in ownership_errors)
    pinned = ownership.get("pinned", {}) if isinstance(ownership, Mapping) else {}
    if isinstance(pinned, Mapping):
        lines.append(
            f"- Pinned turn-desk custody: {_value(pinned.get('total'))} "
            "(logical company ownership retained; native edit custody/maintenance is pooled and may hit the active wallet)"
        )

    lines.extend(
        [
            "",
            "## Native capture evidence",
            "",
            f"- BuildProposal GUI/native/apply events: {_value(capture.get('preCommitCount'))} / "
            f"{_value(capture.get('nativePreCommitCount'))} / {_value(capture.get('postCommitCount'))}",
            f"- Vehicle accept/resolve events: {_value(capture.get('vehicleIntentCount'))} / {_value(capture.get('vehicleResolvedCount'))}",
            f"- Claimed entities: {_value(capture.get('claimedCount'))}",
            f"- Edge replacement transactions/rebound edges/failures: "
            f"{_value(capture.get('replacementObservedCount'))} / "
            f"{_value(capture.get('replacementReboundCount'))} / "
            f"{_value(capture.get('replacementFailureCount'))}",
            f"- Canonical proposals queued/applied/failed/retained: "
            f"{_value(proposals.get('queued') if isinstance(proposals, Mapping) else None)} / "
            f"{_value(proposals.get('applied') if isinstance(proposals, Mapping) else None)} / "
            f"{_value(proposals.get('failed') if isinstance(proposals, Mapping) else None)} / "
            f"{_value(proposals.get('retained') if isinstance(proposals, Mapping) else None)}",
            f"- Physical consensus completed/faulted/session fault: "
            f"{_value(consensus.get('completed') if isinstance(consensus, Mapping) else None)} / "
            f"{_value(consensus.get('failed') if isinstance(consensus, Mapping) else None)} / "
            f"{_value(consensus.get('sessionFault') if isinstance(consensus, Mapping) else None)}",
            f"- Checkpoint barriers completed/faulted/last agreed: "
            f"{_value(checkpoint_consensus.get('completed') if isinstance(checkpoint_consensus, Mapping) else None)} / "
            f"{_value(checkpoint_consensus.get('failed') if isinstance(checkpoint_consensus, Mapping) else None)} / "
            f"{_value(checkpoint_consensus.get('lastAgreed') if isinstance(checkpoint_consensus, Mapping) else None)}",
            "",
            "## Known limits recorded by the mod",
            "",
        ]
    )
    limits = report.get("knownLimits", [])
    if isinstance(limits, list) and limits:
        lines.extend(f"- {item}" for item in limits)
    else:
        lines.append("- None recorded.")

    shapes = capture.get("eventShapes", []) if isinstance(capture, Mapping) else []
    if isinstance(shapes, list) and shapes:
        lines.extend(
            [
                "",
                "## Latest observed GUI event shapes",
                "",
                "```json",
                json.dumps(shapes[-5:], ensure_ascii=False, indent=2, sort_keys=True),
                "```",
            ]
        )
    proposal_snapshot = capture.get("lastProposalSnapshot") if isinstance(capture, Mapping) else None
    if isinstance(proposal_snapshot, Mapping):
        lines.extend(
            [
                "",
                "## Latest bounded proposal snapshot",
                "",
                "This diagnostic projection excludes userdata addresses and is retained outside the event/audit tail.",
                "",
                "```json",
                json.dumps(proposal_snapshot, ensure_ascii=False, indent=2, sort_keys=True),
                "```",
            ]
        )
    replacement = capture.get("lastReplacement") if isinstance(capture, Mapping) else None
    if isinstance(replacement, Mapping):
        lines.extend(
            [
                "",
                "## Latest edge replacement migration",
                "",
                "```json",
                json.dumps(replacement, ensure_ascii=False, indent=2, sort_keys=True),
                "```",
            ]
        )
    proposal_snapshots = capture.get("proposalSnapshots", []) if isinstance(capture, Mapping) else []
    if isinstance(proposal_snapshots, list) and len(proposal_snapshots) > 1:
        lines.extend(
            [
                "",
                "## Recent bounded proposal snapshots",
                "",
                "The bounded ring preserves up to eight previews/applies so an empty post-build cursor proposal cannot erase the useful sample.",
                "",
                "```json",
                json.dumps(proposal_snapshots, ensure_ascii=False, indent=2, sort_keys=True),
                "```",
            ]
        )
    lines.append("")
    return "\n".join(lines)


def write_report(bridge_root: Path | str, session: str, output: Path | str) -> dict[str, Any]:
    report = latest_research(bridge_root, session)
    target = Path(output).expanduser().resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(render_markdown(report), encoding="utf-8")
    return report
