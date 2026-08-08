# Permanent service-registration failure quarantine

Date: 2026-08-09 (Europe/Amsterdam)

Prototype: `0.29.0-alpha`

## Finding

Automatic `line.register` is an authored follow-up. It intentionally waits
behind physical actions and checkpoint barriers, then derives portable service
facts on the owning peer. The retry policy previously treated every failure as
a transient bridge outage.

That is incorrect for normalization failures. Examples include:

- both endpoints resolving to the same town (an ordinary local feeder);
- an industry route whose stations do not resolve to two distinct towns;
- a stale/deleted line binding;
- any route shape outside the current passenger-corridor adapter.

Repeating the same derivation cannot repair those facts. The follow-up stayed
queued forever, kept `localWorkPending` true, and therefore made a later
recovery anchor permanently non-quiescent. Physical work had priority and
could still appear usable, which made this a subtle long-session failure.

## Correction

`network_intent_runtime.lua` now distinguishes two failure phases:

- **normalization failure**: the action never reached the bridge;
- **emit failure**: portable data exists, but the bridge write failed.

A failed `line.register` normalization is removed from the follow-up lane and
recorded in the bounded local `probes.serviceRegistration` diagnostic. It is
not represented as a successfully registered service and earns no authored
revenue. The Multiplayer panel and research export expose the line id and
reason.

A later line edit or vehicle assignment schedules a fresh registration. If
facts can then be derived, the new action is emitted normally and clears that
line's current quarantine record. Historical counts remain diagnostic.

Bridge failures still retain their follow-up with bounded retry delay. The
change therefore does not turn a temporary transport outage into lost authored
work.

## Cargo boundary

This fix deliberately does not call an industry route a passenger corridor.
The present real-line binder is town-pair/passenger-specific. The generic
economy can replay synthetic cargo markets and unit-kilometre revenue, and the
native telemetry can observe cargo, but a real freight service still needs:

1. cargo/passenger classification from station and consist facts;
2. canonical industry/source/sink identity and recipe binding;
3. authored supply, demand, inventory, and transfer scarcity;
4. the same synchronized queue/load/completed-delivery ledger passengers use;
5. cargo-positive two-process proof.

Until that exists, quarantining an unsupported freight registration is more
honest and safer than either retrying forever or paying it as passenger demand.

## Automated evidence

The runtime test forces a same-town-style normalization error and proves:

- no bridge envelope is written;
- the authored follow-up queue becomes empty;
- anchor-visible local work becomes quiescent;
- one bounded current diagnostic is retained;
- a later supported edit emits once and clears the current quarantine;
- transient bridge failures retain the pre-existing retry behavior.

Human follow-up should build a short same-town bus/tram feeder and a genuine
producer-to-consumer freight line. Neither may strand recovery readiness; both
should report their unsupported registration explicitly until their dedicated
authority adapters land.
