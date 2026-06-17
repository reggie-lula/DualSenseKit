import CryptoKit
import Foundation
import Network

final class APIServer: @unchecked Sendable {
    private let configStore: ConfigStore
    private let controllerService: ControllerService
    private let lightService: LightService
    private let audioService: AudioService
    private let actionExecutor: ActionExecutor
    private let eventBus: EventBus
    private let tokenService: TokenService
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "DualSenseKitDemo.APIServer")
    private var websocketConnections: [ObjectIdentifier: NWConnection] = [:]

    init(
        configStore: ConfigStore,
        controllerService: ControllerService,
        lightService: LightService,
        audioService: AudioService,
        actionExecutor: ActionExecutor,
        eventBus: EventBus,
        tokenService: TokenService
    ) {
        self.configStore = configStore
        self.controllerService = controllerService
        self.lightService = lightService
        self.audioService = audioService
        self.actionExecutor = actionExecutor
        self.eventBus = eventBus
        self.tokenService = tokenService
        self.eventBus.subscribe { [weak self] event in
            self?.broadcast(event)
        }
    }

    func start() {
        do {
            let config = configStore.current.server
            let port = NWEndpoint.Port(rawValue: config.port)!
            let listener = try NWListener(using: .tcp, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { state in
                DiagnosticsLog.write("api listener state \(state)")
            }
            listener.start(queue: queue)
            self.listener = listener
            DiagnosticsLog.write("api listener started on port \(config.port)")
        } catch {
            NSLog("DualSenseKitDemo API server failed to start: \(error)")
            DiagnosticsLog.write("api listener failed: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        websocketConnections.values.forEach { $0.cancel() }
        websocketConnections.removeAll()
    }

    private func handle(_ connection: NWConnection) {
        guard isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        receiveHeader(on: connection)
    }

    private func receiveHeader(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }
            self.route(data: data, connection: connection)
        }
    }

    private func route(data: Data, connection: NWConnection) {
        guard let request = HTTPRequest(data: data) else {
            send(status: 400, json: ["error": "bad_request"], connection: connection)
            return
        }

        let publicPaths = ["/v1/status", "/test"]
        guard publicPaths.contains(request.path) || isAuthorized(request) else {
            send(status: 401, json: ["error": "unauthorized"], connection: connection)
            return
        }

        if request.path == "/v1/events", request.headers["upgrade"]?.lowercased() == "websocket" {
            upgradeWebSocket(request: request, connection: connection)
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/test"):
            send(status: 200, body: Data(testPageHTML().utf8), contentType: "text/html; charset=utf-8", connection: connection)

        case ("GET", "/v1/status"):
            let hid = controllerService.diagnostics().hid
            sendCodable(status: 200, value: StatusResponse(
                connectedController: controllerService.connectedControllerName,
                accessibilityTrusted: PermissionService().isAccessibilityTrusted(),
                touchpadEnabled: configStore.current.touchpad.enabled,
                audioCapability: audioService.capability(),
                dualSenseAudioOutput: audioService.dualSenseOutputDevice()?.name,
                hidConnected: hid.connected,
                hidWritable: hid.writable,
                hidStatus: hid.status,
                serverHost: configStore.current.server.host,
                serverPort: configStore.current.server.port,
                tokenFile: tokenService.tokenFilePath
            ), connection: connection)

        case ("GET", "/v1/config"):
            sendCodable(status: 200, value: configStore.current, connection: connection)

        case ("GET", "/v1/controller"):
            sendCodable(status: 200, value: controllerService.diagnostics(), connection: connection)

        case ("GET", "/v1/events/recent"):
            sendCodable(status: 200, value: eventBus.recent(), connection: connection)

        case ("GET", "/v1/hid/raw/recent"):
            sendCodable(status: 200, value: controllerService.recentRawHIDReports(), connection: connection)

        case ("PUT", "/v1/config"):
            do {
                let config = try JSONDecoder().decode(BridgeConfig.self, from: request.body)
                configStore.save(config)
                send(status: 200, json: ["ok": "true"], connection: connection)
            } catch {
                send(status: 400, json: ["error": "invalid_config"], connection: connection)
            }

        case ("PUT", "/v1/light"):
            do {
                let color = try JSONDecoder().decode(RGBColorRequest.self, from: request.body)
                let ok = lightService.setColor(color)
                send(status: ok ? 200 : 409, json: ["ok": "\(ok)"], connection: connection)
            } catch {
                send(status: 400, json: ["error": "invalid_rgb"], connection: connection)
            }

        case ("PUT", "/v1/light/player-leds"):
            do {
                let request = try JSONDecoder().decode(PlayerLEDRequest.self, from: request.body)
                guard request.mask <= 31 else {
                    send(status: 400, json: ["error": "invalid_player_led_mask"], connection: connection)
                    return
                }
                let ok = controllerService.setPlayerLEDs(mask: request.mask, brightness: request.brightness)
                send(status: ok ? 200 : 409, json: ["ok": "\(ok)"], connection: connection)
            } catch {
                send(status: 400, json: ["error": "invalid_player_led_request"], connection: connection)
            }

        case ("PUT", "/v1/light/mic-mute"):
            do {
                let request = try JSONDecoder().decode(MicMuteLEDRequest.self, from: request.body)
                let ok = controllerService.setMicMuteLED(request)
                send(status: ok ? 200 : 409, json: ["ok": "\(ok)"], connection: connection)
            } catch {
                send(status: 400, json: ["error": "invalid_mic_mute_led_request"], connection: connection)
            }

        case ("PUT", "/v1/light/lightbar"):
            do {
                let request = try JSONDecoder().decode(LightbarRequest.self, from: request.body)
                let ok = lightService.setLightbar(request)
                send(status: ok ? 200 : 409, json: ["ok": "\(ok)"], connection: connection)
            } catch {
                send(status: 400, json: ["error": "invalid_lightbar_request"], connection: connection)
            }

        case ("PUT", "/v1/haptics/rumble"):
            do {
                let request = try JSONDecoder().decode(RumbleRequest.self, from: request.body)
                let ok = controllerService.setRumble(request)
                send(status: ok ? 200 : 409, json: ["ok": "\(ok)"], connection: connection)
            } catch {
                send(status: 400, json: ["error": "invalid_rumble_request"], connection: connection)
            }

        case ("PUT", "/v1/triggers"):
            do {
                let request = try JSONDecoder().decode(TriggerRequest.self, from: request.body)
                let ok = controllerService.setTriggers(request)
                send(status: ok ? 200 : 409, json: ["ok": "\(ok)"], connection: connection)
            } catch {
                send(status: 400, json: ["error": "invalid_trigger_request"], connection: connection)
            }

        case ("POST", "/v1/test/light-sequence"):
            runLightSequence()
            send(status: 200, json: ["ok": "true"], connection: connection)

        case ("POST", "/v1/test/reset-effects"):
            controllerService.resetEffects()
            send(status: 200, json: ["ok": "true"], connection: connection)

        case ("POST", "/v1/audio/play"):
            do {
                let request = try JSONDecoder().decode(PlayAudioRequest.self, from: request.body)
                let result = audioService.play(request)
                eventBus.publish(BridgeEvent(type: "audio.play.\(result.status.rawValue)", payload: [
                    "capability": result.capability.rawValue,
                    "outputDeviceID": result.outputDeviceID.map(String.init) ?? "",
                    "outputDeviceName": result.outputDeviceName ?? "",
                    "path": result.path ?? "",
                    "message": result.message
                ]))
                sendCodable(status: 200, value: result, connection: connection)
            } catch {
                send(status: 400, json: ["error": "invalid_audio_request"], connection: connection)
            }

        case ("GET", "/v1/audio/devices"):
            let devices = audioService.devices()
            eventBus.publish(BridgeEvent(type: "audio.device.scan", payload: [
                "inputs": "\(devices.inputs.count)",
                "outputs": "\(devices.outputs.count)",
                "dualSenseAudioStatus": devices.dualSenseAudioStatus
            ]))
            sendCodable(status: 200, value: devices, connection: connection)

        case ("GET", "/v1/audio/outputs"):
            sendCodable(status: 200, value: audioService.outputDevices(), connection: connection)

        case ("POST", "/v1/audio/record/start"):
            do {
                let request = try JSONDecoder().decode(RecordAudioRequest.self, from: request.body)
                let status = audioService.startRecording(request)
                eventBus.publish(BridgeEvent(type: "audio.record.\(status.status.rawValue)", payload: [
                    "inputDeviceID": status.inputDeviceID.map(String.init) ?? "",
                    "inputDeviceName": status.inputDeviceName ?? "",
                    "outputPath": status.outputPath ?? "",
                    "message": status.message
                ]))
                sendCodable(status: 200, value: status, connection: connection)
            } catch {
                send(status: 400, json: ["error": "invalid_record_request"], connection: connection)
            }

        case ("POST", "/v1/audio/record/stop"):
            let status = audioService.stopRecording()
            eventBus.publish(BridgeEvent(type: "audio.record.\(status.status.rawValue)", payload: [
                "inputDeviceID": status.inputDeviceID.map(String.init) ?? "",
                "inputDeviceName": status.inputDeviceName ?? "",
                "outputPath": status.outputPath ?? "",
                "message": status.message
            ]))
            sendCodable(status: 200, value: status, connection: connection)

        case ("GET", "/v1/audio/record/status"):
            sendCodable(status: 200, value: audioService.recordingStatus(), connection: connection)

        case ("POST", "/v1/audio/say"):
            do {
                let request = try JSONDecoder().decode(SayAudioRequest.self, from: request.body)
                send(status: 200, json: ["capability": audioService.say(request).rawValue], connection: connection)
            } catch {
                send(status: 400, json: ["error": "invalid_say_request"], connection: connection)
            }

        case ("POST", "/v1/actions/trigger"):
            do {
                let actions = try JSONDecoder().decode([Action].self, from: request.body)
                actionExecutor.execute(actions, config: configStore.current)
                send(status: 200, json: ["ok": "true"], connection: connection)
            } catch {
                send(status: 400, json: ["error": "invalid_actions"], connection: connection)
            }

        default:
            send(status: 404, json: ["error": "not_found"], connection: connection)
        }
    }

    private func sendCodable<T: Encodable>(status: Int, value: T, connection: NWConnection) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            send(status: status, body: data, contentType: "application/json", connection: connection)
        } catch {
            send(status: 500, json: ["error": "encode_failed"], connection: connection)
        }
    }

    private func send(status: Int, json: [String: String], connection: NWConnection) {
        let data = try? JSONEncoder().encode(json)
        send(status: status, body: data ?? Data(), contentType: "application/json", connection: connection)
    }

    private func send(status: Int, body: Data, contentType: String, connection: NWConnection) {
        let reason = HTTPReason.phrase(for: status)
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func upgradeWebSocket(request: HTTPRequest, connection: NWConnection) {
        guard let key = request.headers["sec-websocket-key"] else {
            send(status: 400, json: ["error": "missing_websocket_key"], connection: connection)
            return
        }
        let accept = websocketAccept(for: key)
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(accept)\r
        \r
        
        """
        let id = ObjectIdentifier(connection)
        websocketConnections[id] = connection
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                self?.websocketConnections.removeValue(forKey: id)
            }
            if case .failed = state {
                self?.websocketConnections.removeValue(forKey: id)
            }
        }
    }

    private func websocketAccept(for key: String) -> String {
        let magic = key.trimmingCharacters(in: .whitespacesAndNewlines) + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(magic.utf8))
        return Data(digest).base64EncodedString()
    }

    private func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return true }
        switch host {
        case .ipv4(let address):
            return address.debugDescription == "127.0.0.1"
        case .ipv6(let address):
            return address.debugDescription == "::1"
        case .name(let name, _):
            return name == "localhost"
        @unknown default:
            return false
        }
    }


    private func broadcast(_ event: BridgeEvent) {
        guard let data = try? JSONEncoder().encode(event) else { return }
        let frame = websocketTextFrame(data)
        for connection in websocketConnections.values {
            connection.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    private func websocketTextFrame(_ payload: Data) -> Data {
        var frame = Data([0x81])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= UInt16.max {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xff))
            frame.append(UInt8(payload.count & 0xff))
        } else {
            frame.append(127)
            let count = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((count >> UInt64(shift)) & 0xff))
            }
        }
        frame.append(payload)
        return frame
    }

    private func runLightSequence() {
        DispatchQueue.global(qos: .userInitiated).async { [lightService, controllerService, eventBus] in
            let colors = [
                RGBColorRequest(r: 255, g: 0, b: 0),
                RGBColorRequest(r: 0, g: 255, b: 0),
                RGBColorRequest(r: 0, g: 0, b: 255),
                RGBColorRequest(r: 255, g: 255, b: 255),
                RGBColorRequest(r: 0, g: 0, b: 0)
            ]
            for color in colors {
                _ = lightService.setColor(color)
                eventBus.publish(BridgeEvent(type: "test.light.rgb", payload: [
                    "r": "\(color.r)",
                    "g": "\(color.g)",
                    "b": "\(color.b)"
                ]))
                Thread.sleep(forTimeInterval: 0.45)
            }
            for mask in [UInt8(1), 2, 4, 8, 16, 31, 0] {
                let ok = controllerService.setPlayerLEDs(mask: mask)
                eventBus.publish(BridgeEvent(type: "test.light.playerLEDs", payload: [
                    "mask": "\(mask)",
                    "ok": "\(ok)"
                ]))
                Thread.sleep(forTimeInterval: 0.45)
            }
        }
    }

    private func testPageHTML() -> String {
        let token = tokenService.token()
        return """
        <!doctype html>
        <html lang="zh-Hans">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>DualSenseKit Visual Test</title>
          <style>
            :root {
              color-scheme: light;
              --blue: #2f80ed;
              --blue-weak: #d6e6ff;
              --red: #ff4d4f;
              --orange: #ffad4d;
              --ink: #30343b;
              --muted: #6b7280;
              --line: #d7dde8;
              --panel: #ffffff;
              --bg: #f7faff;
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            }
            * { box-sizing: border-box; }
            body { margin: 0; background: var(--bg); color: var(--ink); }
            header { height: 52px; display: flex; align-items: center; padding: 0 18px; border-bottom: 1px solid var(--line); background: #fff; }
            h1 { margin: 0; color: var(--blue); font-size: 18px; }
            h2 { margin: 0 0 12px; color: var(--blue); font-size: 18px; border-left: 5px solid var(--blue); padding-left: 8px; }
            h3 { margin: 0 0 8px; color: var(--blue); font-size: 14px; }
            button, select, input[type="color"], input[type="text"] { min-height: 30px; border-radius: 999px; border: 1px solid var(--blue-weak); background: #fff; color: var(--blue); font-weight: 600; }
            button { padding: 0 12px; }
            input[type="text"] { width: 100%; padding: 0 12px; min-width: 0; }
            button.active, button:active { background: var(--blue); color: #fff; }
            input[type="range"] { width: 100%; accent-color: var(--blue); }
            label { color: var(--blue); font-weight: 700; font-size: 14px; }
            .workspace { min-height: calc(100vh - 52px); display: grid; grid-template-columns: 360px minmax(700px, 1fr); gap: 14px; padding: 14px; }
            .side-panel, .preview-panel { min-width: 0; }
            .module { background: var(--panel); border: 1px solid var(--line); border-radius: 24px; padding: 16px 18px; margin-bottom: 14px; }
            .status-grid { display: grid; grid-template-columns: 1fr auto; gap: 6px 12px; color: var(--blue); font-weight: 700; }
            .audio-note { color: var(--muted); font-size: 12px; line-height: 1.45; margin-top: 8px; }
            .audio-status { color: var(--blue); font-weight: 700; font-size: 12px; line-height: 1.45; word-break: break-word; }
            .actions { display: flex; flex-wrap: wrap; gap: 8px; }
            .control-row { display: grid; grid-template-columns: 118px 1fr; gap: 10px; align-items: center; margin: 9px 0; }
            .control-row.compact { grid-template-columns: 118px auto; }
            .segmented { display: inline-flex; border: 1px solid var(--blue-weak); border-radius: 999px; overflow: hidden; background: #fff; }
            .segmented button { border: 0; border-radius: 0; min-height: 28px; padding: 0 10px; }
            .log-tools { display: flex; gap: 8px; align-items: center; margin-bottom: 10px; }
            #packetLog { height: 210px; overflow: auto; border: 2px solid #ff2d2d; background: #fff; padding: 8px; font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre-wrap; }
            .log-entry { padding: 4px 0; border-bottom: 1px solid #eef2f7; }
            .log-entry.failure { color: var(--red); }
            .log-entry.success { color: #0f8a3b; }
            .log-entry.output { color: var(--blue); }
            .log-entry.ui { color: #8a5cf6; }
            .preview-panel { background: #fff; border: 1px solid var(--line); border-radius: 30px; padding: 18px; display: grid; grid-template-rows: auto 1fr auto; gap: 10px; }
            .preview-toolbar { display: flex; justify-content: center; }
            .preview-toolbar select { padding: 0 14px; }
            .controller-wrap { position: relative; display: grid; place-items: center; min-height: 470px; }
            svg.controller { width: min(100%, 930px); height: auto; }
            .shell { fill: #fff; stroke: #333; stroke-width: 2.2; }
            .part { fill: #fff; stroke: #444; stroke-width: 2; transition: fill .08s, stroke .08s, transform .08s; transform-box: fill-box; transform-origin: center; }
            .part.active { fill: var(--blue-weak); stroke: var(--blue); transform: scale(.94); }
            .face-symbol { fill: none; stroke: #777; stroke-width: 3; pointer-events: none; }
            .stick-dot { fill: rgba(47,128,237,.7); transition: transform .05s; }
            .trigger-fill { fill: rgba(47,128,237,.25); opacity: 0; transition: opacity .05s; }
            #touchpad-zone { fill: rgba(255,255,255,.88); stroke: #333; stroke-width: 2; }
            #touchpad-zone.active { fill: var(--blue-weak); stroke: var(--blue); }
            .finger { position: absolute; width: 28px; height: 28px; border-radius: 50%; background: rgba(47,128,237,.55); border: 2px solid #fff; box-shadow: 0 0 0 1px var(--blue); transform: translate(-50%, -50%); opacity: 0; pointer-events: none; transition: opacity .12s; }
            .finger.secondary { background: rgba(255,77,79,.45); box-shadow: 0 0 0 1px var(--red); }
            .sensor-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 18px; max-width: 820px; margin: 0 auto; width: 100%; }
            .sensor-title { text-align: center; color: var(--blue); font-weight: 800; font-size: 20px; margin-bottom: 8px; }
            .axis-row { display: grid; grid-template-columns: 82px 1fr 120px; gap: 10px; align-items: center; margin: 7px 0; font-weight: 700; }
            .axis-row.x { color: var(--blue); }
            .axis-row.y { color: var(--red); }
            .axis-row.z { color: var(--orange); }
            .axis-bar { position: relative; height: 6px; border-radius: 999px; background: currentColor; opacity: .22; }
            .axis-dot { position: absolute; top: 50%; left: 50%; width: 14px; height: 14px; border-radius: 50%; background: currentColor; transform: translate(-50%, -50%); opacity: 1; }
            .button-row { display: grid; grid-template-columns: 124px repeat(3, 1fr); gap: 5px; align-items: center; font-size: 12px; }
            .cell { min-height: 24px; border-radius: 7px; display: grid; place-items: center; background: #f0f5ff; color: var(--blue); }
            .cell.pass { background: var(--blue); color: #fff; }
            details summary { color: var(--blue); font-weight: 800; cursor: pointer; }
            @media (max-width: 980px) {
              .workspace { grid-template-columns: 1fr; }
              .sensor-grid { grid-template-columns: 1fr; }
            }
          </style>
        </head>
        <body>
          <header><h1>DualSenseKit 硬件调试台</h1></header>
          <main class="workspace">
            <aside class="side-panel">
              <section class="module">
                <h2>硬件信息</h2>
                <div id="status" class="status-grid"></div>
              </section>

              <section class="module">
                <h2>输出</h2>
                <div class="control-row compact"><label>麦克风指示灯</label><select id="micLEDMode"><option value="off">关</option><option value="on">开</option><option value="breathe">闪烁</option></select></div>
                <div class="control-row"><label>灯带颜色</label><input id="lightbarColor" type="color" value="#00ff00"></div>
                <div class="control-row"><label>灯带亮度</label><input id="lightbarBrightness" type="range" min="0" max="1" step="0.01" value="1"></div>
                <div class="actions" style="margin-bottom:8px"><button data-rgb="255,0,0">红</button><button data-rgb="0,255,0">绿</button><button data-rgb="0,0,255">蓝</button><button data-rgb="255,255,255">白</button><button data-rgb="0,0,0">关闭</button></div>
                <div class="control-row compact"><label>玩家指示灯</label><div class="segmented"><button data-mask="0">关</button><button data-mask="4">1</button><button data-mask="10">2</button><button data-mask="21">3</button><button data-mask="27">4</button><button data-mask="31">全部</button></div></div>
                <div class="control-row compact"><label>玩家灯亮度</label><div class="segmented"><button data-player-brightness="0">亮</button><button data-player-brightness="1">中</button><button data-player-brightness="2">暗</button></div></div>
                <div class="control-row"><label>震动（重）</label><input id="heavyRumble" type="range" min="0" max="1" step="0.01" value="0"></div>
                <div class="control-row"><label>震动（轻）</label><input id="lightRumble" type="range" min="0" max="1" step="0.01" value="0"></div>
                <div class="control-row compact"><label>自适应扳机（左）</label><select id="leftTriggerMode"><option value="off">关</option><option value="feedback">阻力</option><option value="weapon">单点</option><option value="vibration">连击</option><option value="slopeFeedback">渐变</option></select></div>
                <div class="control-row compact"><label>自适应扳机（右）</label><select id="rightTriggerMode"><option value="off">关</option><option value="feedback">阻力</option><option value="weapon">单点</option><option value="vibration">连击</option><option value="slopeFeedback">渐变</option></select></div>
                <div class="control-row"><label>L2 起始</label><input id="leftTriggerStart" type="range" min="0" max="0.95" step="0.01" value="0.10"></div>
                <div class="control-row"><label>L2 力度</label><input id="leftTriggerStrength" type="range" min="0" max="1" step="0.01" value="0"></div>
                <div class="control-row"><label>R2 起始</label><input id="rightTriggerStart" type="range" min="0" max="0.95" step="0.01" value="0.10"></div>
                <div class="control-row"><label>R2 力度</label><input id="rightTriggerStrength" type="range" min="0" max="1" step="0.01" value="0"></div>
                <div class="actions"><button id="stopRumble">停止震动</button><button id="disableTriggers">关闭扳机</button><button id="resetEffects">复位手柄效果</button><button id="sequence">运行灯光序列</button></div>
              </section>

              <section class="module">
                <h2>音频</h2>
                <div id="audioStatus" class="audio-status">正在扫描 CoreAudio 设备...</div>
                <div class="control-row compact"><label>输出端点</label><select id="audioOutputSelect"></select></div>
                <div class="control-row compact"><label>输入端点</label><select id="audioInputSelect"></select></div>
                <div class="control-row"><label>音频文件路径</label><input id="audioPath" type="text" placeholder="/Users/.../test.wav 或 .mp3/.m4a/.mp4"></div>
                <div class="actions"><button id="refreshAudio">刷新音频设备</button><button id="playAudioFile">播放文件</button><button id="recordAudio3s">录制 3 秒</button><button id="stopAudioRecord">停止录音</button><button id="playRecordedAudio">播放录音</button></div>
                <div id="audioRecordStatus" class="audio-note">录音：未开始</div>
                <div class="audio-note">MVP 只使用 macOS 已暴露的 CoreAudio 端点。蓝牙 HID 不作为 mp3/wav/麦克风 PCM 音频通道；如未检测到 DualSense 音频端点，会使用 Mac fallback 测试链路。</div>
              </section>

              <section class="module">
                <details>
                  <summary>按键测试</summary>
                  <div id="buttons" style="margin-top:10px"></div>
                </details>
              </section>

              <section class="module">
                <h2>发包日志</h2>
                <div class="log-tools">
                  <button id="pauseLog">暂停</button>
                  <button id="clearLog">清空</button>
                  <select id="logFilter"><option value="all">全部</option><option value="output">发包</option><option value="failure">失败</option><option value="input">输入</option><option value="ui">UI 操作</option></select>
                </div>
                <div id="packetLog"></div>
              </section>
            </aside>

            <section class="preview-panel">
              <div class="preview-toolbar"><select id="numberToggle"><option>数值显示开启</option><option>数值显示关闭</option></select></div>
              <div class="controller-wrap" id="controllerWrap">
                <svg class="controller" viewBox="0 0 1000 620" role="img" aria-label="DualSense controller preview">
                  <path class="shell" d="M178 153 C210 121 312 121 355 142 C396 128 604 128 645 142 C688 121 790 121 822 153 C886 187 912 505 852 547 C813 569 762 442 742 392 C695 380 305 380 258 392 C238 442 187 569 148 547 C88 505 114 187 178 153 Z"/>
                  <path class="part trigger" data-button="leftTrigger" d="M200 72 C222 20 286 24 298 96 L200 96 Z"/>
                  <path class="part trigger" data-button="rightTrigger" d="M702 96 C714 24 778 20 800 72 L800 96 Z"/>
                  <rect class="trigger-fill" id="leftTriggerFill" x="200" y="72" width="98" height="24" rx="4"/>
                  <rect class="trigger-fill" id="rightTriggerFill" x="702" y="72" width="98" height="24" rx="4"/>
                  <path id="touchpad-zone" data-button="touchpadButton" d="M355 142 C410 132 590 132 645 142 L618 274 C606 301 394 301 382 274 Z"/>
                  <g class="dpad">
                    <path class="part" data-button="dpadUp" d="M210 215 L238 185 L266 215 L238 246 Z"/>
                    <path class="part" data-button="dpadLeft" d="M178 248 L209 220 L238 248 L209 276 Z"/>
                    <path class="part" data-button="dpadRight" d="M266 248 L295 220 L326 248 L295 276 Z"/>
                    <path class="part" data-button="dpadDown" d="M210 282 L238 251 L266 282 L238 312 Z"/>
                  </g>
                  <g class="face">
                    <circle class="part" data-button="buttonY" cx="782" cy="205" r="31"/><path class="face-symbol" d="M782 188 L800 220 L764 220 Z"/>
                    <circle class="part" data-button="buttonX" cx="718" cy="252" r="31"/><rect class="face-symbol" x="703" y="237" width="30" height="30"/>
                    <circle class="part" data-button="buttonB" cx="846" cy="252" r="31"/><circle class="face-symbol" cx="846" cy="252" r="17"/>
                    <circle class="part" data-button="buttonA" cx="782" cy="300" r="31"/><path class="face-symbol" d="M765 284 L799 318 M799 284 L765 318"/>
                  </g>
                  <circle class="part" data-button="leftThumbstickButton" cx="335" cy="362" r="55"/>
                  <circle class="part" data-button="rightThumbstickButton" cx="665" cy="362" r="55"/>
                  <circle class="stick-dot" id="leftStickDot" cx="335" cy="362" r="12"/>
                  <circle class="stick-dot" id="rightStickDot" cx="665" cy="362" r="12"/>
                  <rect class="part" data-button="buttonMenu" x="315" y="165" width="28" height="58" rx="14" transform="rotate(-12 329 194)"/>
                  <rect class="part" data-button="buttonOptions" x="657" y="165" width="28" height="58" rx="14" transform="rotate(12 671 194)"/>
                  <path class="part" data-button="buttonHome" d="M500 331 C523 343 523 372 500 384 C477 372 477 343 500 331 Z"/>
                  <rect class="part" data-button="buttonMicrophoneMute" x="476" y="392" width="48" height="14" rx="7"/>
                  <path class="part" data-button="leftShoulder" d="M185 118 C226 102 278 103 320 123 L310 145 C263 132 223 132 176 148 Z"/>
                  <path class="part" data-button="rightShoulder" d="M680 123 C722 103 774 102 815 118 L824 148 C777 132 737 132 690 145 Z"/>
                </svg>
                <div id="finger0" class="finger"></div>
                <div id="finger1" class="finger secondary"></div>
              </div>

              <div class="sensor-grid">
                <div>
                  <div class="sensor-title">陀螺仪 raw</div>
                  <div class="axis-row x"><span>俯仰角 X</span><div class="axis-bar"><span id="gyroXDot" class="axis-dot"></span></div><span id="gyroXValue">0</span></div>
                  <div class="axis-row y"><span>偏航角 Y</span><div class="axis-bar"><span id="gyroYDot" class="axis-dot"></span></div><span id="gyroYValue">0</span></div>
                  <div class="axis-row z"><span>滚转角 Z</span><div class="axis-bar"><span id="gyroZDot" class="axis-dot"></span></div><span id="gyroZValue">0</span></div>
                </div>
                <div>
                  <div class="sensor-title">加速度计 raw</div>
                  <div class="axis-row x"><span>X</span><div class="axis-bar"><span id="accelXDot" class="axis-dot"></span></div><span id="accelXValue">0</span></div>
                  <div class="axis-row y"><span>Y</span><div class="axis-bar"><span id="accelYDot" class="axis-dot"></span></div><span id="accelYValue">0</span></div>
                  <div class="axis-row z"><span>Z</span><div class="axis-bar"><span id="accelZDot" class="axis-dot"></span></div><span id="accelZValue">0</span></div>
                </div>
              </div>
              <div id="touchCoords" style="color:var(--blue);font-weight:700;text-align:center">触控板：等待手指</div>
            </section>
          </main>
          <script>
          const TOKEN = "\(token)";
          const buttons = ["dpadUp","dpadDown","dpadLeft","dpadRight","buttonA","buttonB","buttonX","buttonY","leftShoulder","leftTrigger","rightShoulder","rightTrigger","leftThumbstickButton","rightThumbstickButton","buttonMenu","buttonOptions","buttonHome","touchpadButton","buttonMicrophoneMute"];
          const kinds = ["singleClick","doubleClick","longPress"];
          const passed = new Map(buttons.map(b => [b, new Set()]));
          const logEntries = [];
          const highRateLogTimes = new Map();
          let logPaused = false;
          let logFilter = "all";
          let currentPlayerMask = 0;
          let currentPlayerBrightness = 0;
          let rumbleTimer = null;
          let triggerTimer = null;
          const touchState = { primary: null, secondary: null };
          function authHeaders(extra = {}) { return Object.assign({"Authorization": "Bearer " + TOKEN}, extra); }
          function nowTime() { return new Date().toLocaleTimeString("zh-CN", {hour12:false}) + "." + String(new Date().getMilliseconds()).padStart(3, "0"); }
          function classify(event) {
            if (event.type === "ui.action") return "ui";
            if (event.type && event.type.startsWith("hid.output")) return event.type.endsWith("failure") ? "failure" : "output";
            if (event.type && event.type.startsWith("audio.")) return event.type.includes("failed") ? "failure" : "output";
            if (event.type && (event.type.startsWith("button.") || event.type.startsWith("hid.") || event.type.startsWith("touchpad."))) return "input";
            return "other";
          }
          function escapeHTML(value) {
            return String(value).replace(/[&<>"']/g, ch => {
              switch (ch) {
                case "&": return "&amp;";
                case "<": return "&lt;";
                case ">": return "&gt;";
                case '"': return "&quot;";
                case "'": return "&#39;";
                default: return ch;
              }
            });
          }
          function shouldLog(event) {
            if (!["hid.motion", "hid.axis", "hid.touch", "touchpad.primary", "touchpad.secondary"].includes(event.type)) return true;
            const last = highRateLogTimes.get(event.type) || 0;
            const now = Date.now();
            if (now - last < 500) return false;
            highRateLogTimes.set(event.type, now);
            return true;
          }
          function appendLog(event) {
            if (!shouldLog(event)) return;
            if (logPaused && event.type !== "ui.action") return;
            const entry = {event, cls: classify(event), time: nowTime()};
            logEntries.push(entry);
            if (logEntries.length > 500) logEntries.shift();
            renderLog();
          }
          function renderLog() {
            const root = document.querySelector("#packetLog");
            root.innerHTML = logEntries.filter(e => logFilter === "all" || e.cls === logFilter).map(e => {
              const p = e.event.payload || {};
              const detail = JSON.stringify(p);
              return '<div class="log-entry ' + e.cls + '">[' + escapeHTML(e.time) + '] ' + escapeHTML(e.event.type) + ' ' + escapeHTML(detail) + '</div>';
            }).join("");
            root.scrollTop = root.scrollHeight;
          }
          function uiAction(action, endpoint, body) { appendLog({type:"ui.action", payload:{action, endpoint, body: JSON.stringify(body)}}); }
          function setActive(button, pressed) {
            document.querySelectorAll('[data-button="' + button + '"]').forEach(el => el.classList.toggle("active", pressed));
          }
          function renderButtons() {
            const root = document.querySelector("#buttons");
            root.innerHTML = '<div class="button-row"><strong>按键</strong><strong>单击</strong><strong>双击</strong><strong>长按</strong></div>' +
              buttons.map(button => '<div class="button-row"><strong>' + button + '</strong>' +
                kinds.map(kind => '<div class="cell ' + (passed.get(button).has(kind) ? 'pass' : '') + '">' + (passed.get(button).has(kind) ? '通过' : '等待') + '</div>').join('') + '</div>').join('');
          }
          function updateAxisDot(id, raw, max) {
            const dot = document.querySelector("#" + id);
            const clamped = Math.max(-1, Math.min(1, Number(raw) / max));
            dot.style.left = ((clamped + 1) * 50).toFixed(2) + "%";
          }
          function moveStick(id, x, y) {
            const dot = document.querySelector("#" + id);
            dot.style.transform = "translate(" + (Number(x) * 24).toFixed(1) + "px," + (Number(y) * 24).toFixed(1) + "px)";
          }
          function updateTouch(name, x, y, active) {
            const key = name === "secondary" ? "secondary" : "primary";
            touchState[key] = {x:Number(x), y:Number(y), active: active === true || active === "true", at: Date.now()};
            renderTouch();
          }
          function renderTouch() {
            const zone = document.querySelector("#touchpad-zone").getBoundingClientRect();
            const wrap = document.querySelector("#controllerWrap").getBoundingClientRect();
            [["primary","finger0"],["secondary","finger1"]].forEach(([key,id]) => {
              const state = touchState[key];
              const el = document.querySelector("#" + id);
              if (!state || !state.active || Date.now() - state.at > 500) { el.style.opacity = 0; return; }
              el.style.left = (zone.left - wrap.left + state.x * zone.width) + "px";
              el.style.top = (zone.top - wrap.top + state.y * zone.height) + "px";
              el.style.opacity = 1;
            });
            const p = touchState.primary;
            const s = touchState.secondary;
            document.querySelector("#touchCoords").textContent = "触控板：" +
              ["primary", "secondary"].map(key => {
                const t = touchState[key];
                return key + "=" + (t && t.active ? (t.x.toFixed(3) + "," + t.y.toFixed(3)) : "inactive");
              }).join("  ");
          }
          setInterval(renderTouch, 250);
          function addEvent(event) {
            appendLog(event);
            if (event.type === "button.value") {
              const p = event.payload || {};
              setActive(p.button, p.pressed === "true");
            }
            if (event.type && event.type.startsWith("button.")) {
              const kind = event.type.slice("button.".length);
              const button = event.payload && event.payload.button;
              if (passed.has(button) && kinds.includes(kind)) {
                passed.get(button).add(kind);
                renderButtons();
              }
            }
            if (event.type === "hid.axis") {
              const axis = event.payload.axis;
              const value = Number(event.payload.value);
              if (axis === "leftStickX") window.leftX = value;
              if (axis === "leftStickY") window.leftY = value;
              if (axis === "rightStickX") window.rightX = value;
              if (axis === "rightStickY") window.rightY = value;
              moveStick("leftStickDot", window.leftX || 0, window.leftY || 0);
              moveStick("rightStickDot", window.rightX || 0, window.rightY || 0);
              if (axis === "leftTriggerAnalog") document.querySelector("#leftTriggerFill").style.opacity = value;
              if (axis === "rightTriggerAnalog") document.querySelector("#rightTriggerFill").style.opacity = value;
            }
            if (event.type === "hid.touch" || event.type === "touchpad.primary" || event.type === "touchpad.secondary") {
              const point = event.payload.point || (event.type.endsWith("secondary") ? "secondary" : "primary");
              updateTouch(point, event.payload.x, event.payload.y, event.payload.active ?? "true");
            }
            if (event.type === "hid.motion") {
              ["gyroX","gyroY","gyroZ","accelX","accelY","accelZ"].forEach(k => {
                const value = Number(event.payload[k] || 0);
                document.querySelector("#" + k + "Value").textContent = String(value);
                updateAxisDot(k + "Dot", value, 32768);
              });
            }
          }
          async function refreshStatus() {
            const [status, controller] = await Promise.all([
              fetch("/v1/status").then(r => r.json()),
              fetch("/v1/controller", {headers: authHeaders()}).then(r => r.json()).catch(() => null)
            ]);
            const rows = [
              ["报文序号", "-"],
              ["手柄状态", status.connectedController || "未连接"],
              ["辅助功能", String(status.accessibilityTrusted)],
              ["HID 写入", String(status.hidWritable)],
              ["GameController Light", controller && String(controller.supportsLight)],
              ["DualSense Profile", controller && String(controller.isDualSenseProfile)]
            ];
            document.querySelector("#status").innerHTML = rows.map(([k,v]) => '<span>' + k + '</span><span>' + v + '</span>').join("");
          }
          async function requestJSON(endpoint, body, action) {
            uiAction(action, endpoint, body);
            await fetch(endpoint, {method:"PUT", headers: authHeaders({"Content-Type":"application/json"}), body: JSON.stringify(body)});
            refreshStatus();
          }
          async function postJSON(endpoint, body, action) {
            uiAction(action, endpoint, body);
            const response = await fetch(endpoint, {method:"POST", headers: authHeaders({"Content-Type":"application/json"}), body: JSON.stringify(body || {})});
            const json = await response.json().catch(() => ({}));
            return json;
          }
          async function sendRumble(heavy, light, durationMs = 0) { await requestJSON("/v1/haptics/rumble", {heavy, light, durationMs}, "rumble"); }
          function triggerPayload(side) {
            return {mode: document.querySelector("#" + side + "TriggerMode").value, startPosition: Number(document.querySelector("#" + side + "TriggerStart").value), strength: Number(document.querySelector("#" + side + "TriggerStrength").value)};
          }
          async function sendTriggers() { await requestJSON("/v1/triggers", {left: triggerPayload("left"), right: triggerPayload("right")}, "triggers"); }
          async function sendPlayerMask(mask) {
            currentPlayerMask = mask;
            await requestJSON("/v1/light/player-leds", {mask, brightness: currentPlayerBrightness}, "playerLEDs");
          }
          async function sendMicLED() { await requestJSON("/v1/light/mic-mute", {mode: document.querySelector("#micLEDMode").value}, "micMuteLED"); }
          async function sendLightbar() {
            const color = document.querySelector("#lightbarColor").value;
            const body = {r: parseInt(color.slice(1,3), 16), g: parseInt(color.slice(3,5), 16), b: parseInt(color.slice(5,7), 16), brightness: Number(document.querySelector("#lightbarBrightness").value)};
            await requestJSON("/v1/light/lightbar", body, "lightbar");
          }
          let lastRecordingPath = "";
          async function refreshAudioDevices() {
            const devices = await fetch("/v1/audio/devices", {headers: authHeaders()}).then(r => r.json()).catch(() => null);
            if (!devices) return;
            const out = document.querySelector("#audioOutputSelect");
            const input = document.querySelector("#audioInputSelect");
            const outputOptions = ['<option value="">自动：优先 DualSense，否则 Mac fallback</option>'].concat((devices.outputs || []).map(d => '<option value="' + d.id + '">' + escapeHTML(d.name) + (d.isDefaultOutput ? '（默认）' : '') + (d.isDualSenseCandidate ? '（DualSense 候选）' : '') + '</option>'));
            const inputOptions = ['<option value="">自动：优先 DualSense，否则 Mac fallback</option>'].concat((devices.inputs || []).map(d => '<option value="' + d.id + '">' + escapeHTML(d.name) + (d.isDefaultInput ? '（默认）' : '') + (d.isDualSenseCandidate ? '（DualSense 候选）' : '') + '</option>'));
            out.innerHTML = outputOptions.join("");
            input.innerHTML = inputOptions.join("");
            document.querySelector("#audioStatus").textContent = "DualSense 音频状态：" + devices.dualSenseAudioStatus + "；输出 " + (devices.outputs || []).length + " 个，输入 " + (devices.inputs || []).length + " 个";
          }
          async function playAudioFile(pathOverride) {
            const selected = document.querySelector("#audioOutputSelect").value;
            const path = pathOverride || document.querySelector("#audioPath").value;
            const body = {path, useMacFallback: true};
            if (selected) body.outputDeviceID = Number(selected);
            const result = await postJSON("/v1/audio/play", body, "audio.play");
            document.querySelector("#audioRecordStatus").textContent = "播放：" + (result.status || "unknown") + " " + (result.message || "");
          }
          async function recordAudio(durationMs) {
            const selected = document.querySelector("#audioInputSelect").value;
            const body = {useMacFallback: true, durationMs};
            if (selected) body.inputDeviceID = Number(selected);
            const result = await postJSON("/v1/audio/record/start", body, "audio.record.start");
            if (result.outputPath) lastRecordingPath = result.outputPath;
            document.querySelector("#audioRecordStatus").textContent = "录音：" + (result.status || "unknown") + " " + (result.message || "") + (result.outputPath ? " -> " + result.outputPath : "");
            if (durationMs) setTimeout(refreshRecordStatus, durationMs + 400);
          }
          async function stopRecord() {
            const result = await postJSON("/v1/audio/record/stop", {}, "audio.record.stop");
            if (result.outputPath) lastRecordingPath = result.outputPath;
            document.querySelector("#audioRecordStatus").textContent = "录音：" + (result.status || "unknown") + " " + (result.message || "") + (result.outputPath ? " -> " + result.outputPath : "");
          }
          async function refreshRecordStatus() {
            const result = await fetch("/v1/audio/record/status", {headers: authHeaders()}).then(r => r.json()).catch(() => null);
            if (!result) return;
            if (result.outputPath) lastRecordingPath = result.outputPath;
            document.querySelector("#audioRecordStatus").textContent = "录音：" + result.status + " " + result.message + (result.outputPath ? " -> " + result.outputPath : "");
          }
          ["heavyRumble","lightRumble"].forEach(id => document.querySelector("#" + id).addEventListener("input", () => {
            clearTimeout(rumbleTimer);
            rumbleTimer = setTimeout(() => sendRumble(Number(document.querySelector("#heavyRumble").value), Number(document.querySelector("#lightRumble").value), 1000), 60);
          }));
          ["leftTriggerMode","rightTriggerMode"].forEach(id => document.querySelector("#" + id).addEventListener("change", sendTriggers));
          ["leftTriggerStart","leftTriggerStrength","rightTriggerStart","rightTriggerStrength"].forEach(id => document.querySelector("#" + id).addEventListener("input", () => {
            clearTimeout(triggerTimer);
            triggerTimer = setTimeout(sendTriggers, 80);
          }));
          document.querySelector("#lightbarBrightness").addEventListener("input", sendLightbar);
          document.querySelector("#lightbarColor").addEventListener("input", sendLightbar);
          document.querySelector("#micLEDMode").addEventListener("change", sendMicLED);
          document.querySelector("#refreshAudio").addEventListener("click", refreshAudioDevices);
          document.querySelector("#playAudioFile").addEventListener("click", () => playAudioFile(""));
          document.querySelector("#recordAudio3s").addEventListener("click", () => recordAudio(3000));
          document.querySelector("#stopAudioRecord").addEventListener("click", stopRecord);
          document.querySelector("#playRecordedAudio").addEventListener("click", () => lastRecordingPath ? playAudioFile(lastRecordingPath) : appendLog({type:"audio.play.noRecording", payload:{message:"no recording path"}}));
          document.querySelector("#pauseLog").addEventListener("click", () => { logPaused = !logPaused; document.querySelector("#pauseLog").textContent = logPaused ? "继续" : "暂停"; });
          document.querySelector("#clearLog").addEventListener("click", () => { logEntries.length = 0; renderLog(); });
          document.querySelector("#logFilter").addEventListener("change", event => { logFilter = event.target.value; renderLog(); });
          document.addEventListener("click", async event => {
            if (event.target.dataset.rgb) {
              const [r,g,b] = event.target.dataset.rgb.split(",").map(Number);
              document.querySelector("#lightbarColor").value = "#" + [r,g,b].map(v => v.toString(16).padStart(2, "0")).join("");
              await sendLightbar();
            }
            if (event.target.dataset.mask !== undefined) await sendPlayerMask(Number(event.target.dataset.mask));
            if (event.target.dataset.playerBrightness !== undefined) {
              currentPlayerBrightness = Number(event.target.dataset.playerBrightness);
              await sendPlayerMask(currentPlayerMask);
            }
            if (event.target.id === "sequence") {
              uiAction("light-sequence", "/v1/test/light-sequence", {});
              await fetch("/v1/test/light-sequence", {method:"POST", headers: authHeaders()});
            }
            if (event.target.id === "stopRumble") {
              document.querySelector("#heavyRumble").value = "0";
              document.querySelector("#lightRumble").value = "0";
              await sendRumble(0, 0, 0);
            }
            if (event.target.id === "disableTriggers") {
              document.querySelector("#leftTriggerMode").value = "off";
              document.querySelector("#rightTriggerMode").value = "off";
              await requestJSON("/v1/triggers", {left:{mode:"off"}, right:{mode:"off"}}, "disableTriggers");
            }
            if (event.target.id === "resetEffects") {
              uiAction("reset-effects", "/v1/test/reset-effects", {});
              await fetch("/v1/test/reset-effects", {method:"POST", headers: authHeaders()});
            }
          });
          async function loadRecent() {
            const recent = await fetch("/v1/events/recent", {headers: authHeaders()}).then(r => r.json()).catch(() => []);
            recent.forEach(addEvent);
          }
          function connectEvents() {
            const ws = new WebSocket("ws://" + location.host + "/v1/events?token=" + encodeURIComponent(TOKEN));
            ws.onmessage = message => addEvent(JSON.parse(message.data));
            ws.onclose = () => setTimeout(connectEvents, 1000);
          }
          renderButtons();
          refreshStatus();
          refreshAudioDevices();
          loadRecent();
          connectEvents();
          setInterval(refreshStatus, 1500);
          </script>
        </body>
        </html>
        """
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        if tokenService.isAuthorized(headers: request.headers) {
            return true
        }
        return request.query["token"] == tokenService.token()
    }
}

private struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    init?(data: Data) {
        guard let raw = String(data: data, encoding: .utf8),
              let range = raw.range(of: "\r\n\r\n") else { return nil }
        let headerText = String(raw[..<range.lowerBound])
        let bodyStart = raw[range.upperBound...].utf8.count
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0])
        let rawPath = String(parts[1])
        if let separator = rawPath.firstIndex(of: "?") {
            path = String(rawPath[..<separator])
            query = Self.parseQuery(String(rawPath[rawPath.index(after: separator)...]))
        } else {
            path = rawPath
            query = [:]
        }
        var parsedHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            parsedHeaders[key] = value
        }
        headers = parsedHeaders
        let headerLength = Data(raw[..<range.upperBound].utf8).count
        body = data.count > headerLength ? data.dropFirst(headerLength) : Data()
        if let contentLength = headers["content-length"].flatMap(Int.init), body.count > contentLength {
            body = body.prefix(contentLength)
        }
        _ = bodyStart
    }

    private static func parseQuery(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first?.removingPercentEncoding else { continue }
            let value = parts.count > 1 ? parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "" : ""
            result[key] = value
        }
        return result
    }
}

private enum HTTPReason {
    static func phrase(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 409: "Conflict"
        case 500: "Internal Server Error"
        default: "OK"
        }
    }
}
