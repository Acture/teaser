import Foundation

protocol TerminalAttachmentTransport: AnyObject, Sendable {
	var nextUnreadOffset: UInt64 { get }

	func sendInput(_ bytes: [UInt8]) throws
	func sendResize(_ size: AttachmentTerminalSize) throws
	func readFrame() throws -> AttachmentServerFrame
	func close()
}

extension AttachmentClient: TerminalAttachmentTransport {}

protocol TerminalAttachmentConnecting: Sendable {
	/// Implementations must stop connection work when the absolute deadline expires.
	func connect(
		nextOffset: UInt64,
		deadline: AttachmentConnectionDeadline
	) throws -> any TerminalAttachmentTransport
}

struct TerminalAttachmentConnector: TerminalAttachmentConnecting {
	private let connectBody:
		@Sendable (
			UInt64,
			AttachmentConnectionDeadline
		) throws -> any TerminalAttachmentTransport

	init(
		_ connectBody:
			@escaping @Sendable (
				UInt64,
				AttachmentConnectionDeadline
			) throws -> any TerminalAttachmentTransport
	) {
		self.connectBody = connectBody
	}

	func connect(
		nextOffset: UInt64,
		deadline: AttachmentConnectionDeadline
	) throws -> any TerminalAttachmentTransport {
		try connectBody(nextOffset, deadline)
	}
}

struct AttachmentClientConnector: TerminalAttachmentConnecting {
	let socketPath: String
	let sessionID: String
	let surfaceID: UInt64
	let timeoutSeconds: Int

	init(
		socketPath: String,
		sessionID: String,
		surfaceID: UInt64,
		timeoutSeconds: Int = 5
	) {
		self.socketPath = socketPath
		self.sessionID = sessionID
		self.surfaceID = surfaceID
		self.timeoutSeconds = timeoutSeconds
	}

	func connect(
		nextOffset: UInt64,
		deadline: AttachmentConnectionDeadline
	) throws -> any TerminalAttachmentTransport {
		let effectiveDeadline: AttachmentConnectionDeadline =
			deadline.capped(to: TimeInterval(timeoutSeconds))
		let remaining: TimeInterval = effectiveDeadline.remainingTimeInterval
		guard remaining > 0 else {
			throw AttachmentClientError.transport("connection deadline expired")
		}
		return try AttachmentClient.connect(
			socketPath: socketPath,
			sessionID: sessionID,
			surfaceID: surfaceID,
			nextOffset: nextOffset,
			timeoutSeconds: TimeInterval(timeoutSeconds),
			deadline: effectiveDeadline,
			frameReadTimeoutSeconds: nil
		)
	}
}

protocol TerminalOutputSink: AnyObject, Sendable {
	func feed(_ bytes: [UInt8]) throws
}

enum TerminalAttachmentEnqueueResult: Equatable, Sendable {
	case accepted
	case inputPaused
	case overflow
	case stopped
}

protocol TerminalAttachmentEnqueuing: AnyObject, Sendable {
	func enqueueInput(_ bytes: [UInt8]) -> TerminalAttachmentEnqueueResult
	func enqueueResize(
		_ size: AttachmentTerminalSize
	) -> TerminalAttachmentEnqueueResult
}

struct TerminalAttachmentPumpLimits: Equatable, Sendable {
	let maximumInputBytes: Int
	let maximumEvents: Int
	let reconnectTimeout: TimeInterval
	let detachDrainTimeout: TimeInterval
	let reconnectRetryDelays: [TimeInterval]

	static let production: TerminalAttachmentPumpLimits = .init(
		maximumInputBytes: 1 * 1_024 * 1_024,
		maximumEvents: 4_096,
		reconnectTimeout: 5,
		detachDrainTimeout: 5,
		reconnectRetryDelays: [0.025, 0.05, 0.1, 0.2, 0.5]
	)

	init(
		maximumInputBytes: Int,
		maximumEvents: Int,
		reconnectTimeout: TimeInterval,
		detachDrainTimeout: TimeInterval,
		reconnectRetryDelays: [TimeInterval]
	) {
		precondition(maximumInputBytes > 0)
		precondition(maximumEvents > 0)
		precondition(reconnectTimeout > 0)
		precondition(detachDrainTimeout > 0)
		precondition(
			!reconnectRetryDelays.isEmpty
				&& reconnectRetryDelays.allSatisfy { $0 > 0 }
		)
		self.maximumInputBytes = maximumInputBytes
		self.maximumEvents = maximumEvents
		self.reconnectTimeout = reconnectTimeout
		self.detachDrainTimeout = detachDrainTimeout
		self.reconnectRetryDelays = reconnectRetryDelays
	}
}

