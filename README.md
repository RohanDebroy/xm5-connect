# Earbar for macOS

A native menu bar app for Sony audio devices using the Tandem v2 protocol over Classic Bluetooth RFCOMM. It displays headphone battery and charging status, connected audio sources, buttons to request source switching, and a checked Listening Mode section for Noise Cancellation, Transparency and Normal (Off). The original target is WH-1000XM5; feature selection uses advertised protocol functions, never device names.

## Run the packaged app

1. Pair your headphones in macOS Bluetooth settings and connect them to this Mac.
2. Open `dist/Earbar.app`. Its headphone icon appears in the menu bar; there is no Dock window.
3. Allow Bluetooth access when macOS asks. The app automatically selects connected Sony headphones, preferring the current macOS audio output, then a connected saved selection, then a sole connected candidate. Battery loading starts at launch without opening the icon. If multiple devices remain ambiguous, choose one in the picker.
4. For switching, both audio sources must already be connected to the headphones. Click **Switch** beside a connected source. The app waits for the headphones' result and then reads the source list again.

An active call, missing media connection, or voice assistant can prevent switching. The selected-source label is the headphones' reported selection, not an independent measurement of audio playback. Disconnect closes the app's control channel without deliberately disconnecting macOS audio.

This is a local, ad-hoc-signed build, not a notarized download. Keep the bundle at a stable path for Bluetooth permission. If rebuilding changes macOS's permission association, check System Settings → Privacy & Security → Bluetooth. No developer account is needed to build locally.

## Build and test

Requires macOS 13+ and an installed Swift 6 toolchain/Xcode command-line tools. No third-party dependencies.

```bash
cd outputs/xm5-connect
./scripts/test.sh
./scripts/build-app.sh
open "dist/Earbar.app"
```

The build script uses the current Mac's architecture and creates an `.app` with the required Bluetooth descriptions and menu bar-only setting. Open `Package.swift` in Xcode to inspect or debug the source. Launch the packaged app for normal use so Bluetooth permission belongs to its bundle.

In a development environment that already sandboxes the compiler and prohibits SwiftPM's nested sandbox, set `SONY_DISABLE_BUILD_SANDBOX=1` when running the scripts. Build/cache files stay under `.build/`.

## Abstractions

```text
SwiftUI MenuBarExtra + HeadphoneModel
                    │
             SonyDeviceClient
        ┌───────────┴────────────┐
   Power / battery       Peripheral management
   domain decoder        + source-switch decoder
        └───────────┬────────────┘
       CapabilityRegistry + DescriptorPolicy
                    │
             TandemSession
     ACK, deduplication, retry, correlation,
      deadlines, cancellation, notifications
                    │
          FrameCodec / FrameParser
                    │
             TandemTransport
                    │
            RFCOMMTransport
         IOBluetooth + SDP discovery
```

- `Sources/TandemCore` imports Foundation only. It has no dependency on SwiftUI, IOBluetooth, Bluetooth addresses of headphones, or model names.
- `TandemTransport` represents a byte stream. A BLE adapter can implement it later without changing framing or feature services; Sony's BLE readiness and MTU sequence belongs in that adapter.
- `FrameParser` accepts arbitrary chunk boundaries, resynchronizes, and bounds memory. `TandemSession` owns sequence state, exact-frame retries, immediate ACKs, request matching and disconnect cancellation.
- `SonyDeviceClient` coordinates independent feature parsing/availability. Unsupported battery formats do not hide the device list. Unsupported multipoint does not hide battery.
- UI connection tokens prevent callbacks from an old device/session updating the newly selected device. A disconnected session clears live readings. Reconnect retries at most three times (2/4/8 seconds); manual Connect starts a new series.
- A request whose ACK arrived but response timed out cannot be retried with the same reply key until reconnect. This prevents a late response satisfying a newer operation because Tandem has no transaction IDs. Other features can continue.

## Capability metadata discrepancy

The initial protocol notes name the second byte of each support descriptor `capVersion`. An independent implementation instead defines it as `priority` and dispatches these fixed v2 formats by function identity:

