# Native save-menu hang during UI qualification

Status: investigated, not fixed or attributed conclusively. This is separate
from construction or transport acceptance. No user saves were removed, hidden,
rewritten or used as a workaround.

## Reproductions

`localhost-ui-20260906-115016-78cc5c`: P1 PID 21688 stopped responding after
the native Load Game click. CPU usage stopped increasing at 14.484375 seconds.
The 120-second loader deadline expired before any gameplay case; P2 never
started. The supervisor retained a screenshot and external stack-only dump,
then closed its exact processes and restored all six disposable settings.

`localhost-ui-20260906-115434-317b15`: P1 PID 39656 loaded successfully; P2
PID 53124 hit the same native page deadline. Again no gameplay cases ran and
all cleanup checks passed. These failed attempts remain in the record.

`localhost-ui-20260906-120243-ad46ee`: the next pair loaded successfully.
Both stations and a real connecting-track preview passed. The subsequent track
commit reached a fresh checkpoint but a mistaken recipe arithmetic path
(`counts.edges` rather than `counts.edges.edge`) failed its test oracle. This
is failed calibration, not a loader or gameplay PASS for the complete route.
The assertion was corrected for a fresh pair. Arithmetic evidence types are
now preflighted before input; six regression tests cover that guard.

## New dump evidence

The external P1 dump from `115016-78cc5c` has no exception stream. A local,
read-only C++ diagnostic used Windows SDK CONTEXT/STACKFRAME64 and StackWalk64,
with custom memory and runtime-function callbacks. Runtime-function entries
come from each exact local PE's exception directory; PE image size and timestamp
must match the dump module before disk bytes are used. Stack/register bytes
come only from the dump. This is actual PE-guided unwind, not a scan for values
that happen to point into code. Initial output without the custom function
table callback was invalid and is not evidence.

The retained valid unwind shows:

- Thread 49136: native game `+0x9c50dd` -> `+0x26aef54` -> `+0x26af060`
  -> a Windows wait. Its caller chain also includes the native save reader.
- Thread 7176: native game `+0x26ae027` -> `+0x26af34f` -> dbgcore frames
  (`+0x75e1`, `+0x69da`, `+0x14225`, `+0x1365a`, `+0xcf56`) ->
  `gameoverlayrenderer64.dll+0xad173` -> `KERNELBASE!LoadLibraryExW+0xe0`
  -> ntdll loader frames -> `ZwWaitForAlertByThreadId+0x14`.
- Several native Lua save-parser threads and the UI thread are stopped at
  ordinary instructions rather than cooperative wait sites.

This supports investigating an in-process native dump/Steam-overlay loader
lock interaction. It does **not** prove the original error that requested the
dump, blame MinHook's freeze/unfreeze, or establish a safe game patch.
Voluntary native dumps also occurred during successful loads (P2 PID 31616 in
the following run continued to load and play). A `.dmp` file by itself therefore
does not prove that game process crashed.

## Follow-up needed

Identify the native dump request's original message and compare equivalent
launches with/without Steam overlay and native hook. Do not disable error
reporting or suppress native assertions to make tests green. Any overlay A/B
must be confined to disposable test launches and report the effective modules;
an environment hint is not proof the overlay DLL was absent.

The unqualified local diagnostic sources are under `runtime/dump-unwind/`;
no new driver, debugger installation, live process patch or remote upload was
used. The actual dump remains in the corresponding run's
`native-save-load-player1/load-page-timeout.dmp`.