enum TerminalAttachmentUncertaintyReason:
	Equatable, CustomStringConvertible, Sendable
{
	case queueOverflow
	case connectionLost(String)
	case drainTimedOut

	var description: String {
		switch self {
		case .queueOverflow:
			return "outbound queue overflow"
		case .connectionLost(let message):
			return "connection lost: \(message)"
		case .drainTimedOut:
			return "detach drain timed out"
		}
	}
}

enum TerminalAttachmentStopReason:
	Equatable, CustomStringConvertible, Sendable
{
	case detached
	case processExited(UInt32)
	case replayGap(requested: UInt64, availableFrom: UInt64)
	case initialConnectionFailed(String)
	case reconnectTimedOut(String)
	case protocolFailure(String)
	case outputSinkFailed(String)
	case transportFailed(String)
	case drainTimedOut

	var description: String {
		switch self {
		case .detached:
			return "detached"
		case .processExited(let code):
			return "process exited with status \(code)"
		case .replayGap(let requested, let availableFrom):
			return "replay gap \(requested)..<\(availableFrom)"
		case .initialConnectionFailed(let message):
			return "initial connection failed: \(message)"
		case .reconnectTimedOut(let message):
			return "reconnect timed out: \(message)"
		case .protocolFailure(let message):
			return "protocol failure: \(message)"
		case .outputSinkFailed(let message):
			return "output sink failed: \(message)"
		case .transportFailed(let message):
			return "transport failed: \(message)"
		case .drainTimedOut:
			return "detach drain timed out"
		}
	}
}

enum TerminalAttachmentPumpEvent: Equatable, Sendable {
	case connected(offset: UInt64)
	case reconnected(recoveryID: UInt64, offset: UInt64, inputPaused: Bool)
	case inputDeliveryUncertain(
		recoveryID: UInt64,
		reason: TerminalAttachmentUncertaintyReason
	)
	case stopped(reason: TerminalAttachmentStopReason, resumeOffset: UInt64)
}

