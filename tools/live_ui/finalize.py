"""An inner gameplay PASS is provisional until the outer audit/cleanup passes."""
from pathlib import Path
from .runner import read_json, write_json, Runner

CLEANUP_FLAGS = ('settingsRestored', 'steamMarkerRestored', 'temporaryBootstrapRemoved',
                 'temporaryGameScriptRemoved', 'temporaryLibraryRemoved', 'temporaryStartingSaveRemoved')


def finalize(report_path, status_path, processes_closed):
    report_path = Path(report_path)
    if not report_path.exists():
        return False  # Loader failure is not gameplay evidence.
    report = read_json(report_path)
    provisional_pass = report.get('passed') is True
    report['uiCasesPassed'] = bool(report.get('cases')) and all(
        item.get('status') == 'PASS' for item in report['cases'])
    try:
        status = read_json(status_path)
        valid = (status.get('session') == report.get('session') and status.get('passed') is True
                 and all(status.get(k) is True for k in CLEANUP_FLAGS) and processes_closed
                 and report.get('shutdownSettled') is True)
        reason = status.get('failure') or 'supervisor audit, pause or cleanup was not proven'
    except (OSError, ValueError) as exc:
        valid, reason = False, f'supervisor receipt unavailable: {exc}'
    report['supervisorVerified'] = bool(valid)
    report['passed'] = provisional_pass and report['uiCasesPassed'] and bool(valid)
    if not valid:
        report['error'] = report.get('error') or reason
    write_json(report_path, report)
    runner = object.__new__(Runner)
    runner.output, runner.results = report_path.parent, report['cases']
    runner.junit(report)
    return report['passed']
