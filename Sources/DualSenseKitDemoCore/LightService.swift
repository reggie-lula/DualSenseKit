import Foundation
import GameController

final class LightService {
    private weak var controllerService: ControllerService?

    init(controllerService: ControllerService) {
        self.controllerService = controllerService
    }

    @discardableResult
    func setColor(_ color: RGBColorRequest) -> Bool {
        setLightbar(LightbarRequest(r: color.r, g: color.g, b: color.b, brightness: nil))
    }

    @discardableResult
    func setLightbar(_ request: LightbarRequest) -> Bool {
        guard let light = controllerService?.connectedController?.light else { return false }
        let brightness = request.brightness.map { min(1, max(0, $0)) } ?? 1
        light.color = GCColor(
            red: Float(request.r ?? 0) / 255 * brightness,
            green: Float(request.g ?? 0) / 255 * brightness,
            blue: Float(request.b ?? 0) / 255 * brightness
        )
        return true
    }
}
