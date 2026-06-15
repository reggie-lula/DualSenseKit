import DualSenseBridgeCore

@main
struct DualSenseBridgeMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--headless-server") {
            runDualSenseBridgeHeadlessServer()
        } else {
            runDualSenseBridgeApp()
        }
    }
}
