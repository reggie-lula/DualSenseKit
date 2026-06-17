import DualSenseKitMacOS

@main
struct DualSenseKitDemoMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--headless-server") {
            runDualSenseKitDemoHeadlessServer()
        } else {
            runDualSenseKitDemoApp()
        }
    }
}
