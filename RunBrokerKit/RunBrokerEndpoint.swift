import Foundation
import RunBrokerClient
import ASTRACore

public final class RunBrokerRequestEndpoint: @unchecked Sendable {
    private struct CachedResponse {
        let command: RunBrokerCommand
        let protocolVersion: RunBrokerProtocolVersion
        let result: RunBrokerResponsePayload?
        let error: RunBrokerErrorResponse?

        func rebound(to requestID: UUID) -> RunBrokerResponseEnvelope {
            if let result {
                return .init(
                    protocolVersion: protocolVersion,
                    requestID: requestID,
                    result: result
                )
            }
            return .init(
                protocolVersion: protocolVersion,
                requestID: requestID,
                error: error ?? .init(code: .internalFailure, message: "Invalid cached response.")
            )
        }
    }

    private let lock = NSLock()
    private let channel: RunBrokerChannel
    private let installationID: RunBrokerInstallationID
    private let brokerVersion: String
    private let supportedVersions: RunBrokerProtocolRange
    private let securityFloor: RunBrokerProtocolVersion
    private let authenticator: RunBrokerRequestAuthenticator
    private let replayProtector: RunBrokerReplayProtector
    private let peerPolicy: RunBrokerPeerIdentityPolicy
    private let scheduler: RunBrokerMonitorScheduler
    private let applicationHandler: (any RunBrokerApplicationCommandHandling)?
    private let safeResponseCacheCapacity: Int
    private var cachedResponses: [UUID: CachedResponse] = [:]
    private var cacheOrder: [UUID] = []

    public init(
        channel: RunBrokerChannel,
        installationID: RunBrokerInstallationID,
        brokerVersion: String,
        authenticator: RunBrokerRequestAuthenticator,
        replayProtector: RunBrokerReplayProtector = .init(),
        peerPolicy: RunBrokerPeerIdentityPolicy,
        scheduler: RunBrokerMonitorScheduler,
        applicationHandler: (any RunBrokerApplicationCommandHandling)? = nil,
        supportedVersions: RunBrokerProtocolRange = .current,
        securityFloor: RunBrokerProtocolVersion = .minimumSecure,
        safeResponseCacheCapacity: Int = 256
    ) {
        precondition(safeResponseCacheCapacity > 0)
        self.channel = channel
        self.installationID = installationID
        self.brokerVersion = brokerVersion
        self.authenticator = authenticator
        self.replayProtector = replayProtector
        self.peerPolicy = peerPolicy
        self.scheduler = scheduler
        self.applicationHandler = applicationHandler
        self.supportedVersions = supportedVersions
        self.securityFloor = securityFloor
        self.safeResponseCacheCapacity = safeResponseCacheCapacity
    }

    public func handle(
        _ request: RunBrokerRequestEnvelope,
        peer: RunBrokerPeerIdentity,
        now: Date
    ) -> RunBrokerResponseEnvelope {
        do {
            try peerPolicy.verify(peer)
        } catch {
            return failure(request, code: .peerIdentityRejected, message: "Peer identity rejected.")
        }

        do {
            try authenticator.verify(
                request,
                expectedChannel: channel,
                expectedInstallationID: installationID,
                now: now
            )
        } catch RunBrokerAuthenticationError.wrongChannel {
            return failure(request, code: .wrongChannel, message: "Channel identity does not match.")
        } catch RunBrokerAuthenticationError.wrongInstallation {
            return failure(
                request,
                code: .wrongInstallation,
                message: "Installation identity does not match."
            )
        } catch {
            return failure(request, code: .authenticationFailed, message: "Authentication failed.")
        }

        do {
            try replayProtector.consume(nonce: request.authentication.nonce, now: now)
        } catch RunBrokerAuthenticationError.replayCapacityExceeded {
            return failure(
                request,
                code: .replayProtectionSaturated,
                message: "Replay protection is temporarily saturated.",
                retryable: true
            )
        } catch {
            return failure(request, code: .replayDetected, message: "Request nonce was already used.")
        }

        if request.command.isSafeForEphemeralReplay,
           let cached = cachedResponse(for: request.idempotencyKey) {
            guard cached.command == request.command else {
                return failure(
                    request,
                    code: .invalidRequest,
                    message: "Idempotency key was reused for another command."
                )
            }
            return cached.rebound(to: request.requestID)
        }

        let response = route(request, now: now)
        if request.command.isSafeForEphemeralReplay {
            cache(response, command: request.command, key: request.idempotencyKey)
        }
        return response
    }

