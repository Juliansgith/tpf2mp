"""Fail-closed bilateral postconditions. Equal worlds alone are never build proof."""
import math


def finite_number(value):
    return type(value) in (int, float) and math.isfinite(value)


def validate_before_input(before, expect):
    """Reject invalid arithmetic evidence paths before issuing any physical input."""
    for peer in ('player1', 'player2'):
        for check in expect.get('checks', []):
            if check['op'] not in ('delta', 'deltaAtLeast'):
                continue
            value = at(before[peer], check['path'])
            if not finite_number(value):
                raise ValueError(f"{peer}: delta evidence must be numeric before input: {check['path']}")
class Pending(AssertionError):
    pass


class GameFault(AssertionError):
    pass


class PhysicalRejection(AssertionError):
    pass


def at(value, path):
    for key in path:
        try:
            value = value[key]
        except (KeyError, IndexError, TypeError):
            raise Pending(f"missing evidence field: {path}") from None
    return value


def need(condition, reason):
    if not condition:
        raise Pending(reason)


def agreed(pair):
    for peer, data in pair.items():
        snap = at(data, ["snapshot"])
        for family in ("proposalConsensus", "operationConsensus", "checkpointConsensus"):
            fault = at(snap, [family]).get("sessionFault")
            if fault:
                raise GameFault(f"{peer}: {fault}")
        fault = snap.get("bridge", {}).get("companion", {}).get("sessionFault")
        if fault or snap.get("match", {}).get("status") == "faulted":
            raise GameFault(f"{peer}: {fault or 'match faulted'}")
        need(data.get("busy") is False and snap.get("initialized") is True, f"{peer} still busy")
        need(at(data, ["native", "inventoryComplete"]) is True, f"{peer} native inventory unavailable")
        need(snap.get("deferredNetworkQueue", {}).get("count") == 0, f"{peer} deferred work")
        need(not snap.get("deferredNetworkQueue", {}).get("awaitingOrder"), f"{peer} awaiting order")
    a, b = pair["player1"], pair["player2"]
    for path in (["snapshot", "digest"], ["snapshot", "modelDigest"], ["native", "digest"]):
        av, bv = at(a, path), at(b, path)
        need(bool(av) and av == bv, f"bilateral mismatch: {path}: {av} / {bv}")
    ca = at(a, ["snapshot", "checkpointConsensus", "lastAgreed"])
    cb = at(b, ["snapshot", "checkpointConsensus", "lastAgreed"])
    need(ca and cb and ca.get("boundarySeq") == cb.get("boundarySeq")
         and type(ca.get("boundarySeq")) is int and ca["boundarySeq"] > 0, "no common agreed checkpoint")
    for company in ("company:1", "company:2"):
        need(at(a, ["snapshot", "companies", company, "balance"]) == at(b, ["snapshot", "companies", company, "balance"]), "company balances differ")


def objects(data, kind):
    return {cid: v for cid, v in at(data, ["bindings"]).items()
            if v.get("kind") == kind and v.get("exists") is True}


def verify(before, after, expect):
    agreed(after)
    outcome = expect["outcome"]
    for peer in ("player1", "player2"):
        old, new = before[peer], after[peer]
        if outcome != "unchanged":
            old_capture = at(old, ["snapshot", "probes", "capture"])
            capture = at(new, ["snapshot", "probes", "capture"])
            old_count, count = old_capture.get("proposalCodecFailureCount"), capture.get("proposalCodecFailureCount")
            need(type(old_count) is int and type(count) is int and 0 <= old_count <= count,
                 f"{peer}: missing or reset native capture rejection counter")
            if count > old_count:
                raise PhysicalRejection(f"{peer}: capture rejected this case: {capture.get('lastProposalCodecFailure')}")
            boundary = at(old, ["snapshot", "checkpointConsensus", "lastAgreed", "boundarySeq"])
            for family in ("proposalConsensus", "operationConsensus"):
                result = at(new, ["snapshot", family]).get("lastOutcome") or {}
                seq = result.get("commitSeq")
                if type(seq) is int and seq > boundary and result.get("success") is False:
                    raise PhysicalRejection(f"{peer}: {family} rejected this case's operation "
                                            f"at commit {seq}: {result.get('errorCode', 'native rejection')}")
        if outcome == "changed":
            need(at(old, ["native", "digest"]) != at(new, ["native", "digest"]), "no physical change")
            need(at(new, ["snapshot", "checkpointConsensus", "lastAgreed", "boundarySeq"])
                 > at(old, ["snapshot", "checkpointConsensus", "lastAgreed", "boundarySeq"]),
                 "operation has not reached a fresh checkpoint")
        if outcome == "unchanged":
            for path in (["native", "digest"], ["snapshot", "modelDigest"]):
                need(at(old, path) == at(new, path), f"{peer} unexpected mutation")
        elif outcome in ("built", "deleted"):
            previous, current = objects(old, expect["kind"]), objects(new, expect["kind"])
            changed = set(current) - set(previous) if outcome == "built" else set(previous) - set(current)
            need(len(changed) == expect.get("count", 1), f"{peer}: expected {expect.get('count', 1)} {outcome} {expect['kind']}, observed {len(changed)}")
            category = ("edges" if expect["kind"] in ("edge", "edge_object") else
                        "vehicles" if expect["kind"] in ("vehicle", "line") else "constructions")
            inventory_path = ["native", "inventory", "counts", category, expect["kind"]]
            inventory_delta = at(new, inventory_path) - at(old, inventory_path)
            expected_delta = expect.get("inventoryDelta", expect.get("count", 1) * (1 if outcome == "built" else -1))
            need(inventory_delta == expected_delta, f"{peer}: native {expect['kind']} inventory changed by {inventory_delta}, expected {expected_delta}")
            if outcome == "built":
                # Existence in native inventory AND binding identity are required.
                need(at(old, ["native", "digest"]) != at(new, ["native", "digest"]), "no physical change")
                for cid in changed:
                    if "owner" in expect:
                        meta = current[cid].get("metadata") or {}
                        need(meta.get("owner") == expect["owner"], f"{cid}: incorrect/missing ownership")
            need(at(new, ["snapshot", "checkpointConsensus", "lastAgreed", "boundarySeq"])
                 > at(old, ["snapshot", "checkpointConsensus", "lastAgreed", "boundarySeq"]), "operation has not reached a fresh checkpoint")
        for company, policy in expect.get("finance", {}).items():
            path = ["snapshot", "companies", company, "balance"]
            delta = at(new, path) - at(old, path)
            need({"debit": delta < 0, "credit": delta > 0, "unchanged": delta == 0}[policy], f"{peer}: {company} expected {policy}, got {delta}")
        for check in expect.get("checks", []):
            value = at(new, check["path"])
            if check["op"] == "length":
                need(isinstance(value, (list, dict, str)), "length check requires a collection")
                value = len(value)
            if check["op"] in ("delta", "deltaAtLeast"):
                if not finite_number(value) or not finite_number(at(old, check['path'])):
                    raise ValueError(f"{peer}: delta evidence must remain numeric: {check['path']}")
                value -= at(old, check["path"])
            if check['op'] in ('atLeast', 'deltaAtLeast') and not finite_number(value):
                raise ValueError(f"{peer}: lower-bound evidence must be numeric: {check['path']}")
            need(value >= check["value"] if check["op"] in ("atLeast", "deltaAtLeast") else value == check["value"], f"{peer}: postcondition {check}, observed {value}")
