import Foundation

enum ProtocolSessionState: String, Codable, Sendable {
    case unpaired
    case discovering
    case pairing
    case connecting
    case connected
    case interrupted
    case unavailable
    case ended
}

enum ProtocolSessionEvent: String, Codable, Sendable {
    case startDiscovery
    case peerSelected
    case pairingSucceeded
    case pairingFailed
    case transportConnected
    case transportFailed
    case controlLost
    case retry
    case capabilityLost
    case capabilityRestored
    case end
}

enum SessionStateMachineError: LocalizedError, Equatable {
    case unknownEvent(String)
    case invalidTransition(state: ProtocolSessionState, event: ProtocolSessionEvent)

    var errorDescription: String? {
        switch self {
        case .unknownEvent(let event): "UNKNOWN_STATE_EVENT: \(event)"
        case .invalidTransition(let state, let event):
            "INVALID_STATE_TRANSITION: \(event.rawValue) in \(state.rawValue)"
        }
    }
}

struct SessionStateMachine: Sendable {
    private(set) var state: ProtocolSessionState

    init(state: ProtocolSessionState = .unpaired) {
        self.state = state
    }

    mutating func apply(_ eventName: String) throws -> ProtocolSessionState {
        guard let event = ProtocolSessionEvent(rawValue: eventName) else {
            throw SessionStateMachineError.unknownEvent(eventName)
        }
        return try apply(event)
    }

    mutating func apply(_ event: ProtocolSessionEvent) throws -> ProtocolSessionState {
        let target: ProtocolSessionState?
        switch (state, event) {
        case (.unpaired, .startDiscovery): target = .discovering
        case (.discovering, .peerSelected): target = .pairing
        case (.pairing, .pairingSucceeded): target = .connecting
        case (.pairing, .pairingFailed): target = .interrupted
        case (.connecting, .transportConnected): target = .connected
        case (.connecting, .transportFailed): target = .interrupted
        case (.connected, .controlLost): target = .interrupted
        case (.interrupted, .retry): target = .discovering
        case (.unavailable, .capabilityRestored): target = .unpaired
        case (.ended, _): target = nil
        case (_, .capabilityLost): target = state == .unavailable ? nil : .unavailable
        case (_, .end): target = .ended
        default: target = nil
        }
        guard let target else {
            throw SessionStateMachineError.invalidTransition(state: state, event: event)
        }
        state = target
        return target
    }
}

