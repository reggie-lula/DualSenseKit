import Foundation

struct BridgeEvent: Codable, Equatable, Sendable {
    var type: String
    var payload: [String: String]
    var timestamp: Date = Date()
}

final class EventBus: @unchecked Sendable {
    typealias Handler = (BridgeEvent) -> Void
    private let queue = DispatchQueue(label: "DualSenseBridge.EventBus")
    private var handlers: [UUID: Handler] = [:]
    private var recentEvents: [BridgeEvent] = []
    private let maxRecentEvents = 200

    func publish(_ event: BridgeEvent) {
        let snapshot = queue.sync {
            recentEvents.append(event)
            if recentEvents.count > maxRecentEvents {
                recentEvents.removeFirst(recentEvents.count - maxRecentEvents)
            }
            return handlers.values
        }
        snapshot.forEach { $0(event) }
    }

    @discardableResult
    func subscribe(_ handler: @escaping Handler) -> UUID {
        let id = UUID()
        queue.sync { handlers[id] = handler }
        return id
    }

    func unsubscribe(_ id: UUID) {
        queue.sync { _ = handlers.removeValue(forKey: id) }
    }

    func recent(limit: Int = 50) -> [BridgeEvent] {
        queue.sync {
            Array(recentEvents.suffix(max(0, min(limit, maxRecentEvents))))
        }
    }
}
