"""Visible-save preparation through native scrolling, not save selection injection."""
from .desktop import InfrastructureError


def scroll_step(status, expected):
    components = status.get("components", {})
    if (status.get("stage") != "ready-to-click-pinned-save"
            or components.get("expectedSave") != expected or not expected):
        raise InfrastructureError("save page identity changed before scrolling")
    row, clip, view = (components.get(k) for k in ("expectedSaveRect", "expectedSaveClipRect", "menuRect"))
    if not all(isinstance(r, dict) and r.get("w", 0) > 0 and r.get("h", 0) > 0 for r in (row, clip, view)):
        raise InfrastructureError("missing native save scroll viewport")
    x, y = row["x"] + row["w"] / 2, row["y"] + row["h"] / 2
    if clip["x"] < x < clip["x"] + clip["w"] and clip["y"] + 5 < y < clip["y"] + clip["h"] - 5:
        return None
    center = [clip["x"] + clip["w"] / 2, clip["y"] + clip["h"] / 2]
    point = [(center[0] - view["x"]) / view["w"], (center[1] - view["y"]) / view["h"]]
    if not all(0 < v < 1 for v in point):
        raise InfrastructureError("native save scroll viewport is offscreen")
    delta = min(2400, max(120, int(abs(y - center[1]) / 80) * 120))
    return {"action": "wheel", "point": point, "delta": delta if y < center[1] else -delta}
