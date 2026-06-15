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
    private let queue = DispatchQueue(label: "DualSenseBridge.APIServer")
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
            NSLog("DualSenseBridge API server failed to start: \(error)")
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
                let ok = controllerService.setLightbar(request)
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
                send(status: 200, json: ["capability": audioService.play(request).rawValue], connection: connection)
            } catch {
                send(status: 400, json: ["error": "invalid_audio_request"], connection: connection)
            }

        case ("GET", "/v1/audio/outputs"):
            sendCodable(status: 200, value: audioService.outputDevices(), connection: connection)

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
          <title>DualSenseBridge Test</title>
          <style>
            :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
            body { margin: 0; background: Canvas; color: CanvasText; }
            header { position: sticky; top: 0; padding: 14px 18px; border-bottom: 1px solid color-mix(in srgb, CanvasText 16%, transparent); background: Canvas; z-index: 2; }
            h1 { margin: 0; font-size: 20px; }
            main { max-width: 1180px; margin: 0 auto; padding: 18px; display: grid; gap: 18px; }
            section { border: 1px solid color-mix(in srgb, CanvasText 14%, transparent); border-radius: 8px; padding: 14px; }
            h2 { margin: 0 0 12px; font-size: 15px; }
            .grid { display: grid; gap: 10px; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); }
            .pill { display: inline-flex; align-items: center; gap: 8px; padding: 6px 8px; border-radius: 999px; background: color-mix(in srgb, CanvasText 8%, transparent); font-size: 13px; }
            .ok { color: #16833a; }
            .bad { color: #c53030; }
            .button-row { display: grid; grid-template-columns: 150px repeat(3, 1fr); gap: 6px; align-items: center; font-size: 13px; }
            .cell { min-height: 28px; border-radius: 6px; display: grid; place-items: center; background: color-mix(in srgb, CanvasText 7%, transparent); }
            .cell.pass { background: color-mix(in srgb, #21a366 26%, transparent); color: CanvasText; }
            button { min-height: 32px; border-radius: 6px; border: 1px solid color-mix(in srgb, CanvasText 18%, transparent); background: ButtonFace; color: ButtonText; }
            .actions { display: flex; flex-wrap: wrap; gap: 8px; }
            .control-grid { display: grid; gap: 12px; grid-template-columns: repeat(auto-fit, minmax(230px, 1fr)); }
            label { display: grid; gap: 6px; font-size: 13px; }
            input[type="range"] { width: 100%; }
            select { min-height: 32px; border-radius: 6px; }
            .checks { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; }
            .checks label { display: inline-flex; grid-template-columns: none; align-items: center; gap: 4px; }
            pre { margin: 0; max-height: 260px; overflow: auto; font-size: 12px; line-height: 1.45; white-space: pre-wrap; }
          </style>
        </head>
        <body>
          <header><h1>DualSenseBridge 硬件测试 MVP</h1></header>
          <main>
            <section>
              <h2>状态</h2>
              <div id="status" class="grid"></div>
            </section>
            <section>
              <h2>按键测试</h2>
              <div id="buttons"></div>
            </section>
            <section>
              <h2>灯光测试</h2>
              <div class="actions">
                <button data-rgb="255,0,0">红</button>
                <button data-rgb="0,255,0">绿</button>
                <button data-rgb="0,0,255">蓝</button>
                <button data-rgb="255,255,255">白</button>
                <button data-rgb="0,0,0">关闭 RGB</button>
                <button id="sequence">运行序列</button>
              </div>
              <div class="actions" style="margin-top:10px">
                <button data-mask="4">玩家 1</button>
                <button data-mask="10">玩家 2</button>
                <button data-mask="21">玩家 3</button>
                <button data-mask="27">玩家 4</button>
                <button data-mask="31">全亮</button>
                <button data-mask="0">全灭</button>
              </div>
              <div class="control-grid" style="margin-top:10px">
                <label>状态灯亮度 <span id="playerBrightnessValue">0</span><input id="playerBrightness" type="range" min="0" max="2" step="1" value="0"></label>
                <label>警灯亮度 <span id="lightbarBrightnessValue">1.00</span><input id="lightbarBrightness" type="range" min="0" max="1" step="0.01" value="1"></label>
                <label>静音灯
                  <select id="micLEDMode">
                    <option value="off">关闭</option>
                    <option value="on">常亮</option>
                    <option value="breathe">呼吸/闪烁</option>
                  </select>
                </label>
                <label>警灯颜色 <input id="lightbarColor" type="color" value="#00ff00"></label>
              </div>
              <div class="checks" style="margin-top:10px">
                <strong>状态灯自由组合</strong>
                <label><input type="checkbox" class="playerCheck" value="1">灯 1</label>
                <label><input type="checkbox" class="playerCheck" value="2">灯 2</label>
                <label><input type="checkbox" class="playerCheck" value="4">灯 3</label>
              </div>
            </section>
            <section>
              <h2>马达与扳机</h2>
              <div class="control-grid">
                <label>重马达 <span id="heavyRumbleValue">0</span><input id="heavyRumble" type="range" min="0" max="1" step="0.01" value="0"></label>
                <label>轻马达 <span id="lightRumbleValue">0</span><input id="lightRumble" type="range" min="0" max="1" step="0.01" value="0"></label>
                <label>L2 模式
                  <select id="leftTriggerMode">
                    <option value="off">关闭</option>
                    <option value="feedback">阻力</option>
                    <option value="weapon">单点</option>
                    <option value="vibration">连击</option>
                    <option value="slopeFeedback">渐变阻力</option>
                  </select>
                </label>
                <label>R2 模式
                  <select id="rightTriggerMode">
                    <option value="off">关闭</option>
                    <option value="feedback">阻力</option>
                    <option value="weapon">单点</option>
                    <option value="vibration">连击</option>
                    <option value="slopeFeedback">渐变阻力</option>
                  </select>
                </label>
                <label>L2 起始 <span id="leftTriggerStartValue">0.10</span><input id="leftTriggerStart" type="range" min="0" max="0.95" step="0.01" value="0.10"></label>
                <label>L2 终点 <span id="leftTriggerEndValue">0.80</span><input id="leftTriggerEnd" type="range" min="0" max="1" step="0.01" value="0.80"></label>
                <label>L2 力度 <span id="leftTriggerStrengthValue">0</span><input id="leftTriggerStrength" type="range" min="0" max="1" step="0.01" value="0"></label>
                <label>L2 频率 <span id="leftTriggerFrequencyValue">10</span><input id="leftTriggerFrequency" type="range" min="0" max="30" step="1" value="10"></label>
                <label>R2 起始 <span id="rightTriggerStartValue">0.10</span><input id="rightTriggerStart" type="range" min="0" max="0.95" step="0.01" value="0.10"></label>
                <label>R2 终点 <span id="rightTriggerEndValue">0.80</span><input id="rightTriggerEnd" type="range" min="0" max="1" step="0.01" value="0.80"></label>
                <label>R2 力度 <span id="rightTriggerStrengthValue">0</span><input id="rightTriggerStrength" type="range" min="0" max="1" step="0.01" value="0"></label>
                <label>R2 频率 <span id="rightTriggerFrequencyValue">10</span><input id="rightTriggerFrequency" type="range" min="0" max="30" step="1" value="10"></label>
              </div>
              <div class="actions" style="margin-top:10px">
                <button id="stopRumble">停止震动</button>
                <button id="disableTriggers">关闭扳机</button>
                <button id="resetEffects">复位手柄效果</button>
              </div>
            </section>
            <section>
              <h2>事件</h2>
              <pre id="events"></pre>
            </section>
          </main>
          <script>
          const TOKEN = "\(token)";
          const buttons = [
            "dpadUp","dpadDown","dpadLeft","dpadRight",
            "buttonA","buttonB","buttonX","buttonY",
            "leftShoulder","leftTrigger","rightShoulder","rightTrigger",
            "leftThumbstickButton","rightThumbstickButton",
            "buttonMenu","buttonOptions","buttonHome","touchpadButton","buttonMicrophoneMute"
          ];
          const kinds = ["singleClick","doubleClick","longPress"];
          const passed = new Map(buttons.map(b => [b, new Set()]));
          const eventsEl = document.querySelector("#events");
          function authHeaders(extra = {}) {
            return Object.assign({"Authorization": "Bearer " + TOKEN}, extra);
          }
          function renderButtons() {
            const root = document.querySelector("#buttons");
            root.innerHTML = '<div class="button-row"><strong>按键</strong><strong>单击</strong><strong>双击</strong><strong>长按</strong></div>' +
              buttons.map(button => '<div class="button-row"><strong>' + button + '</strong>' +
                kinds.map(kind => '<div class="cell ' + (passed.get(button).has(kind) ? 'pass' : '') + '">' + (passed.get(button).has(kind) ? '通过' : '等待') + '</div>').join('') +
                '</div>').join('');
          }
          function addEvent(event) {
            if (event.type && event.type.startsWith("button.")) {
              const kind = event.type.slice("button.".length);
              const button = event.payload && event.payload.button;
              if (passed.has(button) && kinds.includes(kind)) {
                passed.get(button).add(kind);
                renderButtons();
              }
            }
            eventsEl.textContent = JSON.stringify(event, null, 2) + "\\n" + eventsEl.textContent;
          }
          async function refreshStatus() {
            const [status, controller] = await Promise.all([
              fetch("/v1/status").then(r => r.json()),
              fetch("/v1/controller", {headers: authHeaders()}).then(r => r.json()).catch(() => null)
            ]);
            document.querySelector("#status").innerHTML = [
              ["手柄", status.connectedController || "未连接", !!status.connectedController],
              ["辅助功能", String(status.accessibilityTrusted), status.accessibilityTrusted],
              ["HID", status.hidStatus, status.hidConnected],
              ["HID 写入", String(status.hidWritable), status.hidWritable],
              ["GameController Light", controller && String(controller.supportsLight), controller && controller.supportsLight],
              ["DualSense Profile", controller && String(controller.isDualSenseProfile), controller && controller.isDualSenseProfile]
            ].map(([k,v,ok]) => '<span class="pill"><strong>' + k + '</strong><span class="' + (ok ? 'ok' : 'bad') + '">' + v + '</span></span>').join('');
          }
          async function loadRecent() {
            const recent = await fetch("/v1/events/recent", {headers: authHeaders()}).then(r => r.json()).catch(() => []);
            recent.forEach(addEvent);
          }
          function connectEvents() {
            const ws = new WebSocket("ws://" + location.host + "/v1/events?token=" + encodeURIComponent(TOKEN));
            ws.onmessage = message => addEvent(JSON.parse(message.data));
            ws.onclose = () => setTimeout(connectEvents, 1000);
          }
          let rumbleTimer = null;
          let triggerTimer = null;
          let currentPlayerMask = 0;
          function rangeNumber(id) { return Number(document.querySelector("#" + id).value); }
          function updateValue(id) {
            const input = document.querySelector("#" + id);
            const output = document.querySelector("#" + id + "Value");
            output.textContent = Number(input.value).toFixed(2);
          }
          function bindValue(id) {
            const input = document.querySelector("#" + id);
            input.addEventListener("input", () => updateValue(id));
            updateValue(id);
          }
          async function sendRumble(heavy, light, durationMs = 0) {
            await fetch("/v1/haptics/rumble", {
              method:"PUT",
              headers: authHeaders({"Content-Type":"application/json"}),
              body: JSON.stringify({heavy, light, durationMs})
            });
            refreshStatus();
          }
          function triggerPayload(side) {
            const mode = document.querySelector("#" + side + "TriggerMode").value;
            return {
              mode,
              startPosition: rangeNumber(side + "TriggerStart"),
              endPosition: rangeNumber(side + "TriggerEnd"),
              strength: rangeNumber(side + "TriggerStrength"),
              endStrength: rangeNumber(side + "TriggerStrength"),
              amplitude: rangeNumber(side + "TriggerStrength"),
              frequency: rangeNumber(side + "TriggerFrequency")
            };
          }
          async function sendTriggers() {
            await fetch("/v1/triggers", {
              method:"PUT",
              headers: authHeaders({"Content-Type":"application/json"}),
              body: JSON.stringify({
                left: triggerPayload("left"),
                right: triggerPayload("right")
              })
            });
          }
          async function sendPlayerMask(mask) {
            currentPlayerMask = mask;
            document.querySelectorAll(".playerCheck").forEach(el => {
              el.checked = (mask & Number(el.value)) !== 0;
            });
            await fetch("/v1/light/player-leds", {
              method:"PUT",
              headers: authHeaders({"Content-Type":"application/json"}),
              body: JSON.stringify({mask, brightness: Number(document.querySelector("#playerBrightness").value)})
            });
          }
          async function sendPlayerChecks() {
            const mask = [...document.querySelectorAll(".playerCheck:checked")].reduce((sum, el) => sum | Number(el.value), 0);
            await sendPlayerMask(mask);
          }
          async function sendMicLED() {
            await fetch("/v1/light/mic-mute", {
              method:"PUT",
              headers: authHeaders({"Content-Type":"application/json"}),
              body: JSON.stringify({mode: document.querySelector("#micLEDMode").value})
            });
          }
          async function sendLightbar() {
            const color = document.querySelector("#lightbarColor").value;
            const r = parseInt(color.slice(1,3), 16);
            const g = parseInt(color.slice(3,5), 16);
            const b = parseInt(color.slice(5,7), 16);
            const brightness = rangeNumber("lightbarBrightness");
            await fetch("/v1/light/lightbar", {
              method:"PUT",
              headers: authHeaders({"Content-Type":"application/json"}),
              body: JSON.stringify({r, g, b, brightness})
            });
          }
          ["heavyRumble","lightRumble","playerBrightness","lightbarBrightness","leftTriggerStart","leftTriggerEnd","leftTriggerStrength","leftTriggerFrequency","rightTriggerStart","rightTriggerEnd","rightTriggerStrength","rightTriggerFrequency"].forEach(bindValue);
          ["heavyRumble","lightRumble"].forEach(id => {
            document.querySelector("#" + id).addEventListener("input", () => {
              clearTimeout(rumbleTimer);
              rumbleTimer = setTimeout(() => sendRumble(rangeNumber("heavyRumble"), rangeNumber("lightRumble"), 1000), 80);
            });
          });
          ["leftTriggerMode","rightTriggerMode"].forEach(id => {
            document.querySelector("#" + id).addEventListener("change", sendTriggers);
          });
          ["leftTriggerStart","leftTriggerEnd","leftTriggerStrength","leftTriggerFrequency","rightTriggerStart","rightTriggerEnd","rightTriggerStrength","rightTriggerFrequency"].forEach(id => {
            document.querySelector("#" + id).addEventListener("input", () => {
              clearTimeout(triggerTimer);
              triggerTimer = setTimeout(sendTriggers, 80);
            });
          });
          document.querySelector("#playerBrightness").addEventListener("input", () => sendPlayerMask(currentPlayerMask));
          document.querySelector("#lightbarBrightness").addEventListener("input", sendLightbar);
          document.querySelector("#lightbarColor").addEventListener("input", sendLightbar);
          document.querySelector("#micLEDMode").addEventListener("change", sendMicLED);
          document.querySelectorAll(".playerCheck").forEach(el => el.addEventListener("change", sendPlayerChecks));
          document.addEventListener("click", async event => {
            const rgb = event.target.dataset.rgb;
            const mask = event.target.dataset.mask;
            const micLED = event.target.dataset.micLed;
            if (rgb) {
              const [r,g,b] = rgb.split(",").map(Number);
              const brightness = rangeNumber("lightbarBrightness");
              await fetch("/v1/light/lightbar", {method:"PUT", headers: authHeaders({"Content-Type":"application/json"}), body: JSON.stringify({r,g,b,brightness})});
            }
            if (mask !== undefined) {
              await sendPlayerMask(Number(mask));
            }
            if (event.target.id === "sequence") {
              await fetch("/v1/test/light-sequence", {method:"POST", headers: authHeaders()});
            }
            if (event.target.id === "stopRumble") {
              document.querySelector("#heavyRumble").value = "0";
              document.querySelector("#lightRumble").value = "0";
              updateValue("heavyRumble");
              updateValue("lightRumble");
              await sendRumble(0, 0, 0);
            }
            if (event.target.id === "disableTriggers") {
              document.querySelector("#leftTriggerMode").value = "off";
              document.querySelector("#rightTriggerMode").value = "off";
              document.querySelector("#leftTriggerStrength").value = "0";
              document.querySelector("#rightTriggerStrength").value = "0";
              updateValue("leftTriggerStrength");
              updateValue("rightTriggerStrength");
              await fetch("/v1/triggers", {
                method:"PUT",
                headers: authHeaders({"Content-Type":"application/json"}),
                body: JSON.stringify({left:{mode:"off"}, right:{mode:"off"}})
              });
            }
            if (event.target.id === "resetEffects") {
              await fetch("/v1/test/reset-effects", {method:"POST", headers: authHeaders()});
            }
            refreshStatus();
          });
          renderButtons();
          refreshStatus();
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
