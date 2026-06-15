import Foundation
import GameController

final class LightService {
    private weak var controllerService: ControllerService?

    init(controllerService: ControllerService) {
        self.controllerService = controllerService
    }

    @discardableResult
    func setColor(_ color: RGBColorRequest) -> Bool {
        guard let light = controllerService?.connectedController?.light else { return false }
        light.color = GCColor(
            red: Float(color.r) / 255,
            green: Float(color.g) / 255,
            blue: Float(color.b) / 255
        )
        return true
    }
}
