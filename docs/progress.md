# Execution ledger — implementation-plan.md

Design approved by user. Inline execution in the requested new project folder.
Ruling: REA has no Git repository; use the user-selected outputs/xm5-connect directory as the isolated project and keep this ledger instead of Git-specific skill scripts. No unrelated files touched.
Pre-flight: Task 1 domain types feed Task 2 session; Task 3 consumes both. All protocol and transport callbacks run on MainActor, while native synchronous writes use a dedicated serial queue. No shared-interface conflicts.
Task 1: core codec and feature tests complete — 8 tests pass. Initial missing-symbol failures observed; a Swift type-check timeout in a long test fixture was corrected by splitting concatenations. Build caches redirected to /tmp due to sandbox restrictions.
Task 2: reliable session complete — 15 tests pass across core + session. Tests cover missing ACK retries, cancellation, disconnect, write errors, reply address/table matching and duplicate ACK behavior.
Ruling: after an acknowledged request times out, quarantine its reply key until reconnect rather than reusing it. Tandem has no transaction ID, so this prevents late replies completing a later request while allowing unrelated features to continue. A timed-out feature requires reconnect to retry safely.
Ruling: independent primary implementation evidence names the support-descriptor second byte priority and dispatches the documented v2 wire formats by function. Add explicit DescriptorPolicy.referencePriority and capabilityVersions(Set) abstractions; native app selects the reference policy and preserves raw metadata. Cost if wrong on a firmware: rejected/incorrect feature compatibility; hardware checklist and README call out this uncertainty. No model-name gates or invented version numbers.
Task 3: native transport, client, menu UI and packaging implemented. Core/client/session: 21 tests passed before write-deadline regression. The regression failed with a 272 ms deadline against a 30 ms timeout; moved deadline enforcement outside the transport write await.
Final review: fresh independent reviewer found three important issues and one minor. All important findings fixed in one regression pass:
- Empty friendly names: testEmptyFriendlyNameFallsBackToAddress failed then passed; accept zero-byte names and use address fallback.
- Independent table-1 negotiation: testMalformedTable1SupportDoesNotHidePeripheralFeatures failed then passed; table-2 features remain usable after a table-1 support error.
- Old-session asynchronous errors: three tests for late connect/request-write/ACK-write errors failed then passed; guard callbacks/error paths with originating epoch and operation identity.
Final: minor (deferred): DeviceCatalog retains completed SDP query objects across manual refreshes; clean up with an explicit policy for late native callbacks. This does not change protocol state but can accumulate memory over repeated refreshes.
Final verification: 28 XCTest tests, zero failures. Release build passed. Info.plist lint and codesign --verify --strict passed. Packaged binary is arm64 for this Mac. No compiler warnings in final test/release logs.
UI startup verification: attempted via desktop automation, but it could not obtain the accessory app's UI and timed out. Finder showed the packaged application; no menu bar state or live Bluetooth behavior is claimed verified. Hardware checklist remains manual.
Task 4: complete. All source and artifacts retained in the requested output project; no Git repository or integration operation applies.

## 0.1.1 — service-discovery timeout follow-up

User reports an already-paired device timing out waiting for Bluetooth service discovery. Source inspection confirms DeviceCatalog lists only devices with an existing Sony service/channel record, but RFCOMMTransport unconditionally required another SDP lookup before opening that same channel. Native diagnostics previously contained only Tandem frames, so a pre-handshake timeout had no useful stage details.

Extracted the existing discovery-first algorithm into RFCOMMConnectionPlan and wrote six hardware-free native-target tests. The known-channel/discovery-timeout regression failed with the reported timeout, stale-channel fallback and cancellation tests also failed. Changed policy to try the known Sony channel first, discover only if absent or failed, then retry the discovered channel once. Close failed channel attempts without invalidating the overall attempt, and guard cancellation by connection identity. All six regressions pass, along with the 28 existing tests (34 total).

Added native-stage diagnostics for cached channel, pairing/connection state, SDP request result and callback deadline, and RFCOMM completion. App version is now 0.1.1/build 2. Clarified UI labels to distinguish headphones-to-control from their connected audio devices and Use for audio source-switch actions. This preserves the user's intended headphone-controlled multipoint switching.

Hardware outcome remains unverified: desktop automation could not access the running menu bar app. User must quit/reopen the rebuilt bundle and retry; if it still fails, the new Copy Diagnostics log identifies the failed native stage. No re-pairing or guessed RFCOMM channels introduced.

## 0.2.0 — automatic connection and audio-device lists

