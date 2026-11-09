# Hardware validation

Automated tests use an in-memory transport to test actual protocol/session/feature code. They do not connect to Bluetooth hardware.

- [ ] Launch the packaged app and approve macOS Bluetooth access.
- [ ] Connect the headphones to macOS for audio, refresh the app's picker, and choose the device.
- [ ] Without opening the menu, confirm the active connected Sony headphones are selected automatically and a fresh battery percentage appears.
- [ ] Connect if selection is ambiguous; inspect diagnostics for init generation, table 1/table 2 support descriptors and selected device-list request type.
- [ ] Compare reported battery/charging state with Sound Connect. Verify battery updates or manual refresh.
- [ ] Connect a second source through normal OS pairing/connection flows; confirm the app reports both connected names.
- [ ] Play audio from each source and compare the reported selection index. If the index semantics differ, keep selection unknown rather than guessing.
- [ ] Switch to each connected source; verify the app waits for a matching result, refreshes the list, and audio behavior follows.
- [ ] Test failure during a call, without a media link, and while an assistant has priority. Confirm useful errors and no optimistic selection.
- [ ] Disable Bluetooth or power off the headphones; verify readings clear and reconnect stops after three attempts.
- [ ] Change the selected headset during connection; verify no stale state appears from the earlier connection.
- [ ] Deny permission, then enable it in System Settings; verify recovery after refresh/connect.
- [ ] Check device firmware modes that restrict multipoint, and a device without the implemented features; unsupported functions must remain unavailable.
- [ ] Confirm the raw support-descriptor metadata interpretation before claiming firmware-wide compatibility. See the README's discrepancy note.

Do not claim support for another model/firmware until its capability report and the implemented payload variants have been exercised.

- [ ] Test default-output preference with two connected Sony devices and verify manual Disconnect stays paused.
- [ ] Test power off/on and several separately recovered link losses; each interruption should have a fresh bounded retry budget.

## Listening modes

- [ ] Confirm the negotiated listening profile appears in diagnostics and the initial checkmark matches the headphones.
- [ ] Select ANC, Transparency and Normal where available; verify actual audible behavior and settled checkmark.
- [ ] Change mode with the headphone button or Sound Connect and verify the checkmark follows notifications.
- [ ] Confirm ambient level/voice focus/adaptation settings remain unchanged by mode-only changes, apart from the documented zero-to-one ambient minimum.
- [ ] Test an unsupported profile, a missing confirmation, and a link loss during a change; stale or unconfirmed selection must not be shown as success.


## Ambient slider (0.4.0)

- [ ] In Transparency, drag from the reported level to1 and20; verify one SET per release and a settled69 with the requested level.
- [ ] Verify audible ambient difference, Voice Focus preservation, keyboard arrows and VoiceOver adjustment.
- [ ] Change modes with the headphone button/phone while dragging; releasing must not reactivate Transparency.
- [ ] Confirm external ambient-level notifications update the slider when idle, and ANC/Normal hide it.


## Stable UI (0.5.0)

- [ ] Open the panel and leave it open across multiple discovery/poll cycles; header/footer and panel bounds stay in place.
- [ ] Switch modes, change ambient level and switch sources; no content-driven panel resize or button-width movement.
- [ ] Drag ambient level, then change mode using hardware/phone; drag cancels and cannot reactivate Transparency.
- [ ] Keyboard/VoiceOver controls report unavailable during operations and work again after confirmation/failure.


## macOS output routing (0.6.0)

- [ ] Set macOS output to built-in speakers or another device; click Use for audio for this Mac and confirm default output becomes the controlled headphones.
- [ ] Confirm this Mac's reported source address matches its Bluetooth controller address (diagnostics reports target-is-this-Mac).
- [ ] Switch to a phone/another Mac and confirm local output is unchanged.
- [ ] A rejected switch (call/media-link failure) must not change macOS output.
- [ ] Disconnect/change headphones during endpoint discovery; no subsequent output change may target the old headphones.
- [ ] Missing endpoint/OS rejection shows partial-success feedback, without claiming successful routing.
