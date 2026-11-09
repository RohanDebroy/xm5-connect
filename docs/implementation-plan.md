# Earbar Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans for inline execution. Track steps below and progress in progress.md.

**Goal:** Deliver the approved native macOS menu bar app with a reusable Sony Tandem core.
**Architecture:** A dependency-free protocol library handles codecs, feature parsing, capability policy and reliable sessions through a transport protocol. The executable provides IOBluetooth RFCOMM, a presentation model and SwiftUI MenuBarExtra.
**Tech Stack:** Swift 5 language mode / Swift tools 6, Foundation, SwiftUI, IOBluetooth, XCTest; macOS 13+.
**Spec:** design.md

## Global Constraints

- Project lives in outputs/xm5-connect; device names never gate capabilities.
- v2 payloads only; v1 detected and explicitly unsupported.
- Unknown capability versions do not enable writes without evidence.
- Disconnect clears live data, cancels pending operations, and closes only the RFCOMM control channel.
- No first-time pairing, unpairing, firmware updates, ANC/EQ, or launch-at-login.

## Review Focus

- Corrupt/fragmented frames must not reach features or consume unbounded memory.
- A late or unrelated response must not complete another request.
- Loss, cancellation, and write failure must release waiters and stop retries.
- Unsupported or malformed features must leave independent features usable.
- Device selection/reconnect races must not show data from a previous connection.

## Task 1: Codec and feature domain

Files: Package.swift, Sources/TandemCore/{FrameCodec,Features}.swift, Tests/TandemCoreTests/ProtocolTests.swift.
Interfaces: Frame(dataType:sequence:payload:), FrameCodec.encode(_:), FrameParser.feed(_:); CapabilityRegistry; BatteryStatus; PeripheralSnapshot; SourceSwitchResult.
- [x] Write and run failing tests for known init/ACK bytes, escaping, arbitrary fragmentation, checksum/size/escape rejection, capability parsing, v1 detection, battery status, list bounds and selection, address validation and switch-result errors.
- [x] Implement these interfaces from supplied docs; run all tests.

## Task 2: Transport-independent reliable session

Files: Sources/TandemCore/{Transport,TandemSession}.swift, Tests/TandemCoreTests/SessionTests.swift.
Interfaces: @MainActor TandemTransport with connect/disconnect/write and event callbacks; TandemSession.request(table:payload:matching:), start(), stop(), notifications.
- [x] Test with an in-memory transport boundary: ACK before delivery, duplicate suppression, exact retransmit on missing ACK, correlation, disconnect/cancel rejection, response timeout, and fresh negotiation on reconnect.
- [x] Implement one serialized request lane with immediate serialized ACK writes, bounded deadlines and safe cancellation; run suite.

## Task 3: Native transport and menu bar app

Files: Sources/Earbar/{RFCOMMTransport,DeviceCatalog,HeadphoneModel,EarbarApp}.swift, scripts/build-app.sh, Resources/Info.plist.
- [x] Implement asynchronous SDP/RFCOMM with per-connection identity guards, finite connection timeout and serialized writes.
- [x] Implement persisted explicit selection, capability negotiation, independent feature errors, polling, bounded reconnect, diagnostic export and source-result correlation.
- [x] Implement native menu popover with accessible states/actions; compile against installed SDK.
- [x] Package and ad-hoc sign release .app; verify plist, signature and executable architecture.

## Task 4: Review and delivery

Files: README.md, docs/hardware-checklist.md, docs/progress.md.
- [x] Run full tests and release packaging; record exact outcomes and hardware verification limits.
- [x] Obtain fresh code review, fix material findings with regression tests, rerun suite/build.
- [x] Deliver app and source links plus concise startup instructions.