final class TerminalAttachmentPump:
	TerminalAttachmentEnqueuing, @unchecked Sendable
{
	private enum Phase {
		case prepared
		case connecting
		case running
		case reconnecting
		case draining
		case stopping
		case stopped
	}

	private enum OutboundEvent {
		case input([UInt8])
		case resize(AttachmentTerminalSize)

		var inputByteCount: Int {
			switch self {
			case .input(let bytes):
				return bytes.count
			case .resize:
				return 0
			}
		}
	}

	private struct ReconnectAction {
		let transport: any TerminalAttachmentTransport
		let token: UInt64
		let deadline: AttachmentConnectionDeadline
		let uncertainty: TerminalAttachmentUncertaintyReason
	}

	private enum FeedDrainResult {
		case drained
		case cancelled
		case timedOut
	}

	private struct StopAction {
		let transport: (any TerminalAttachmentTransport)?
		let stoppedEvent: TerminalAttachmentPumpEvent?
	}

	private struct TransportFailureAction {
		let uncertaintyEvent: TerminalAttachmentPumpEvent?
		let reconnectAction: ReconnectAction?
		let stopAction: StopAction?
	}

	private let connector: any TerminalAttachmentConnecting
	private let outputSink: any TerminalOutputSink
	private let limits: TerminalAttachmentPumpLimits
	private let eventDeliveryQueue: DispatchQueue
	private let eventHandler: @Sendable (TerminalAttachmentPumpEvent) -> Void
	private let condition: NSCondition = .init()
	private let stateChanges: DispatchSemaphore = .init(value: 0)
	private var stateChangeSignalPending: Bool = false
	private let lifecycleQueue: DispatchQueue = .init(
		label: "dev.taco.terminal-attachment.lifecycle"
	)

	private var phase: Phase = .prepared
	private var transport: (any TerminalAttachmentTransport)?
	private var generation: UInt64 = 0
	private var connectionToken: UInt64 = 0
	private var outboundEvents: [OutboundEvent] = []
	private var queuedInputBytes: Int = 0
	private var writerInFlight: OutboundEvent?
	private var latestResize: AttachmentTerminalSize?
	private var committedOffset: UInt64 = 0
	private var inputEnabled: Bool = false
	private var inputPausedAfterReconnect: Bool = false
	private var pendingInputRecoveryID: UInt64?
	private var feedsInFlight: Int = 0
	private var workersStarted: Bool = false
	private var readerFinished: Bool = false
	private var writerFinished: Bool = false
	private var lifecycleOperations: Int = 0
	private var stopReason: TerminalAttachmentStopReason?
	private var stoppedEventPublished: Bool = false

	init(
		connector: any TerminalAttachmentConnecting,
		outputSink: any TerminalOutputSink,
		limits: TerminalAttachmentPumpLimits = .production,
		eventQueue: DispatchQueue = .main,
		eventHandler:
			@escaping @Sendable (TerminalAttachmentPumpEvent) -> Void = { _ in }
	) {
		self.connector = connector
		self.outputSink = outputSink
		self.limits = limits
		eventDeliveryQueue = .init(
			label: "dev.taco.terminal-attachment.events",
			target: eventQueue
		)
		self.eventHandler = eventHandler
	}

	var committedOutputOffset: UInt64 {
		condition.lock()
		defer { condition.unlock() }
		return committedOffset
	}

	func start() {
		condition.lock()
		guard phase == .prepared else {
			condition.unlock()
			return
		}
		phase = .connecting
		workersStarted = true
		connectionToken &+= 1
		let token: UInt64 = connectionToken
		lifecycleOperations += 1
		condition.unlock()

		startWorkers()
		lifecycleQueue.async { [weak self] in
			self?.performInitialConnection(token: token)
			self?.finishLifecycleOperation()
		}
	}

	func enqueueInput(_ bytes: [UInt8]) -> TerminalAttachmentEnqueueResult {
		guard !bytes.isEmpty else { return .accepted }

		condition.lock()
		guard phase != .stopping, phase != .stopped, phase != .draining else {
			condition.unlock()
			return .stopped
		}
		guard inputEnabled else {
			condition.unlock()
			return .inputPaused
		}

		let residentInputBytes: Int =
			queuedInputBytes + (writerInFlight?.inputByteCount ?? 0)
		let residentEvents: Int =
			outboundEvents.count + (writerInFlight == nil ? 0 : 1)
		let inputWouldOverflow: Bool =
			bytes.count > limits.maximumInputBytes - residentInputBytes
		let eventsWouldOverflow: Bool =
			residentEvents >= limits.maximumEvents
		guard !inputWouldOverflow, !eventsWouldOverflow else {
			let action: ReconnectAction? = prepareReconnectLocked(
				uncertainty: .queueOverflow
			)
			let stopAction: StopAction? = action == nil
				? prepareStopLocked(
					reason: .transportFailed(
						"outbound queue overflow without a live attachment"
					)
				)
				: nil
			let recoveryID: UInt64 = action?.token ?? connectionToken
			signalStateChangeLocked()
			condition.unlock()
			emit(
				.inputDeliveryUncertain(
					recoveryID: recoveryID,
					reason: .queueOverflow
				)
			)
			if let action {
				performReconnect(action)
			} else {
				performStopIfPresent(stopAction)
			}
			return .overflow
		}

		outboundEvents.append(.input(bytes))
		queuedInputBytes += bytes.count
		signalStateChangeLocked()
		condition.unlock()
		return .accepted
	}

	func enqueueResize(
		_ size: AttachmentTerminalSize
	) -> TerminalAttachmentEnqueueResult {
		condition.lock()
		guard phase != .stopping, phase != .stopped, phase != .draining else {
			condition.unlock()
			return .stopped
		}

		if case .resize? = outboundEvents.last {
			latestResize = size
			outboundEvents[outboundEvents.count - 1] = .resize(size)
			signalStateChangeLocked()
			condition.unlock()
			return .accepted
		}

		let residentEvents: Int =
			outboundEvents.count + (writerInFlight == nil ? 0 : 1)
		guard residentEvents < limits.maximumEvents else {
			let action: ReconnectAction? = prepareReconnectLocked(
				uncertainty: .queueOverflow
			)
			let stopAction: StopAction? = action == nil
				? prepareStopLocked(
					reason: .transportFailed(
						"outbound queue overflow without a live attachment"
					)
				)
				: nil
			let recoveryID: UInt64 = action?.token ?? connectionToken
			signalStateChangeLocked()
			condition.unlock()
			emit(
				.inputDeliveryUncertain(
					recoveryID: recoveryID,
					reason: .queueOverflow
				)
			)
			if let action {
				performReconnect(action)
			} else {
				performStopIfPresent(stopAction)
			}
			return .overflow
		}

		latestResize = size
		outboundEvents.append(.resize(size))
		signalStateChangeLocked()
		condition.unlock()
		return .accepted
	}

	func acknowledgeInputAfterReconnect(recoveryID: UInt64) -> Bool {
		condition.lock()
		defer { condition.unlock() }
		guard
			phase == .running,
			inputPausedAfterReconnect,
			pendingInputRecoveryID == recoveryID
		else {
			return false
		}
		inputPausedAfterReconnect = false
		pendingInputRecoveryID = nil
		inputEnabled = true
		signalStateChangeLocked()
		return true
	}

	func detach() {
		let uncertaintyEvent: TerminalAttachmentPumpEvent?
		let stopAction: StopAction?
		let shouldScheduleDeadline: Bool
		condition.lock()
		guard
			phase != .stopping,
			phase != .stopped,
			phase != .draining
		else {
			condition.unlock()
			return
		}

		let wasReconnecting: Bool
		if case .reconnecting = phase {
			wasReconnecting = true
		} else {
			wasReconnecting = false
		}
		inputEnabled = false
		inputPausedAfterReconnect = false
		pendingInputRecoveryID = nil
		phase = .draining
		connectionToken &+= 1
		let shouldStopImmediately: Bool =
			outboundEvents.isEmpty && writerInFlight == nil
		let unavailableTransport: Bool = transport == nil
		let uncertainInput: Bool =
			queuedInputBytes + (writerInFlight?.inputByteCount ?? 0) > 0
		let recoveryID: UInt64 = connectionToken

		if shouldStopImmediately {
			uncertaintyEvent = nil
			stopAction = prepareStopLocked(reason: .detached)
			shouldScheduleDeadline = false
		} else if unavailableTransport, wasReconnecting {
			uncertaintyEvent = nil
			stopAction = prepareStopLocked(reason: .detached)
			shouldScheduleDeadline = false
		} else if unavailableTransport {
			if uncertainInput {
				uncertaintyEvent = .inputDeliveryUncertain(
					recoveryID: recoveryID,
					reason: .drainTimedOut
				)
				stopAction = prepareStopLocked(
					reason: .transportFailed(
						"detached without a live transport"
					)
				)
			} else {
				uncertaintyEvent = nil
				stopAction = prepareStopLocked(reason: .detached)
			}
			shouldScheduleDeadline = false
		} else {
			uncertaintyEvent = nil
			stopAction = nil
			shouldScheduleDeadline = true
		}
		signalStateChangeLocked()
		condition.unlock()

		emitIfPresent(uncertaintyEvent)
		performStopIfPresent(stopAction)
		guard shouldScheduleDeadline else { return }

		let timeout: TimeInterval = limits.detachDrainTimeout
		DispatchQueue.global(qos: .utility).asyncAfter(
			deadline: .now() + timeout
		) { [weak self] in
			self?.enforceDrainDeadline()
		}
	}

	func waitUntilStopped(timeout: TimeInterval) -> Bool {
		precondition(timeout >= 0)
		let deadline: Date = Date().addingTimeInterval(timeout)
		condition.lock()
		defer { condition.unlock() }
		while phase != .stopped {
			guard condition.wait(until: deadline) else {
				return phase == .stopped
			}
		}
		return true
	}

	private func startWorkers() {
		DispatchQueue.global(qos: .userInitiated).async { [self] in
			readerLoop()
		}
		DispatchQueue.global(qos: .userInitiated).async { [self] in
			writerLoop()
		}
	}

	private func readerLoop() {
		var observedGeneration: UInt64 = 0
		while true {
			condition.lock()
			while
				phase != .stopping,
				phase != .stopped,
				(transport == nil || generation == observedGeneration)
			{
				condition.wait()
			}
			guard phase != .stopping, phase != .stopped else {
				condition.unlock()
				break
			}
			guard let activeTransport = transport else {
				condition.unlock()
				continue
			}
			let activeGeneration: UInt64 = generation
			observedGeneration = activeGeneration
			condition.unlock()

			while isCurrentConnection(
				transport: activeTransport,
				generation: activeGeneration
			) {
				do {
					let frame: AttachmentServerFrame =
						try activeTransport.readFrame()
					guard handleFrame(
						frame,
						transport: activeTransport,
						generation: activeGeneration
					) else {
						break
					}
				} catch {
					handleTransportFailure(
						error,
						transport: activeTransport,
						generation: activeGeneration
					)
					break
				}
			}
		}

		condition.lock()
		readerFinished = true
		let stoppedEvent: TerminalAttachmentPumpEvent? =
			finishStoppingIfReadyLocked()
		signalStateChangeLocked()
		condition.unlock()
		emitIfPresent(stoppedEvent)
	}

	private func writerLoop() {
		while true {
			condition.lock()
			while true {
				if phase == .stopping || phase == .stopped {
					break
				}
				if
					phase == .draining,
					outboundEvents.isEmpty,
					writerInFlight == nil
				{
					break
				}
				if transport != nil, !outboundEvents.isEmpty {
					break
				}
				condition.wait()
			}

			if phase == .stopping || phase == .stopped {
				condition.unlock()
				break
			}
			if
				phase == .draining,
				outboundEvents.isEmpty,
				writerInFlight == nil
			{
				condition.unlock()
				requestStop(reason: .detached)
				continue
			}
			guard
				let activeTransport = transport,
				!outboundEvents.isEmpty
			else {
				condition.unlock()
				continue
			}

			let event: OutboundEvent = outboundEvents.removeFirst()
			queuedInputBytes -= event.inputByteCount
			writerInFlight = event
			let activeGeneration: UInt64 = generation
			condition.unlock()

			var sendError: Error?
			do {
				switch event {
				case .input(let bytes):
					try activeTransport.sendInput(bytes)
				case .resize(let size):
					try activeTransport.sendResize(size)
				}
			} catch {
				sendError = error
			}

			let sendFailure: (error: Error, message: String)? = sendError.map {
				($0, describeTransportError($0))
			}
			condition.lock()
			let failureAction: TransportFailureAction? = sendFailure.flatMap {
				prepareTransportFailureLocked(
					$0.error,
					message: $0.message,
					transport: activeTransport,
					generation: activeGeneration
				)
			}
			writerInFlight = nil
			let shouldDetach: Bool =
				sendError == nil
					&& phase == .draining
					&& outboundEvents.isEmpty
			signalStateChangeLocked()
			condition.unlock()

			performTransportFailureIfPresent(failureAction)
			if shouldDetach {
				requestStop(reason: .detached)
			}
		}

		condition.lock()
		writerFinished = true
		let stoppedEvent: TerminalAttachmentPumpEvent? =
			finishStoppingIfReadyLocked()
		signalStateChangeLocked()
		condition.unlock()
		emitIfPresent(stoppedEvent)
	}

	private func handleFrame(
		_ frame: AttachmentServerFrame,
		transport activeTransport: any TerminalAttachmentTransport,
		generation activeGeneration: UInt64
	) -> Bool {
		switch frame {
		case .output(let offset, let bytes):
			condition.lock()
			guard isCurrentConnectionLocked(
				transport: activeTransport,
				generation: activeGeneration
			) else {
				condition.unlock()
				return false
			}
			guard offset == committedOffset else {
				let expectedOffset: UInt64 = committedOffset
				let stopAction: StopAction? = prepareStopLocked(
					reason: .protocolFailure(
						"output offset \(offset) is not committed offset "
							+ "\(expectedOffset)"
					)
				)
				signalStateChangeLocked()
				condition.unlock()
				performStopIfPresent(stopAction)
				return false
			}
			let (nextOffset, overflow): (UInt64, Bool) =
				offset.addingReportingOverflow(UInt64(bytes.count))
			guard !overflow else {
				let stopAction: StopAction? = prepareStopLocked(
					reason: .protocolFailure(
						"output offset exceeded UInt64.max"
					)
				)
				signalStateChangeLocked()
				condition.unlock()
				performStopIfPresent(stopAction)
				return false
			}
			feedsInFlight += 1
			condition.unlock()

			do {
				try outputSink.feed(bytes)
			} catch {
				let message: String = describeKnownError(error)
				condition.lock()
				feedsInFlight -= 1
				let stopAction: StopAction? = prepareStopLocked(
					reason: .outputSinkFailed(message)
				)
				signalStateChangeLocked()
				condition.unlock()
				performStopIfPresent(stopAction)
				return false
			}

			condition.lock()
			committedOffset = nextOffset
			feedsInFlight -= 1
			signalStateChangeLocked()
			condition.unlock()
			return true

		case .replayGap(let requested, let availableFrom):
			condition.lock()
			guard isCurrentConnectionLocked(
				transport: activeTransport,
				generation: activeGeneration
			) else {
				condition.unlock()
				return false
			}
			let stopAction: StopAction? = prepareStopLocked(
				reason: .replayGap(
					requested: requested,
					availableFrom: availableFrom
				)
			)
			signalStateChangeLocked()
			condition.unlock()
			performStopIfPresent(stopAction)
			return false

		case .exit(let code):
			condition.lock()
			guard isCurrentConnectionLocked(
				transport: activeTransport,
				generation: activeGeneration
			) else {
				condition.unlock()
				return false
			}
			let stopAction: StopAction? = prepareStopLocked(
				reason: .processExited(code)
			)
			signalStateChangeLocked()
			condition.unlock()
			performStopIfPresent(stopAction)
			return false
		}
	}

	private func handleTransportFailure(
		_ error: Error,
		transport activeTransport: any TerminalAttachmentTransport,
		generation activeGeneration: UInt64
	) {
		let message: String = describeTransportError(error)
		condition.lock()
		let action: TransportFailureAction? = prepareTransportFailureLocked(
			error,
			message: message,
			transport: activeTransport,
			generation: activeGeneration
		)
		signalStateChangeLocked()
		condition.unlock()
		performTransportFailureIfPresent(action)
	}

	private func prepareTransportFailureLocked(
		_ error: Error,
		message: String,
		transport activeTransport: any TerminalAttachmentTransport,
		generation activeGeneration: UInt64
	) -> TransportFailureAction? {
		let uncertaintyEvent: TerminalAttachmentPumpEvent?
		let reconnectAction: ReconnectAction?
		let stopAction: StopAction?
		guard isCurrentConnectionLocked(
			transport: activeTransport,
			generation: activeGeneration
		) else {
			return nil
		}

		if isProtocolError(error) {
			uncertaintyEvent = nil
			reconnectAction = nil
			stopAction = prepareStopLocked(reason: .protocolFailure(message))
		} else if phase == .draining {
			uncertaintyEvent = .inputDeliveryUncertain(
				recoveryID: connectionToken,
				reason: .connectionLost(message)
			)
			reconnectAction = nil
			stopAction = prepareStopLocked(reason: .transportFailed(message))
		} else {
			let action: ReconnectAction? = prepareReconnectLocked(
				uncertainty: .connectionLost(message)
			)
			uncertaintyEvent = action.map {
				.inputDeliveryUncertain(
					recoveryID: $0.token,
					reason: $0.uncertainty
				)
			}
			reconnectAction = action
			stopAction = nil
		}
		return TransportFailureAction(
			uncertaintyEvent: uncertaintyEvent,
			reconnectAction: reconnectAction,
			stopAction: stopAction
		)
	}

	private func performTransportFailureIfPresent(
		_ action: TransportFailureAction?
	) {
		guard let action else { return }
		emitIfPresent(action.uncertaintyEvent)
		if let reconnectAction = action.reconnectAction {
			performReconnect(reconnectAction)
		}
		performStopIfPresent(action.stopAction)
	}

	private func prepareReconnectLocked(
		uncertainty: TerminalAttachmentUncertaintyReason
	) -> ReconnectAction? {
		guard phase == .running, let activeTransport = transport else {
			return nil
		}
		transport = nil
		phase = .reconnecting
		inputEnabled = false
		inputPausedAfterReconnect = true
		connectionToken &+= 1
		let token: UInt64 = connectionToken
		pendingInputRecoveryID = token
		lifecycleOperations += 1
		discardQueuedEventsForReconnectLocked()
		signalStateChangeLocked()
		return ReconnectAction(
			transport: activeTransport,
			token: token,
			deadline: .init(timeout: limits.reconnectTimeout),
			uncertainty: uncertainty
		)
	}

	private func discardQueuedEventsForReconnectLocked() {
		outboundEvents.removeAll(keepingCapacity: true)
		queuedInputBytes = 0
		if let latestResize {
			outboundEvents.append(.resize(latestResize))
		}
	}

	private func performReconnect(_ action: ReconnectAction) {
		lifecycleQueue.async { [weak self] in
			guard let self else { return }
			action.transport.close()
			switch waitForFeedsToDrain(
				token: action.token,
				deadline: action.deadline
			) {
			case .drained:
				reconnect(
					token: action.token,
					deadline: action.deadline
				)
			case .timedOut:
				requestStop(
					reason: .reconnectTimedOut(
						"Surface feed did not quiesce before deadline"
					)
				)
			case .cancelled:
				break
			}
			finishLifecycleOperation()
		}
	}

	private func performInitialConnection(token: UInt64) {
		let nextOffset: UInt64
		condition.lock()
		guard phase == .connecting, connectionToken == token else {
			condition.unlock()
			return
		}
		nextOffset = committedOffset
		condition.unlock()

		do {
			let newTransport: any TerminalAttachmentTransport =
				try connector.connect(
					nextOffset: nextOffset,
					deadline: .init(timeout: limits.reconnectTimeout)
				)
			install(
				transport: newTransport,
				token: token,
				reconnected: false
			)
		} catch {
			requestStop(
				reason: .initialConnectionFailed(describeTransportError(error))
			)
		}
	}

	private func reconnect(
		token: UInt64,
		deadline: AttachmentConnectionDeadline
	) {
		var attempt: Int = 0
		var lastError: String = "deadline expired"
		while !deadline.isExpired {
			let nextOffset: UInt64
			condition.lock()
			guard phase == .reconnecting, connectionToken == token else {
				condition.unlock()
				return
			}
			nextOffset = committedOffset
			condition.unlock()

			do {
				let newTransport: any TerminalAttachmentTransport =
					try connector.connect(
						nextOffset: nextOffset,
						deadline: deadline
					)
				guard !deadline.isExpired else {
					newTransport.close()
					requestStop(
						reason: .reconnectTimedOut("connection completed after deadline")
					)
					return
				}
				install(
					transport: newTransport,
					token: token,
					reconnected: true
				)
				return
			} catch {
				lastError = describeTransportError(error)
				guard !deadline.isExpired else {
					requestStop(reason: .reconnectTimedOut(lastError))
					return
				}
				guard isRetryableReconnectError(error) else {
					requestStop(reason: .protocolFailure(lastError))
					return
				}
			}

			let delay: TimeInterval = limits.reconnectRetryDelays[
				min(attempt, limits.reconnectRetryDelays.count - 1)
			]
			attempt += 1
			let retryDeadline: AttachmentConnectionDeadline =
				deadline.capped(to: delay)
			guard waitForRetry(
				token: token,
				until: retryDeadline
			) else {
				return
			}
		}
		requestStop(reason: .reconnectTimedOut(lastError))
	}

	private func install(
		transport newTransport: any TerminalAttachmentTransport,
		token: UInt64,
		reconnected: Bool
	) {
		condition.lock()
		guard
			connectionToken == token,
			phase == (reconnected ? .reconnecting : .connecting)
		else {
			condition.unlock()
			newTransport.close()
			return
		}

		generation &+= 1
		transport = newTransport
		phase = .running
		if reconnected {
			inputEnabled = false
			inputPausedAfterReconnect = true
			pendingInputRecoveryID = token
		} else {
			inputEnabled = true
			inputPausedAfterReconnect = false
			pendingInputRecoveryID = nil
		}
		let offset: UInt64 = committedOffset
		let event: TerminalAttachmentPumpEvent = reconnected
			? .reconnected(
				recoveryID: token,
				offset: offset,
				inputPaused: true
			)
			: .connected(offset: offset)
		emit(event)
		signalStateChangeLocked()
		condition.unlock()
	}

	private func requestStop(reason: TerminalAttachmentStopReason) {
		condition.lock()
		let action: StopAction? = prepareStopLocked(reason: reason)
		signalStateChangeLocked()
		condition.unlock()
		performStopIfPresent(action)
	}

	private func prepareStopLocked(
		reason: TerminalAttachmentStopReason
	) -> StopAction? {
		guard phase != .stopping, phase != .stopped else { return nil }
		phase = .stopping
		stopReason = reason
		inputEnabled = false
		inputPausedAfterReconnect = false
		pendingInputRecoveryID = nil
		if !workersStarted {
			readerFinished = true
			writerFinished = true
		}
		connectionToken &+= 1
		let activeTransport: (any TerminalAttachmentTransport)? = transport
		transport = nil
		outboundEvents.removeAll(keepingCapacity: false)
		queuedInputBytes = 0
		if activeTransport != nil {
			lifecycleOperations += 1
		}
		let stoppedEvent: TerminalAttachmentPumpEvent? =
			activeTransport == nil ? finishStoppingIfReadyLocked() : nil
		return StopAction(
			transport: activeTransport,
			stoppedEvent: stoppedEvent
		)
	}

	private func performStopIfPresent(_ action: StopAction?) {
		guard let action else { return }
		if let activeTransport = action.transport {
			lifecycleQueue.async { [weak self] in
				activeTransport.close()
				self?.finishLifecycleOperation()
			}
		} else {
			emitIfPresent(action.stoppedEvent)
		}
	}

	private func enforceDrainDeadline() {
		let uncertaintyEvent: TerminalAttachmentPumpEvent?
		let stopAction: StopAction?
		condition.lock()
		guard phase == .draining else {
			condition.unlock()
			return
		}
		if outboundEvents.isEmpty, writerInFlight == nil {
			uncertaintyEvent = nil
			stopAction = prepareStopLocked(reason: .detached)
		} else {
			uncertaintyEvent = .inputDeliveryUncertain(
				recoveryID: connectionToken,
				reason: .drainTimedOut
			)
			stopAction = prepareStopLocked(reason: .drainTimedOut)
		}
		signalStateChangeLocked()
		condition.unlock()
		emitIfPresent(uncertaintyEvent)
		performStopIfPresent(stopAction)
	}

	private func finishLifecycleOperation() {
		condition.lock()
		lifecycleOperations -= 1
		let stoppedEvent: TerminalAttachmentPumpEvent? =
			finishStoppingIfReadyLocked()
		signalStateChangeLocked()
		condition.unlock()
		emitIfPresent(stoppedEvent)
	}

	private func finishStoppingIfReadyLocked() -> TerminalAttachmentPumpEvent? {
		guard
			phase == .stopping,
			readerFinished,
			writerFinished,
			lifecycleOperations == 0,
			feedsInFlight == 0,
			writerInFlight == nil,
			!stoppedEventPublished,
			let stopReason
		else {
			return nil
		}
		phase = .stopped
		stoppedEventPublished = true
		return .stopped(reason: stopReason, resumeOffset: committedOffset)
	}

	private func waitForFeedsToDrain(
		token: UInt64,
		deadline: AttachmentConnectionDeadline
	) -> FeedDrainResult {
		while true {
			condition.lock()
			guard phase == .reconnecting, connectionToken == token else {
				condition.unlock()
				return .cancelled
			}
			guard feedsInFlight > 0 else {
				condition.unlock()
				return deadline.isExpired ? .timedOut : .drained
			}
			discardPendingStateChangeSignalLocked()
			condition.unlock()
			guard !deadline.isExpired else {
				return .timedOut
			}
			if !waitForStateChange(until: deadline) {
				return .timedOut
			}
		}
	}

	private func waitForRetry(
		token: UInt64,
		until deadline: AttachmentConnectionDeadline
	) -> Bool {
		while true {
			condition.lock()
			guard phase == .reconnecting, connectionToken == token else {
				condition.unlock()
				return false
			}
			discardPendingStateChangeSignalLocked()
			condition.unlock()
			guard !deadline.isExpired else { return true }
			if !waitForStateChange(until: deadline) {
				return true
			}
		}
	}

	private func isCurrentConnection(
		transport candidate: any TerminalAttachmentTransport,
		generation candidateGeneration: UInt64
	) -> Bool {
		condition.lock()
		defer { condition.unlock() }
		return isCurrentConnectionLocked(
			transport: candidate,
			generation: candidateGeneration
		)
	}

	private func isCurrentConnectionLocked(
		transport candidate: any TerminalAttachmentTransport,
		generation candidateGeneration: UInt64
	) -> Bool {
		guard
			let currentTransport = transport,
			generation == candidateGeneration
		else {
			return false
		}
		return currentTransport === candidate
	}

	private func isRetryableReconnectError(_ error: Error) -> Bool {
		guard let error = error as? AttachmentClientError else {
			return false
		}
		switch error {
		case .transport, .closed:
			return true
		case .serverRejected(let code, _):
			return code == "session_already_attached"
		case .invalidSocketPath,
			.invalidRequest,
			.invalidResponse,
			.protocolViolation:
			return false
		}
	}

	private func isProtocolError(_ error: Error) -> Bool {
		guard let error = error as? AttachmentClientError else {
			return false
		}
		switch error {
		case .invalidRequest,
			.invalidResponse,
			.protocolViolation,
			.serverRejected:
			return true
		case .invalidSocketPath, .transport, .closed:
			return false
		}
	}

	private func describeTransportError(_ error: Error) -> String {
		if let attachmentError = error as? AttachmentClientError {
			return attachmentError.description
		}
		return "transport error of type "
			+ String(reflecting: type(of: error))
	}

	private func describeKnownError(_ error: Error) -> String {
		if let attachmentError = error as? AttachmentClientError {
			return attachmentError.description
		}
		return String(reflecting: type(of: error))
	}

	private func emit(_ event: TerminalAttachmentPumpEvent) {
		eventDeliveryQueue.async { [eventHandler] in
			eventHandler(event)
		}
	}

	private func emitIfPresent(_ event: TerminalAttachmentPumpEvent?) {
		if let event {
			emit(event)
		}
	}

	private func signalStateChangeLocked() {
		condition.broadcast()
		guard !stateChangeSignalPending else { return }
		stateChangeSignalPending = true
		stateChanges.signal()
	}

	private func discardPendingStateChangeSignalLocked() {
		guard stateChangeSignalPending else { return }
		if stateChanges.wait(timeout: .now()) == .success {
			stateChangeSignalPending = false
		}
	}

	private func waitForStateChange(
		until deadline: AttachmentConnectionDeadline
	) -> Bool {
		guard stateChanges.wait(timeout: deadline.dispatchTime) == .success else {
			return false
		}
		condition.lock()
		stateChangeSignalPending = false
		condition.unlock()
		return true
	}
}
