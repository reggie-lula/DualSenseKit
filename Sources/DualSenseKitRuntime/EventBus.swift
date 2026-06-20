import Foundation

public struct BridgeEvent: Codable, Equatable, Sendable {
    public var type: String
    public var payload: [String: String]
    public var timestamp: Date = Date()

    public init(type: String, payload: [String: String], timestamp: Date = Date()) {
        self.type = type
        self.payload = payload
        self.timestamp = timestamp
    }
}

public final class EventBus: @unchecked Sendable {
    public typealias Handler = (BridgeEvent) -> Void
    private let queue = DispatchQueue(label: "DualSenseKitDemo.EventBus")
    private var handlers: [UUID: Handler] = [:]
    private var recentEvents: [BridgeEvent] = []
    private let maxRecentEvents = 200

    public init() {}

    public func publish(_ event: BridgeEvent) {
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
    public func subscribe(_ handler: @escaping Handler) -> UUID {
        let id = UUID()
        queue.sync { handlers[id] = handler }
        return id
    }

    public func unsubscribe(_ id: UUID) {
        queue.sync { _ = handlers.removeValue(forKey: id) }
    }

    public func recent(limit: Int = 50) -> [BridgeEvent] {
        queue.sync {
            Array(recentEvents.suffix(max(0, min(limit, maxRecentEvents))))
        }
    }
}
