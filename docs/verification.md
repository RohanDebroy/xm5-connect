# Verification results

Verified locally on 2026-11-08:

- `SONY_DISABLE_BUILD_SANDBOX=1 ./scripts/test.sh`: 28 XCTest tests, zero failures.
- `SONY_DISABLE_BUILD_SANDBOX=1 ./scripts/build-app.sh`: release build passed.
- `plutil -lint dist/Sony\ Connect.app/Contents/Info.plist`: passed.
- `codesign --verify --strict dist/Sony\ Connect.app`: passed.
- Packaged executable: Mach-O 64-bit arm64; deployment target macOS 13+.
- Final test and release logs contained no compiler warnings/errors.

Tests exercise framing, ACK vectors, byte escaping and chunking, malformed frames/lists, support negotiation, independent feature errors, v1 rejection, descriptor policies, battery values, connected sources, successful and failed switches, timeout quarantine, retransmission, write stalls, disconnect/cancellation, and old-session failures after reopen.

An independent code review identified three important defects, all reproduced with failing regressions and fixed. One minor remains deferred: discovery retains completed query objects across refreshes. See progress.md.

Desktop automation could not obtain the accessory app's UI and timed out. The package was visible as an application in Finder, but menu bar rendering and launch behavior are not claimed verified. No live headphone battery, audible switching, Bluetooth permission/recovery, or native cancellation/unblocking behavior was tested. Follow hardware-checklist.md for those checks.

## 0.1.1 follow-up

The paired-device service-discovery issue has a hardware-free regression: a cached Sony service channel must connect without waiting for a fresh SDP callback. Native-target tests also cover a stale channel requiring one discovery/retry, missing services, cancellation, no cached channel and bounded open failure. Updated UI copy makes headphone selection distinct from connected audio-source switching. Final follow-up suite: 34 tests, zero failures. The user's physical-device retry is still needed to confirm the timeout is resolved on macOS.

## 0.2.0 follow-up

Verified final suite: 49 XCTest tests, zero failures, including automatic-target selection, interruption-scoped reconnect budgets, device-class list parsing, explicit list requests, optional-capacity independence, early battery reads, and type-2 notifications/post-switch refresh. A fresh independent review identified the reconnect-budget reset issue; its failing regression now passes. Release build, Info.plist lint and strict signature verification passed for version 0.2.0/build 3. Final test/release logs contain no compiler warnings or errors. CoreAudio CFString ownership follows the installed SDK's caller-release contract using unmanaged C-boundary storage and ARC ownership transfer.

No live auto-connection, battery or source-list behavior is claimed verified. The user has not yet supplied the requested runtime diagnostics. Quit/reopen the rebuilt bundle and verify the firmware's selected type/request/reply in Copy Diagnostics if the list remains unavailable.

## 0.3.0 listening-mode verification

Final listening-mode suite: 68 XCTest tests, zero failures. Release build, Info.plist lint and strict signature verification passed for 0.3.0/build 4. Coverage includes capability/profile gating, exact mode commands, preservation of ambient/voice/adaptation state, settled-confirmation matching, unknown/malformed profiles, external mode notifications and batched reply/newer-notification ordering. A fresh reviewer reproduced the stale-continuation overwrite; the regression failed and then passed after receive-order application.

On resume, rechecked version/signature and reran all 68 tests. Opened the packaged bundle through Finder and confirmed a new app process in Activity Monitor (PID54323). This verifies startup, not the mode UI's rendering or audible hardware changes. Listening-mode hardware checklist remains outstanding.


## 0.4.0 ambient slider verification (2026-11-09)

Compared mode/level semantics with Gadgetbridge Sony v2 and ambient preference sources through its GitHub mirror. Supplied live capture was separately decoded with the current parser:44% battery, six paired/two connected audio sources, and settled confirmations of ANC/Transparency/Off. Audible results are not established by packet acknowledgements.

Final suite:75 XCTest tests, zero failures. Release build, Info.plist lint and strict ad-hoc signature verification passed for0.4.0/build5. New coverage checks wire-level1/20 boundaries, invalid inputs/reports, Voice Focus preservation, fresh read before level write, delayed settled confirmation, mismatched confirmed levels, external-mode changes during a read, and unsent preflight rejection with sequence reuse. Independent review caught invalid report bounds and the queued-write race; both are addressed. A final review boundary case hides the slider for a raw0 level outside1...20. Keyboard binding edits have a deferred commit in addition to drag completion and explicit accessibility adjustment.

Mouse/keyboard/VoiceOver slider behavior and audible ambient-level changes still require the native hardware checklist; automated tests verify protocol/state behavior, not acoustics.


## 0.5.0 stable UI and Earbar rename

Reproduced layout-changing conditions from the view/state paths: five-second discovery inserted a text row, mode transitions removed ambient controls, source action text changed button width, and operation messages changed panel height. Replaced content-driven panel height with370x640 scrollable content and pinned header/footer. Removed the periodic loading row and forced discovery on opening the popover. Reserved message/spinner space, retained the ambient control outside Transparency, kept last-confirmed mode during intermediate reports, and retained local Applying feedback for pending slider writes. Controls remain semantically disabled during conflicting operations for keyboard/VoiceOver users. Slider editing explicitly cancels on an external mode transition.

Renamed visible app, bundle, executable and Swift target to Earbar0.5.0/build6; bundle identifier is local.earbar.desktop. Tests:77, zero failures. Release build, plist lint and strict signature verification pass. These checks establish state behavior and packaging; native menu movement, keyboard/VoiceOver and interrupted slider drag still need live UI verification.


Opened the0.5.0 bundle through Finder after quitting the previous process; Activity Monitor confirms Earbar running as PID93530. This verifies the renamed build starts, not visual interaction quality. The obsolete generated bundle was removed from dist so only Earbar.app remains.


## 0.5.1 requested layout refinements

Hidden scroll indicators while retaining overflow scrolling, moved the slider directly under Ambient before Normal, changed the mode title from Transparency to Ambient, and replaced the footer's reserved message block with the existing single-line header status/tooltip. Footer vertical padding is8points; content/header padding is16points.77tests pass; release build, plist lint and strict signature verification pass for0.5.1/build7. No new tests were added for these presentation-only changes. Visual layout still needs user confirmation.
