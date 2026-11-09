# Earbar menu bar app design

## Intent

Build a native macOS menu bar application in `outputs/xm5-connect` that reads a Sony audio device's battery, shows its connected audio sources, and lets the user switch the active source. The initial hardware target is the user's XM5. Protocol and feature logic must be reusable across Sony devices rather than branch on model names.

## Chosen approach and alternatives

The user selected native SwiftUI with Classic Bluetooth RFCOMM, following the supplied protocol docs' recommendation for ordinary headphone control. Use IOBluetooth for bonded-device enumeration, SDP service discovery and asynchronous RFCOMM connection. Use SwiftUI MenuBarExtra for the status item and popover.

BLE via CoreBluetooth was considered: it carries the same framed Tandem messages but requires separate readiness/MTU setup. Defer the BLE adapter while keeping the transport boundary suitable for it. A browser application would require a different Bluetooth access path and does not satisfy the requested native menu bar experience.

## Product scope

- A menu bar headphone icon and battery percentage when a fresh reading is available; otherwise show an unknown/disconnected state.
- A compact popover with a paired Sony-compatible device picker, connection status, battery/charging status, connected audio sources, and a switch button per eligible source. Remember the user's selected device.
- Identify candidates using Sony SDP service UUIDs; names are display text, never capability gates. Refresh bonded devices manually; do not silently select an arbitrary headset.
- Distinguish connected sources from remembered but disconnected sources. Disconnected entries may be shown separately for context, without source-switch actions.
- Connect, disconnect the control session, refresh, reconnect after loss with bounded backoff, and quit. Disconnecting the control session must not deliberately disconnect the macOS audio connection.
- Show unsupported features, permission failures, timeouts, calls blocking switching, missing media connections, and assistant-priority failures as understandable states. Disable duplicate actions while a switch is pending.
- No first-time pairing, unpairing, firmware updates, EQ controls, or launch-at-login. Listening-mode controls were added at the user's request in 0.3.0. Pair with macOS Bluetooth settings first.

## Structure and abstractions

Use a dependency-free Swift package with a library target, executable app target, and library tests. Target macOS 13 or later. Provide a script that packages the release executable as a local `.app` with `LSUIElement` and Bluetooth usage descriptions, then ad-hoc signs it. No App Store distribution or notarization is promised.

1. **Transport protocol:** connect, disconnect, serialized whole-frame writes, and byte/disconnect events. Knows neither Sony commands nor SwiftUI. RFCOMM adapter discovers the v2 Sony service, falls back to v1 service if available, and resolves the channel using SDP. Keep the Apple delegate adapter isolated from the portable protocol library.
2. **Frame codec:** bounded incremental parsing, strict length/checksum/escape validation, encoding, resynchronization, and arbitrary chunk support.
3. **Reliable session:** handshake generation detection, independent send/receive sequence state, immediate ACK, retransmission deduplication, one outstanding outbound command, bounded retries/timeouts, request/reply correlation by table/command/type, and notification delivery without blocking ACK processing. Disconnect cancels pending work and clears live state. Reconnect reruns negotiation.
4. **Capability registry:** store table/function/version pairs and raw capability responses. Unknown functions/versions remain inspectable and do not enable writes. Feature implementations declare the capability versions they understand; unsupported versions result in an explicit unavailable state. Do not equate protocol generation with feature support.
5. **Feature services:** power service parses the documented single-battery variant; peripheral service parses paired/connected lists, capability source counts and switch results. Future battery variants and features can be added without changing the transport or codec. Table 2 function `0x31` means SOURCE_SWITCH_CONTROL, following the raw enum over the conflicting overview label.
6. **Application model:** exposes connection, battery, source list and action state to SwiftUI; owns selection persistence, refresh cadence, reconnect policy and bounded diagnostic log. UI consumes domain values rather than raw byte offsets.

## Protocol behavior and compatibility limits

Support the documented v2 formats initially. A v1 init response is recognized and reported as unsupported; it never receives v2 feature commands. This is a capability-driven Sony Tandem client, not a claim of compatibility with arbitrary Bluetooth brands or every Sony firmware.

Negotiate table 1 and table 2 support functions, and per-feature capabilities when the wire format requires capability-dependent values. Fixed device-list/source-switch messages use the advertised function and validated connected addresses; optional capacity inquiries do not block them. Only query or enable implemented feature variants. Request battery and device list initially, process notifications continuously, and refresh periodically while connected. Battery read failures must not prevent source-list display, and unavailable multipoint must not prevent battery display.

Validate every device-list boundary and 17-byte address. Preserve unknown status values without crashing. Treat a missing, out-of-range or disconnected selected-source index as unknown. The selected-source field is documented but still needs verification on hardware; label it as the device-reported selection rather than independently verified playback activity.

Switch only to a currently connected source when source switching is advertised. Match result address to the pending request. A success means the headphones accepted the request; refresh the list rather than optimistically changing selection. Failures preserve the previous confirmed data. On link loss clear live battery/source state to avoid presenting stale data as current.

## Verification and delivery

