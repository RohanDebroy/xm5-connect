# XM5 Connect protocol research

Target: native macOS status/menu bar application. Requested features: headphone battery, connected source devices, and switching active audio source.

## Findings from the supplied docs

- Tandem/MDR uses the same framed stream over Classic RFCOMM and BLE GATT. `docs/sony-mdr/01-transport.md` recommends RFCOMM for normal headphone control.
- RFCOMM service UUIDs: v2 `956C7B26-D49A-4BA8-B03F-B17D393CB6E2`, v1 `96CC203E-5068-46AD-B32D-E316F5E069BA`. Discover the channel via SDP; do not hardcode it.
- BLE headphone service: `5b833e20-6bc7-4802-8e9a-723ceca4bd8f`; TX/RX characteristic short IDs `5b833c60` / `5b833c61`. BLE requires Sony readiness and MTU setup before Tandem initialization.
- Frame: SOF `3e`, data type, sequence, four-byte big-endian length, payload, sum checksum, EOF `3c`. Escape `3c/3d/3e`. Parse across arbitrary transport chunks, validate exact length/checksum, ACK valid non-ACK frames with opposite sequence, deduplicate retransmissions.
- Initialize with table 1 (`0c`) payload `00 00`; an eight-byte reply selects generation v2. A four-byte reply is v1 and requires another implementation.
- Query capability information (`02 00`) and support functions (`06 00`) on tables 1 and 2. Support response: `07 00 count (function version)...`.
- Battery support: table 1 function `20`. Read `22 00`; response/notification `23/25 00 level chargingStatus`. Charging states: 0 not charging, 1 charging, 2 unknown, 3 charged.
- Device management: table 2 (`0e`) function `30`. Capability request `30 00`; response `31 00 numSource numSink fileTransfer`.
- Source switching: table 2 function **31**, named SOURCE_SWITCH_CONTROL in `appendix-functiontype-raw.md`. The overview's description of this value as CONNECTION_STATUS conflicts with that raw enum; use the explicit enum.
- Device list request `36 00`; response/notification `37/39 00 count entries trailingIndex`. Each entry: 17 ASCII address bytes, status byte (>0 connected), name length byte, UTF-8 name. Validate every boundary.
- The trailing index's selected-source semantics need hardware verification. Treat missing/out-of-range/disconnected indices as unknown.
- Switch request `3c 01 <17 ASCII address bytes>`; result `3d 01 result <address>`. Correlate address, handle call/assistant/media-link failures, and refresh after success. Do not optimistically mark a source active.
- Negotiate feature support and preserve unknown capability versions as unsupported until implemented. Do not infer capabilities from the headphone name.

## macOS API references

- SwiftUI MenuBarExtra: https://developer.apple.com/documentation/swiftui/menubarextra
- IOBluetooth asynchronous RFCOMM: https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice/openrfcommchannelasync(_:withchannelid:delegate:)
- Installed SDK headers confirm asynchronous SDP discovery, RFCOMM open/data/close delegates, and writes.

## Verification boundary

These are source-document findings, not observations of the user's headphones. Live battery, multipoint, source index interpretation, and firmware compatibility require testing with the XM5.
