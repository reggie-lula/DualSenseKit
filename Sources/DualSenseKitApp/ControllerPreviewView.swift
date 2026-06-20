import AppKit
import DualSenseKitRuntime

final class ControllerPreviewView: NSView {
    var selectedButton: ControllerButton = .dpadRight {
        didSet { needsDisplay = true }
    }
    var onSelectButton: ((ControllerButton) -> Void)?

    private let accent = NSColor(calibratedRed: 0.12, green: 0.48, blue: 0.88, alpha: 1)
    private let ink = NSColor(calibratedWhite: 0.16, alpha: 1)
    private let fill = NSColor(calibratedWhite: 0.98, alpha: 1)

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(calibratedWhite: 0.985, alpha: 1).setFill()
        dirtyRect.fill()

        let bounds = controllerBounds()
        drawShell(in: bounds)
        for button in previewButtons {
            draw(region: button, in: bounds)
        }
        drawCenterLabels(in: bounds)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let bounds = controllerBounds()
        guard let button = previewButtons.last(where: { $0.path(in: bounds).contains(point) })?.button else { return }
        selectedButton = button
        onSelectButton?(button)
    }

    private func controllerBounds() -> CGRect {
        let inset = CGFloat(36)
        let targetRatio = CGFloat(1000.0 / 620.0)
        var width = max(320, bounds.width - inset * 2)
        var height = width / targetRatio
        if height > bounds.height - inset * 2 {
            height = max(220, bounds.height - inset * 2)
            width = height * targetRatio
        }
        return CGRect(
            x: (bounds.width - width) / 2,
            y: (bounds.height - height) / 2,
            width: width,
            height: height
        )
    }

    private func drawShell(in rect: CGRect) {
        let path = NSBezierPath()
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x / 1000, y: rect.minY + rect.height * y / 620)
        }
        path.move(to: p(178, 153))
        path.curve(to: p(355, 142), controlPoint1: p(210, 121), controlPoint2: p(312, 121))
        path.curve(to: p(645, 142), controlPoint1: p(396, 128), controlPoint2: p(604, 128))
        path.curve(to: p(822, 153), controlPoint1: p(688, 121), controlPoint2: p(790, 121))
        path.curve(to: p(852, 547), controlPoint1: p(886, 187), controlPoint2: p(912, 505))
        path.curve(to: p(742, 392), controlPoint1: p(813, 569), controlPoint2: p(762, 442))
        path.curve(to: p(258, 392), controlPoint1: p(695, 380), controlPoint2: p(305, 380))
        path.curve(to: p(148, 547), controlPoint1: p(238, 442), controlPoint2: p(187, 569))
        path.curve(to: p(178, 153), controlPoint1: p(88, 505), controlPoint2: p(114, 187))
        path.close()
        fill.setFill()
        ink.setStroke()
        path.lineWidth = 2.4
        path.fill()
        path.stroke()

        roundedRect(x: 355, y: 142, width: 290, height: 148, radius: 34, in: rect).stroke()
        drawStick(centerX: 335, centerY: 362, in: rect)
        drawStick(centerX: 665, centerY: 362, in: rect)
    }

    private func drawStick(centerX: CGFloat, centerY: CGFloat, in rect: CGRect) {
        let center = point(centerX, centerY, in: rect)
        let radius = rect.width * 55 / 1000
        let outer = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        fill.setFill()
        ink.setStroke()
        outer.lineWidth = 2
        outer.fill()
        outer.stroke()
        let inner = NSBezierPath(ovalIn: outer.bounds.insetBy(dx: radius * 0.24, dy: radius * 0.24))
        inner.stroke()
    }

    private func draw(region: PreviewRegion, in rect: CGRect) {
        let path = region.path(in: rect)
        if region.button == selectedButton {
            accent.withAlphaComponent(0.18).setFill()
            accent.setStroke()
        } else {
            fill.setFill()
            ink.setStroke()
        }
        path.lineWidth = region.button == selectedButton ? 3 : 2
        path.fill()
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(10, rect.width * 0.018), weight: .semibold),
            .foregroundColor: region.button == selectedButton ? accent : ink
        ]
        let title = region.title as NSString
        let size = title.size(withAttributes: attributes)
        let center = region.labelPoint(in: rect)
        title.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
    }

    private func drawCenterLabels(in rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(11, rect.width * 0.02), weight: .medium),
            .foregroundColor: ink
        ]
        let ps = "PS" as NSString
        let center = point(500, 358, in: rect)
        let size = ps.size(withAttributes: attributes)
        ps.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
    }

    private func point(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * x / 1000, y: rect.minY + rect.height * y / 620)
    }

    private func roundedRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, radius: CGFloat, in rect: CGRect) -> NSBezierPath {
        NSBezierPath(roundedRect: CGRect(
            x: rect.minX + rect.width * x / 1000,
            y: rect.minY + rect.height * y / 620,
            width: rect.width * width / 1000,
            height: rect.height * height / 620
        ), xRadius: rect.width * radius / 1000, yRadius: rect.height * radius / 620)
    }
}