User requested automatic connection to the active headphones, battery display, and investigation of the absent list, then asked whether that list needs an explicit request. Confirmed yes: GET_PARAM type 0 or 2 follows support negotiation; notifications alone are insufficient for initial population.

Implemented startup discovery in HeadphoneModel instead of waiting for popover appearance. A testable policy prefers connected headphones identified as the macOS default output, then a connected saved selection or sole connected candidate. No arbitrary choice among ambiguous devices. Background discovery checks every five seconds; unrecognized connected accessories are probed once per connection, while manual refresh can force a new probe. Manual Disconnect pauses auto-connect, and per-target automatic attempts do not defeat the bounded retry budget. CoreAudio is queried read-only; names are identity fallback only, never feature gates.

Confirmed code defects: the prior client recognized only function 0x30/type 0, and a failed PERI_GET_CAPABILITY inquiry suppressed GET_PARAM. The independent protocol reference confirms function 0x32/0x33's type-2 device-class format (17-byte address, status, 3-byte big-endian class, length-prefixed name, selection trailer); its initial-state code requests parameters directly without a capacity prerequisite. Added that negotiated format and removed the startup capacity probe. Switch actions remain gated by advertised source-switch support and an actually connected address from a validated list. No maximum source count is invented. Battery now loads before table-2 negotiation. Native diagnostics log selected list type and exact request.

Tests reproduced the old class-list rejection, old list suppression after capacity failure, and battery loading after table-2 work, then passed after changes. Coverage includes type-2 notifications, type-2 post-switch refresh, function 0x33, malformed/truncated list entries, and no optional capacity request. The latest suite has 49 tests, zero failures.

Fresh review found one important unattended-lifecycle issue: retry count persisted across successful recovery. Extracted ReconnectBudget, observed its recovery-reset regression fail, then reset on successful startup and verified repeated interruption budgets. Manual Disconnect and negotiated-type propagation were reviewed with no additional important findings.

Device diagnostics were requested asynchronously but have not been supplied. These are verified code-path fixes and simulated protocol tests, not proof of the user's firmware payload or live source-list rendering. Hardware retry remains required. App version 0.2.0/build 3.
0.2.0 final verification: full suite 49/49; release build and signature verification passed, plist version 0.2.0/build 3. Corrected a CoreAudio raw-pointer compiler warning using owned unmanaged CFString storage per installed SDK ownership docs; final build/test logs are warning-free. No live Bluetooth claims.

## 0.3.0 — listening-mode controls

User explicitly requested ANC, Transparency and Normal/Off controls with checked native rows like the attached reference. Implemented a separate ListeningMode domain decoder/builder and native ListeningModeSection, with capability-driven profiles (functions6B/6D/67/66 to types17/19/22/21). Raw enum tables agree with the independent primary implementation on v2 commands66/67/68/69; high-level overview command/function numbers conflict and were not used. Unknown profiles remain unavailable, no model-name gate or universal fallback.

Initial GET loads mode state; hardware notifications update it. Mode actions fresh-read settings, preserve voice/level/adaptation fields, write only requested mode fields, and wait for settled69 rather than ACK/intermediate69. Normal turns total effect off. Ambient with a zero observed level uses reference max(level,1); there is no level slider. Optional feature read errors do not hide battery or audio devices.

Domain and client tests passed (63 tests), then a fresh independent review reproduced a receive-order race: an older awaited GET/SET reply could overwrite a newer hardware notification. Added failing regressions for GET/SET ordering, latest-level/voice preservation and malformed newer reports. Session now exposes synchronous onMessage application before continuation resumption. Listening state follows wire order and setter uses the latest received settings. Full suite passes68 tests including different settled-mode rejection. No other important review findings.

Package version0.3.0/build4. Live audible mode switching remains untested; user must validate with headphones. No Apple-specific extra features are implied by the visual reference.
Resume completed: verified 0.3.0 signature, reran 68 tests, launched bundle via Finder, confirmed new running process PID54323 in Activity Monitor. No audible mode change was performed or claimed tested.


### 2026-11-09:0.4.0 ambient slider

User requested Gadgetbridge cross-check and ambient slider. Compared seven-byte v2 encoder and Android level preference offset against Gadgetbridge GitHub mirror; existing mode fields match. Added capability-based6B/17 ambient slider1–20, local drag draft, keyboard/accessibility paths, fresh reads, settled level confirmation, and pre-transmission validation against newly observed device state. Preserves Voice Focus. Other profile ranges remain unguessed.75tests and signed release pass. See verification and hardware checklist for remaining live UI/acoustic checks.
