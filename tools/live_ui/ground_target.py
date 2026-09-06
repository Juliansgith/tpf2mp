"""Bounded physical-cursor calibration on terrain; never clicks or edits a world.

Not a projection for elevated bridge/roof objects. The adapter must supply fresh
cursor/terrain readbacks from the foreground game and log every physical move.
"""
import math


class TargetingError(ValueError):
    pass


def locate(target, sample, *, initial=(.5, .4), bounds=(.06, .06, .94, .76),
           tolerance=.15, max_reads=32):
    def vector(value, size):
        return (isinstance(value, (tuple, list)) and len(value) == size
                and all(type(v) in (float, int) and math.isfinite(v) for v in value))
    if (not vector(target, 2) or not vector(initial, 2) or not vector(bounds, 4)
            or not 0 < bounds[0] < bounds[2] < 1 or not 0 < bounds[1] < bounds[3] < 1
            or type(tolerance) not in (float, int) or not .01 <= tolerance <= 1
            or type(max_reads) is not int or not 4 <= max_reads <= 48):
        raise TargetingError('invalid bounded ground-target request')
    reads = []
    def inside(p):
        return bounds[0] <= p[0] <= bounds[2] and bounds[1] <= p[1] <= bounds[3]
    def query(point):
        if not inside(point): raise TargetingError('ground target left the usable viewport')
        if len(reads) >= max_reads: raise TargetingError('ground targeting read budget exhausted')
        value = sample(tuple(point))
        if not vector(value, 3): raise TargetingError('fresh finite native terrain position unavailable')
        reads.append({'point': list(point), 'world': list(value)})
        return value
    point = list(initial)
    while True:
        current = query(point)
        error = [target[i] - current[i] for i in range(2)]
        if math.hypot(*error) <= tolerance:
            confirmation = query(point)
            if math.hypot(*(target[i] - confirmation[i] for i in range(2))) <= tolerance:
                return {'point': point, 'world': list(confirmation), 'samples': reads}
            raise TargetingError('terrain cursor changed without a physical move')
        probes = []
        for axis in range(2):
            step = .025 if point[axis] + .025 <= bounds[axis + 2] else -.025
            offset = point.copy(); offset[axis] += step
            value = query(offset)
            probes.append([(value[i] - current[i]) / step for i in range(2)])
        a, c = probes[0]; b, d = probes[1]
        determinant = a*d - b*c
        scale = math.hypot(a, c) * math.hypot(b, d)
        if scale < 1e-8 or not math.isfinite(determinant) or abs(determinant) < scale*1e-5:
            raise TargetingError('stale or degenerate terrain cursor samples')
        dx = (d*error[0] - b*error[1]) / determinant
        dy = (-c*error[0] + a*error[1]) / determinant
        distance = math.hypot(dx, dy)
        if not math.isfinite(distance): raise TargetingError('nonfinite targeting correction')
        factor = min(1, .20 / max(distance, 1e-12))
        point = [point[0] + dx*factor, point[1] + dy*factor]
