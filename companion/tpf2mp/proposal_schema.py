from __future__ import annotations

from typing import Any, Mapping

LEGACY_PROPOSAL_SCHEMA_VERSION = 5
PROPOSAL_SCHEMA_VERSION = 6
LEGACY_CONSTRUCTION_PROPOSAL_SCHEMA_VERSION = 7
CONSTRUCTION_PROPOSAL_SCHEMA_VERSION = 8
NAMED_CONSTRUCTION_PROPOSAL_SCHEMA_VERSION = 9
SUPPORTED_PROPOSAL_SCHEMA_VERSIONS = {
    LEGACY_PROPOSAL_SCHEMA_VERSION, PROPOSAL_SCHEMA_VERSION,
    LEGACY_CONSTRUCTION_PROPOSAL_SCHEMA_VERSION, CONSTRUCTION_PROPOSAL_SCHEMA_VERSION,
    NAMED_CONSTRUCTION_PROPOSAL_SCHEMA_VERSION,
}
MAX_PROPOSAL_NODES = 256
MAX_PROPOSAL_EDGES = 256
MAX_PROPOSAL_EDGE_OBJECTS = 256
MAX_CONSTRUCTION_PROPOSAL_NODES = 1024
MAX_CONSTRUCTION_PROPOSAL_EDGES = 1024
MAX_STATION_MODULES = 256
MAX_PROPOSAL_REMOVALS = 512
MAX_CONSTRUCTION_COLLATERAL = 64
MAX_PROPOSAL_OUTPUTS = (
    MAX_CONSTRUCTION_PROPOSAL_NODES
    + MAX_CONSTRUCTION_PROPOSAL_EDGES
    + MAX_PROPOSAL_EDGE_OBJECTS
    + 64
)
TRAM_TRACK_NONE = 0
TRAM_TRACK_PLAIN = 1
TRAM_TRACK_ELECTRIC = 2


def valid_construction_name(construction: Any) -> bool:
    name = construction.get("name") if isinstance(construction, dict) else None
    if not isinstance(name, str) or construction.get("mode") == "remove":
        return False
    try:
        return 0 < len(name.encode("utf-8")) <= 240 and all(ord(char) >= 32 for char in name)
    except UnicodeEncodeError:
        return False


def construction_fields(version: int, construction: Any) -> tuple[set[str], str | None]:
    fields = {"slot", "mode", "adapter", "kind", "sourceCid", "fileName",
              "transform", "params", "modules", "collateral"}
    if version == NAMED_CONSTRUCTION_PROPOSAL_SCHEMA_VERSION:
        fields.add("name")
        if not valid_construction_name(construction):
            return fields, "construction name is invalid"
    return fields, None


def construction_proposal_schema(version: Any) -> bool:
    return version in {
        LEGACY_CONSTRUCTION_PROPOSAL_SCHEMA_VERSION,
        CONSTRUCTION_PROPOSAL_SCHEMA_VERSION,
        NAMED_CONSTRUCTION_PROPOSAL_SCHEMA_VERSION,
    }


def street_features_schema(version: Any) -> bool:
    return version in {PROPOSAL_SCHEMA_VERSION, CONSTRUCTION_PROPOSAL_SCHEMA_VERSION,
                       NAMED_CONSTRUCTION_PROPOSAL_SCHEMA_VERSION}


def street_feature_error(edge: Mapping[str, Any], version: Any) -> str | None:
    if not street_features_schema(version):
        return None
    if not isinstance(edge.get("bus"), bool):
        return "proposal street bus-lane flag must be boolean"
    tram_type = edge.get("tramTrackType")
    if not isinstance(tram_type, int) or isinstance(tram_type, bool):
        return "proposal street tramTrackType must be an integer"
    if not TRAM_TRACK_NONE <= tram_type <= TRAM_TRACK_ELECTRIC:
        return "proposal street tram-track type is outside [0,2]"
    return None
