"""A release can require fresh GUI proof, without confusing mocks with gameplay."""
import hashlib
from pathlib import Path
from .schema import sha256


def source_fingerprint(root):
    root = Path(root)
    digest = hashlib.sha256()
    # Sources, recipes, and harness changes invalidate old receipts. Generated
    # outputs and diagnostic documentation do not. Include dirty source files.
    for folder in ("tpf2_mp_1", "companion/tpf2mp", "native/src", "native/include", "native/third_party", "content", "tools"):
        for path in sorted((root/folder).rglob("*")):
            if path.is_file() and path.suffix.lower() in (".lua", ".py", ".ps1", ".json", ".c", ".cpp", ".hpp", ".h", ".cmake"):
                digest.update(path.relative_to(root).as_posix().encode())
                digest.update(b"\0" + sha256(path).encode() + b"\n")
    for path in sorted((root/'native').rglob('CMakeLists.txt')):
        if any(part in ('build', 'build-release', '_deps') for part in path.relative_to(root/'native').parts):
            continue
        digest.update(path.relative_to(root).as_posix().encode())
        digest.update(b"\0" + sha256(path).encode() + b"\n")
    return digest.hexdigest()


def check_coverage(required, reports, fingerprint):
    covered = set()
    for report in reports:
        if (report.get("proof") != "physical-ui-input" or report.get("passed") is not True
                or report.get('supervisorVerified') is not True):
            raise ValueError("only passing real-UI reports are accepted")
        if report.get("sourceFingerprint") != fingerprint:
            raise ValueError("UI report belongs to different source content; rerun after the change")
        for case in report.get("cases", []):
            if case.get("status") != "PASS":
                raise ValueError("report contains a blocked, failed, or unrun case")
            covered.update(case.get("coverage", []))
    missing = sorted(set(required) - covered)
    if missing:
        raise ValueError("missing real UI coverage: " + ", ".join(missing))
    return sorted(covered)