    private func route(
        _ request: RunBrokerRequestEnvelope,
        now: Date
    ) -> RunBrokerResponseEnvelope {
        switch request.command {
        case .negotiate(let negotiation):
            do {
                let selected = try RunBrokerProtocolNegotiator.negotiate(
                    client: negotiation.supportedVersions,
                    server: supportedVersions,
                    clientSecurityFloor: negotiation.securityFloor,
                    serverSecurityFloor: securityFloor
                )
                return .init(
                    protocolVersion: selected,
                    requestID: request.requestID,
                    result: .negotiation(
                        .init(
                            selectedVersion: selected,
                            serverSupportedVersions: supportedVersions,
                            serverSecurityFloor: securityFloor
                        )
                    )
                )
            } catch RunBrokerContractError.insecureProtocolDowngrade {
                return failure(
                    request,
                    code: .insecureDowngrade,
                    message: "No mutually secure protocol version."
                )
            } catch {
                return failure(
                    request,
                    code: .incompatibleProtocol,
                    message: "No compatible protocol version."
                )
            }

        case .health:
            guard request.protocolVersion == .current else {
                return incompatibleVersion(request)
            }
            return .init(
                protocolVersion: .current,
                requestID: request.requestID,
                result: .health(
                    .init(
                        status: scheduler.isOperational && scheduler.monitorAvailable
                            ? .healthy
                            : .degraded,
                        brokerVersion: brokerVersion,
                        protocolRange: supportedVersions,
                        ledgerAvailable: scheduler.ledgerAvailable
                    )
                )
            )

        case .capabilities:
            guard request.protocolVersion == .current else {
                return incompatibleVersion(request)
            }
            return .init(
                protocolVersion: .current,
                requestID: request.requestID,
                result: .capabilities(
                    .init(
                        schedulerRead: scheduler.isOperational,
                        schedulerMutation: scheduler.isOperational && scheduler.monitorAvailable,
                        durableIdempotency: scheduler.isOperational,
                        applicationControl: applicationHandler != nil,
                        gracefulCancellation:
                            applicationHandler?.supportsGracefulCancellation == true,
                        immediateTermination:
                            applicationHandler?.supportsImmediateTermination == true
                    )
                )
            )

        case .scheduler(let command):
            guard request.protocolVersion == .current else {
                return incompatibleVersion(request)
            }
            guard scheduler.ledgerAvailable else {
                return failure(
                    request,
                    code: .ledgerUnavailable,
                    message: "Durable RunLedger is unavailable.",
                    retryable: true
                )
            }
            if command != .recover, !scheduler.isOperational {
                return failure(
                    request,
                    code: .ledgerUnavailable,
                    message: "Durable scheduler is degraded and requires recovery.",
                    retryable: true
                )
            }
            if !scheduler.monitorAvailable {
                switch command {
                case .upsert, .remove, .wake:
                    return failure(
                        request,
                        code: .monitorUnavailable,
                        message: "External-operation monitoring is unavailable."
                    )
                case .recover, .status:
                    break
                }
            }
            do {
                switch command {
                case .recover:
                    try scheduler.recover()
                    return accepted(request)
                case .upsert(let mutation):
                    try scheduler.upsert(
                        mutation.deadline,
                        replacing: mutation.replacing,
                        idempotencyKey: request.idempotencyKey
                    )
                    return accepted(request)
                case .remove(let mutation):
                    try scheduler.remove(
                        expected: mutation.expected,
                        occurredAt: mutation.occurredAt,
                        idempotencyKey: request.idempotencyKey
                    )
                    return accepted(request)
                case .wake:
                    try scheduler.wake()
                    return accepted(request)
                case .status:
                    return .init(
                        protocolVersion: .current,
                        requestID: request.requestID,
                        result: .schedulerStatus(try scheduler.status())
                    )
                }
            } catch RunBrokerSchedulerError.monitorScheduleConflict(_) {
                return failure(
                    request,
                    code: .monitorScheduleConflict,
                    message: "Monitor schedule changed; refresh its current projection.",
                    retryable: true
                )
            } catch {
                return failure(
                    request,
                    code: .internalFailure,
                    message: "Scheduler command failed.",
                    retryable: true
                )
            }

        case .application(let command):
            guard request.protocolVersion == .current else {
                return incompatibleVersion(request)
            }
            guard let applicationHandler else {
                return failure(
                    request,
                    code: .applicationUnavailable,
                    message: "Durable application control is unavailable."
                )
            }
            do {
                try command.validate(now: now)
                return .init(
                    protocolVersion: .current,
                    requestID: request.requestID,
                    result: .application(try applicationHandler.handle(
                        command,
                        idempotencyKey: request.idempotencyKey,
                        now: now
                    ))
                )
            } catch RunBrokerApplicationEndpointError.executionNotFound {
                return failure(request, code: .executionNotFound, message: "Execution was not found.")
            } catch RunBrokerApplicationEndpointError.projectionAcknowledgementConflict {
                return failure(
                    request,
                    code: .projectionAcknowledgementConflict,
                    message: "Projection acknowledgement does not match the next durable message."
                )
            } catch RunBrokerApplicationEndpointError.externalOperationBlocked {
                return failure(
                    request,
                    code: .externalOperationBlocked,
                    message: "External-operation control is not authorized."
                )
            } catch is RunBrokerApplicationContractError {
                return failure(
                    request,
                    code: .applicationRequestRejected,
                    message: "Application request is invalid."
                )
            } catch {
                return failure(
                    request,
                    code: .applicationRequestRejected,
                    message: "Application request was rejected."
                )
            }
        }
    }

    private func accepted(_ request: RunBrokerRequestEnvelope) -> RunBrokerResponseEnvelope {
        .init(protocolVersion: .current, requestID: request.requestID, result: .accepted)
    }

    private func incompatibleVersion(
        _ request: RunBrokerRequestEnvelope
    ) -> RunBrokerResponseEnvelope {
        failure(
            request,
            code: .updateRequired,
            message: "Update ASTRA and the RunBroker cohort before sending this command."
        )
    }

    private func failure(
        _ request: RunBrokerRequestEnvelope,
        code: RunBrokerErrorCode,
        message: String,
        retryable: Bool = false
    ) -> RunBrokerResponseEnvelope {
        .init(
            protocolVersion: .current,
            requestID: request.requestID,
            error: .init(code: code, message: message, retryable: retryable)
        )
    }

    private func cachedResponse(for key: UUID) -> CachedResponse? {
        lock.lock()
        defer { lock.unlock() }
        return cachedResponses[key]
    }

    private func cache(_ response: RunBrokerResponseEnvelope, command: RunBrokerCommand, key: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if cachedResponses[key] == nil {
            cacheOrder.append(key)
        }
        cachedResponses[key] = CachedResponse(
            command: command,
            protocolVersion: response.protocolVersion,
            result: response.result,
            error: response.error
        )
        while cacheOrder.count > safeResponseCacheCapacity {
            cachedResponses.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}
