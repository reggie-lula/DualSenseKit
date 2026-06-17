import Foundation

final class ButtonGestureRecognizer: @unchecked Sendable {
    typealias Emit = (ButtonGesture) -> Void

    private struct ButtonState {
        var isPressed = false
        var downDate: Date?
        var pendingSingleWorkItem: DispatchWorkItem?
    }

    private let queue = DispatchQueue(label: "DualSenseKitDemo.ButtonGestureRecognizer")
    private var states: [ControllerButton: ButtonState] = [:]
    private let configProvider: () -> GestureTimingConfig
    private let emit: Emit

    init(configProvider: @escaping () -> GestureTimingConfig, emit: @escaping Emit) {
        self.configProvider = configProvider
        self.emit = emit
    }

    func update(button: ControllerButton, pressed: Bool, value: Float = 1) {
        queue.async {
            var state = self.states[button] ?? ButtonState()
            guard state.isPressed != pressed else { return }
            state.isPressed = pressed
            let config = self.configProvider()

            if pressed {
                state.downDate = Date()
                self.emit(ButtonGesture(button: button, kind: .press))
            } else {
                self.emit(ButtonGesture(button: button, kind: .release))
                let heldMilliseconds = Date().timeIntervalSince(state.downDate ?? Date()) * 1000
                if heldMilliseconds >= Double(config.longPressMilliseconds) {
                    state.pendingSingleWorkItem?.cancel()
                    state.pendingSingleWorkItem = nil
                    self.emit(ButtonGesture(button: button, kind: .longPress))
                } else if let pending = state.pendingSingleWorkItem {
                    pending.cancel()
                    state.pendingSingleWorkItem = nil
                    self.emit(ButtonGesture(button: button, kind: .doubleClick))
                } else {
                    let workItem = DispatchWorkItem { [weak self] in
                        self?.emit(ButtonGesture(button: button, kind: .singleClick))
                    }
                    state.pendingSingleWorkItem = workItem
                    self.queue.asyncAfter(
                        deadline: .now() + .milliseconds(config.doubleClickWindowMilliseconds),
                        execute: workItem
                    )
                }
                state.downDate = nil
            }

            self.states[button] = state
        }
    }
}