- [Support descriptor definition, Constants.h](https://github.com/mos9527/SonyHeadphonesClient/blob/master/src/Constants.h)
- [Function dispatch, Headphones.cpp](https://github.com/mos9527/SonyHeadphonesClient/blob/master/src/Headphones.cpp)
- [Peripheral/source-switch wire structures](https://github.com/mos9527/SonyHeadphonesClient/blob/master/src/ProtocolV2T2.h)

The native app explicitly selects `DescriptorPolicy.referencePriority`, preserves the raw descriptor byte in diagnostics, and uses only the documented fixed v2 layouts with advertised functions and a validated connected-device list. This is an implementation-evidence-based compatibility choice; the metadata's meaning on this firmware is not hardware-verified. If a firmware is known to use capability versions, supply `DescriptorPolicy.capabilityVersions(verifiedVersions)` instead; unknown versions are then rejected. There is no invented model-to-version table. No source code from the reference implementation is copied.

## Current support and limits

- Implemented: v2 handshake, capability identifier/support functions, single-device battery (`BATTERY`), Classic paired/connected lists (plain and Bluetooth device-class variants), and source switching (`SOURCE_SWITCH_CONTROL`).
- Not implemented: v1 feature payloads, left/right/case battery variants, other NCASM payload layouts, ambient-level sliders for other NCASM profiles, BLE transport, initial pairing, connect/disconnect/unpair of remembered sources, or other Sound Connect features. These are reported unavailable instead of using another format's bytes.
- The control connection tries the existing Sony service channel first. If that channel fails, it refreshes SDP and retries once. Pairing or an audio connection no longer has to wait for an unnecessary second service-discovery callback.
- Device discovery uses Sony service UUIDs. It queries already-connected bonded devices without cached Sony service records once per connection (or on manual refresh), avoiding repeated probes of unchanged accessories. Connect the headphones through macOS first if they do not appear.
- Only one headset control session is active at a time. The picker remembers your selection. Startup discovery and five-second connection checks run in the background. Manual Disconnect pauses automatic connection until Connect or a new selection. Successful reconnects reset the per-interruption retry budget.
- **Build/tests do not prove hardware compatibility.** Battery notifications, capability descriptors, source-list trailer semantics, source switching and listening-mode changes still need validation with your headphones. See `docs/hardware-checklist.md`.

## Listening modes

The menu's Listening Mode section shows the latest settled device-reported selection. Normal (Off) turns off NC/ambient processing; it does not power off the headphones. Only modes available in the negotiated, implemented profile are enabled. Incoming notifications track changes made with the headphone button or another controller.

Implemented table-1 function/type pairs:

| Advertised function | NCASM type | Available controls |
| --- | --- | --- |
| `0x6B` | `0x17` | ANC, Transparency, Normal |
| `0x6D` | `0x19` | ANC, Transparency, Normal; preserve adaptation settings |
| `0x67` | `0x22` | Transparency, Normal |
| `0x66` | `0x21` | Transparency, Normal |

Mode state uses `66 <type>` (GET), `67` (reply), `68` (SET), and `69` (notification). These v2 bytes are confirmed by the supplied raw enum tables and [reference NCASM structures](https://github.com/mos9527/SonyHeadphonesClient/blob/master/src/ProtocolV2T1.h); the high-level overview has conflicting older values. The app never substitutes a different schema for an unknown advertised variant.

Before a mode write, the app re-reads the current state and preserves the newest observed ambient level, voice-focus and adaptation fields. For the seven-byte 6B/17 profile, Transparency includes an ambient-level slider (1–20). A drag sends one settled command on release; Voice Focus is preserved. The level is confirmed by the headphones. Other profiles keep mode controls without an unverified slider range; when enabling ambient with a reported zero level, it uses the reference setter's minimum of 1. Mode switches wait for a settled notification rather than treating a Bluetooth ACK as confirmation. Listening state is applied in receive order so a newer hardware notification cannot be overwritten by an older request reply. Malformed reports clear the checkmark and disable changes until valid state is read again. Battery and connected-source data remain independent of mode parsing errors.

## Audio-device list requests

After support-function negotiation, the app explicitly requests `36 00` for the plain Classic format or `36 02` for the device-class variant, according to advertised function `0x30` or `0x32`/`0x33`. Both replies and `39` notifications use that same selected type; post-switch refresh does too. Names may be empty, in which case the address is shown.

An optional capacity inquiry is no longer part of startup: missing/rejected capacity responses must not prevent the separately advertised list from being fetched. The independent reference's [initial-state requests](https://github.com/mos9527/SonyHeadphonesClient/blob/master/src/Headphones.cpp) also request peripheral parameters directly. The UI shows the connected count, without guessing a maximum. Source-switch commands require the advertised switch function plus a validated connected target address. No capability-dependent numeric parameters are sent.

## Diagnostics

App options → **Copy Diagnostics** copies a bounded, in-memory log of the last 300 entries, including frame hex and support descriptors. It contains device names and Bluetooth addresses; review before sharing. No network requests, analytics, or persistent device logs are used.

## Protocol sources

Implementation follows the repository's `../../docs/sony-mdr/` documentation, especially transport, framing, handshake, features and multipoint pages. See `PROTOCOL-NOTES.md` for the initial findings. The app uses Apple's [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra) and [IOBluetooth RFCOMM](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice/openrfcommchannelasync(_:withchannelid:delegate:)) APIs.


### 0.4.0 ambient-level reference check

Compared the existing mode layout with [Gadgetbridge SonyProtocolImplV2](https://github.com/Freeyourgadget/Gadgetbridge/blob/master/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/sony/headphones/protocol/impl/v2/SonyProtocolImplV2.java) and [AmbientSoundControl](https://github.com/Freeyourgadget/Gadgetbridge/blob/master/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/devices/sony/headphones/prefs/AmbientSoundControl.java), accessed 2026-11-09 through its GitHub mirror (Codeberg was inaccessible). Its seven-byte v2 command matches our total-effect, NC/ASM, Voice Focus and level fields. Gadgetbridge's UI preference offsets ambient levels by one, producing wire values 1–20. The native slider uses those wire values directly, without the Android preference offset. No Gadgetbridge implementation code is incorporated.
