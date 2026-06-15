# DualSenseKit

DualSenseKit is a Swift SDK for parsing and controlling Sony DualSense controllers, with a macOS MVP demo app for local hardware testing.

## Features

- Uses the DualSense touchpad as a mouse surface.
- Maps controller buttons, including PS/Home, Menu, Options, L1/L2/R1/R2, sticks, D-pad, face buttons, and touchpad button, to actions.
- Supports single-click, double-click, long-press, press, and release gestures.
- Provides local HTTP and WebSocket APIs on `127.0.0.1:17395`.
- Controls controller RGB light through Apple's `GameController` light API when available.
- Provides a local browser hardware test panel at `http://127.0.0.1:17395/test`.
- Adds a minimal DualSense HID path for the microphone mute button and 5 player LEDs.
- Includes `DualSenseKit`, a reusable Swift protocol layer for DualSense HID input parsing and output report encoding.
- Detects DualSense audio capability and falls back cleanly when controller speaker output is unsupported.
- Runs as an accessory/menu-bar app with no Dock icon.

## Build

The current Command Line Tools install in this environment hangs in SwiftPM's final executable link step, so the checked-in build path compiles with `swiftc` and links with `clang` directly:

```sh
scripts/build.sh
```

The executable is written to:

```sh
.manual-build/DualSenseKitDemo
```

The menu-bar app bundle is written to:

```sh
.manual-build/DualSenseKitDemo.app
```

For MVP hardware testing in this local CLT environment, start the headless server:

```sh
.manual-build/DualSenseKitDemo --headless-server
```

Then open:

```sh
http://127.0.0.1:17395/test
```

For macOS Accessibility permissions, install the app to a stable path before granting permission:

```sh
scripts/install.sh
open -n ~/Applications/DualSenseKitDemo.app
```

Note: this local unsigned/ad-hoc bundle can be killed by macOS on some builds. The headless executable above is the verified MVP test path in this workspace.

If you previously granted permission to a development build, remove the old `DualSenseKitDemo` entry from System Settings, then add `~/Applications/DualSenseKitDemo.app` and enable it. Rebuilding into `.manual-build` can change the ad-hoc signature and invalidate the old TCC entry.

## Test

This CLT install does not include `XCTest` or Swift Testing modules. Use the dependency-free self-test:

```sh
scripts/test.sh
```

It verifies config JSON round-tripping, RGB/player LED payloads, shell whitelist behavior, touchpad delta mapping, gesture timing, and HID special-button parsing.

## SDK

The reusable SDK target lives in:

```sh
Sources/DualSenseKit
```

It exposes:

- `DualSenseProtocol.parseInputReport(_:)` for DualSense USB/Bluetooth input reports.
- `DualSenseProtocol.dpadButtons(from:)` for hat-switch decoding.
- `DualSenseOutputState` for stateful output-report composition.
- `DualSenseProtocol.apply(_:to:)` for player LEDs, mic mute LED, rumble, lightbar, and reset effects.
- `DualSenseProtocol.bluetoothOutputReport(state:sequence:)` and `usbOutputReport(state:)`.

Example:

```swift
import DualSenseKit

var state = DualSenseOutputState()
DualSenseProtocol.apply(.playerLEDs(mask: 0x1f), to: &state)
let report = DualSenseProtocol.bluetoothOutputReport(state: state, sequence: 0)
```

The SDK protocol layout is cross-checked against the public WebHID implementation in [daidr/dualsense-tester](https://github.com/daidr/dualsense-tester), especially `sendOutputReportFactory`, `OutputStruct`, input offsets, and Bluetooth CRC32 behavior.

## Runtime Verification

Start the verified MVP server:

```sh
.manual-build/DualSenseKitDemo --headless-server
```

Read status:

```sh
curl -s http://127.0.0.1:17395/v1/status
```

Read controller diagnostics:

```sh
TOKEN="$(cat ~/Library/Application\ Support/DualSenseKitDemo/api-token)"
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:17395/v1/controller
```

Set the controller light:

```sh
curl -s -X PUT \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"r":255,"g":0,"b":0}' \
  http://127.0.0.1:17395/v1/light
```

Set the 5 player LEDs:

```sh
curl -s -X PUT \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"mask":31}' \
  http://127.0.0.1:17395/v1/light/player-leds
```

Run the MVP light sequence:

```sh
curl -s -X POST \
  -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:17395/v1/test/light-sequence
```

List audio outputs:

```sh
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:17395/v1/audio/outputs
```

When a DualSense output device is available, `/v1/audio/play` and `/v1/audio/say` temporarily route the system default output to the controller, play the sound, then restore the previous default output. If no DualSense output is available, calls return `unsupported` unless `useMacFallback` is true.

If mouse or keyboard injection does not work, grant Accessibility permission to the built app in System Settings. The status response includes `accessibilityTrusted`.

Startup diagnostics are written to:

```sh
~/Library/Application Support/DualSenseKitDemo/diagnostics.log
```

## API

`GET /v1/status` is unauthenticated so clients can discover health and the token file path. All other endpoints require one of:

```sh
Authorization: Bearer "$(cat ~/Library/Application\ Support/DualSenseKitDemo/api-token)"
X-DualSenseKitDemo-Token: "$(cat ~/Library/Application\ Support/DualSenseKitDemo/api-token)"
```

The server rejects accepted connections whose remote endpoint is not loopback.

- `GET /test`
- `GET /v1/status`
- `GET /v1/config`
- `GET /v1/controller`
- `GET /v1/events/recent`
- `GET /v1/hid/raw/recent`
- `PUT /v1/config`
- `PUT /v1/light` with `{"r":255,"g":80,"b":0}`
- `PUT /v1/light/lightbar` with `{"r":0,"g":255,"b":0,"brightness":1.0}`
- `PUT /v1/light/player-leds` with `{"mask":31,"brightness":0}` where brightness is `0` high, `1` medium, `2` low
- `PUT /v1/light/mic-mute` with `{"mode":"off"|"on"|"breathe"}` or legacy `{"on":true}`
- `PUT /v1/haptics/rumble` with `{"heavy":0.4,"light":0.2,"durationMs":1000}`; legacy `left/right` is still accepted
- `PUT /v1/triggers` with `{"left":{"mode":"feedback"|"weapon"|"vibration"|"slopeFeedback"|"off","startPosition":0.1,"endPosition":0.8,"strength":0.5,"frequency":10},"right":{"mode":"off"}}`
- `POST /v1/test/light-sequence`
- `POST /v1/test/reset-effects`
- `POST /v1/audio/play`
- `GET /v1/audio/outputs`
- `POST /v1/audio/say`
- `POST /v1/actions/trigger`
- `WS /v1/events`

Configuration is stored at:

```sh
~/Library/Application Support/DualSenseKitDemo/config.json
```

The local API token is stored in Keychain and mirrored for developer clients at:

```sh
~/Library/Application Support/DualSenseKitDemo/api-token
```
