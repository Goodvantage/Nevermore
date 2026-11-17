"""Strict SemVer precedence for release snapshot ordering."""
import re

_VERSION = re.compile(
    r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)


def parse_version(tag):
    match = _VERSION.fullmatch(tag)
    if not match:
        raise ValueError(f"Invalid release tag: {tag}")
    parts = tuple(int(value) for value in match.group(1, 2, 3))
    pre = match.group(4)
    if pre is None:
        return parts, None
    identifiers = pre.split(".")
    if any(value.isdigit() and len(value) > 1 and value[0] == "0" for value in identifiers):
        raise ValueError(f"Invalid release tag: {tag}")
    return parts, tuple(int(value) if value.isdigit() else value for value in identifiers)


def compare_versions(a, b):
    left, right = parse_version(a), parse_version(b)
    if left[0] != right[0]:
        return (left[0] > right[0]) - (left[0] < right[0])
    if left[1] is None or right[1] is None:
        return (left[1] is None) - (right[1] is None)
    for x, y in zip(left[1], right[1]):
        if x == y:
            continue
        if isinstance(x, int) != isinstance(y, int):
            return -1 if isinstance(x, int) else 1
        return (x > y) - (x < y)
    return (len(left[1]) > len(right[1])) - (len(left[1]) < len(right[1]))