private struct PreviewRegion {
    let button: ControllerButton
    let title: String
    let frame: CGRect
    let shape: Shape

    enum Shape {
        case oval
        case rounded(CGFloat)
    }

    func path(in rect: CGRect) -> NSBezierPath {
        let mapped = CGRect(
            x: rect.minX + rect.width * frame.minX / 1000,
            y: rect.minY + rect.height * frame.minY / 620,
            width: rect.width * frame.width / 1000,
            height: rect.height * frame.height / 620
        )
        switch shape {
        case .oval:
            return NSBezierPath(ovalIn: mapped)
        case .rounded(let radius):
            return NSBezierPath(roundedRect: mapped, xRadius: rect.width * radius / 1000, yRadius: rect.height * radius / 620)
        }
    }

    func labelPoint(in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + rect.width * frame.midX / 1000,
            y: rect.minY + rect.height * frame.midY / 620
        )
    }
}

private let previewButtons: [PreviewRegion] = [
    PreviewRegion(button: .leftTrigger, title: "L2", frame: CGRect(x: 200, y: 68, width: 100, height: 42), shape: .rounded(12)),
    PreviewRegion(button: .rightTrigger, title: "R2", frame: CGRect(x: 700, y: 68, width: 100, height: 42), shape: .rounded(12)),
    PreviewRegion(button: .leftShoulder, title: "L1", frame: CGRect(x: 176, y: 112, width: 142, height: 42), shape: .rounded(12)),
    PreviewRegion(button: .rightShoulder, title: "R1", frame: CGRect(x: 682, y: 112, width: 142, height: 42), shape: .rounded(12)),
    PreviewRegion(button: .touchpadButton, title: "", frame: CGRect(x: 382, y: 142, width: 236, height: 130), shape: .rounded(28)),
    PreviewRegion(button: .dpadUp, title: "", frame: CGRect(x: 215, y: 185, width: 46, height: 58), shape: .rounded(10)),
    PreviewRegion(button: .dpadLeft, title: "", frame: CGRect(x: 178, y: 224, width: 58, height: 46), shape: .rounded(10)),
    PreviewRegion(button: .dpadRight, title: "", frame: CGRect(x: 264, y: 224, width: 58, height: 46), shape: .rounded(10)),
    PreviewRegion(button: .dpadDown, title: "", frame: CGRect(x: 215, y: 270, width: 46, height: 58), shape: .rounded(10)),
    PreviewRegion(button: .buttonY, title: "△", frame: CGRect(x: 752, y: 174, width: 60, height: 60), shape: .oval),
    PreviewRegion(button: .buttonX, title: "□", frame: CGRect(x: 688, y: 222, width: 60, height: 60), shape: .oval),
    PreviewRegion(button: .buttonB, title: "○", frame: CGRect(x: 816, y: 222, width: 60, height: 60), shape: .oval),
    PreviewRegion(button: .buttonA, title: "×", frame: CGRect(x: 752, y: 270, width: 60, height: 60), shape: .oval),
    PreviewRegion(button: .leftThumbstickButton, title: "", frame: CGRect(x: 280, y: 307, width: 110, height: 110), shape: .oval),
    PreviewRegion(button: .rightThumbstickButton, title: "", frame: CGRect(x: 610, y: 307, width: 110, height: 110), shape: .oval),
    PreviewRegion(button: .buttonMenu, title: "", frame: CGRect(x: 318, y: 168, width: 24, height: 54), shape: .rounded(12)),
    PreviewRegion(button: .buttonOptions, title: "", frame: CGRect(x: 658, y: 168, width: 24, height: 54), shape: .rounded(12)),
    PreviewRegion(button: .buttonHome, title: "PS", frame: CGRect(x: 470, y: 330, width: 60, height: 60), shape: .oval),
    PreviewRegion(button: .buttonMicrophoneMute, title: "", frame: CGRect(x: 476, y: 392, width: 48, height: 14), shape: .rounded(7))
]