Automated tests cover known init/ACK vectors, escaping, chunk boundaries, malformed/oversized frames, negotiation parsing, unsupported generations/functions, battery states, malformed device lists, selected-index handling, switch address/result correlation, timeouts, retransmission and disconnect cancellation. Transport integration is compiled against the installed SDK; live Bluetooth tests require the user's headphones and permission.

Deliver source, tests, build/run instructions, packaged `.app` when local compilation permits, and a hardware checklist. Clearly separate passing automated checks from unverified device behavior. The builder may choose internal Swift types, exact layout, timeout values and refresh cadence, provided these invariants hold.

## Design review finding

The independent builder check found one technical research gap: the supplied docs expose capability-version fields but do not enumerate which version values use the documented battery/peripheral payload layouts. During implementation, establish those supported-version mappings from protocol implementation evidence or a captured negotiation trace. Do not invent mappings or equate every advertised version with support. If evidence remains unavailable, keep source switching disabled with a clear compatibility message and retain diagnostics for hardware validation. This is an implementation evidence requirement, not an additional product preference for the user to decide.

## Implementation research amendment

Independent primary implementation evidence resolves the descriptor research gap differently from the initial protocol notes: `mos9527/SonyHeadphonesClient/src/Constants.h` defines the second descriptor byte as `priority`, and `Headphones.cpp` dispatches fixed v2 functions without version branching. Preserve the byte as raw metadata and make its interpretation an explicit policy. The native adapter selects the reference-priority policy for the documented v2 formats; a strict capability-version policy is available for firmware with verified version semantics. Function advertisement and a valid connected-device list are required for switching. This is an implementation compatibility choice, not a hardware-confirmed correction to the supplied docs; see README for links and limitations.


## 0.2.0 user-requested behavior

Automatically discover/control connected Sony headphones at app launch and show battery without opening the menu. Prefer the current macOS output (address/UID, then a unique friendly-name match for identity only), otherwise a connected saved selection or the sole connected Sony device. Do not choose arbitrarily among ambiguous candidates. Manual Disconnect pauses auto-connect. Reconnect remains bounded per interruption; a successful connection resets its budget.

Support both documented plain Classic lists (type 0) and independently verified device-class lists (type 2, three-byte big-endian device class before name length), selected from function advertisements. Request the list explicitly, handle matching notifications and refresh it after source switching. Battery loads before optional table-2 work. The capacity probe is not a prerequisite: the list and fixed-address switch command have no capacity-dependent numeric payload.


## 0.3.0 user-requested listening modes

Add a native checked-row Listening Mode section for Noise Cancellation, Transparency and Normal (Off), following the supplied visual reference. Enable only modes in recognized advertised profiles. Core profile negotiation, parsing and command construction remain independent of macOS/UI code.

Implement exact function/type mappings 6B/17, 6D/19, 67/22 and 66/21 from raw enums and independent protocol structures. Read state using v2 66/67; write 68 and await settled69. Preserve ambient level, voice and adaptation values from a fresh read/the latest received notification. Mode-only controls expose no adjustable numeric ranges. Normal disables the total effect. A zero ambient level uses reference minimum1 only when enabling ambient. Unknown variants remain disabled rather than using a universal fallback.

Apply matched replies and notifications synchronously in receive order before resuming request continuations. A late continuation must not restore older state or overwrite newer preserved settings. Intermediate change notifications do not confirm selection; malformed latest reports show unknown selection and an error. Existing battery/source operations remain independently handled.


## 0.4.0 ambient-level slider

User requested an ambient slider alongside the mode controls. Show it below Transparency for capability-negotiated function 6B/type17. Use the independently confirmed range 1–20, preserving Voice Focus. Other NCASM profiles retain mode controls without a guessed adjustable range. Keep draft values local while dragging, send one settled SET on release, fresh-read first and reject if hardware/another app has left Transparency. Wait for matching settled notification and validate both mode and level. Keep confirmed state in receive order. Keyboard/accessibility increments use the same client command path. No separate audio volume control is introduced.

The 2026-11-09 user capture confirms successful ANC/ambient/off reports, battery44 and two connected sources; it does not prove audible behavior. Gadgetbridge's GitHub mirror independently matches the seven-byte command and its ambient preference maps to wire levels1–20. See README reference links.


## 0.5.0 stable operation layout

Keep a fixed370x640 panel with scrolling central content and pinned header/footer. Reserve status and spinner space rather than inserting rows on routine operations. Discovery continues in the background without a loading row. Keep a capability-supported ambient slider visible but disabled outside Transparency. Retain last-confirmed mode only during same-profile intermediate reports, while command availability uses live state. Display pending slider draft as Applying until the operation ends. Rename the product to Earbar as an assistant-selected working name, retaining the Earbar bundle identifier.


## 0.6.0 local source audio routing

User expects Use for audio to select the headphones in macOS when this Mac is the target source. Keep headphone protocol switching in TandemCore; implement system routing in the macOS adapter. Identify this Mac by local Bluetooth controller address. Wait for headphone acceptance before changing the default media output; other sources and rejected switches leave local routing alone. Match alive, default-capable Bluetooth outputs by headset address, with a unique name fallback only for opaque UIDs. Validate cancellation/connection token before writing, bound endpoint discovery and readback confirmation, and report partial success when routing fails. Do not change the system alert output or per-app routing.
