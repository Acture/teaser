import Darwin
import Foundation

private enum TestFailure: Error, CustomStringConvertible {
	case assertion(String)

	var description: String {
		switch self {
		case .assertion(let message):
			return message
		}
	}
}

private func require(
	_ condition: @autoclosure () -> Bool,
	_ message: String
) throws {
	guard condition() else {
		throw TestFailure.assertion(message)
	}
}

private enum RecordedWrite: Equatable {
	case input([UInt8])
	case resize(AttachmentTerminalSize)
}

private final class FakeTransport:
	TerminalAttachmentTransport, @unchecked Sendable
{
	private enum ReadStep {
		case frame(AttachmentServerFrame)
		case failure(AttachmentClientError)
	}

	private let condition: NSCondition = .init()
	private var unreadOffset: UInt64
	private var readSteps: [ReadStep] = []
	private var readStartCount: Int = 0
	private var readReturnsBlocked: Bool
	private var recordedWrites: [RecordedWrite] = []
	private var writeStartCount: Int = 0
	private var writesBlocked: Bool
	private var writeFailure: (any Error)?
	private var closed: Bool = false
	private var closeCount: Int = 0

	init(
		nextUnreadOffset: UInt64 = 0,
		blockReadReturns: Bool = false,
		blockWrites: Bool = false,
		writeFailure: (any Error)? = nil
	) {
		unreadOffset = nextUnreadOffset
		readReturnsBlocked = blockReadReturns
		writesBlocked = blockWrites
		self.writeFailure = writeFailure
	}

	var nextUnreadOffset: UInt64 {
		condition.lock()
		defer { condition.unlock() }
		return unreadOffset
	}

	func sendInput(_ bytes: [UInt8]) throws {
		try send(.input(bytes))
	}

	func sendResize(_ size: AttachmentTerminalSize) throws {
		try send(.resize(size))
	}

	func readFrame() throws -> AttachmentServerFrame {
		condition.lock()
		readStartCount += 1
		condition.broadcast()
		while readSteps.isEmpty, !closed {
			condition.wait()
		}
		guard !closed else {
			condition.unlock()
			throw AttachmentClientError.closed
		}
		let step: ReadStep = readSteps.removeFirst()
		switch step {
		case .failure(let error):
			condition.unlock()
			throw error
		case .frame(let frame):
			while readReturnsBlocked {
				condition.wait()
			}
			if case .output(let offset, let bytes) = frame {
				unreadOffset = offset + UInt64(bytes.count)
			}
			condition.unlock()
			return frame
		}
	}

	func close() {
		condition.lock()
		closeCount += 1
		closed = true
		condition.broadcast()
		condition.unlock()
	}

	func push(_ frame: AttachmentServerFrame) {
		condition.lock()
		readSteps.append(.frame(frame))
		condition.broadcast()
		condition.unlock()
	}

	func failRead(_ error: AttachmentClientError) {
		condition.lock()
		readSteps.append(.failure(error))
		condition.broadcast()
		condition.unlock()
	}

	func releaseWrites() {
		condition.lock()
		writesBlocked = false
		condition.broadcast()
		condition.unlock()
	}

	func releaseReadReturns() {
		condition.lock()
		readReturnsBlocked = false
		condition.broadcast()
		condition.unlock()
	}

	func waitForReadStarts(
		_ expected: Int,
		timeout: TimeInterval = 0.5
	) -> Bool {
		condition.lock()
		defer { condition.unlock() }
		let deadline: Date = Date().addingTimeInterval(timeout)
		while readStartCount < expected {
			guard condition.wait(until: deadline) else {
				return readStartCount >= expected
			}
		}
		return true
	}

	func waitForWriteStarts(
		_ expected: Int,
		timeout: TimeInterval = 0.5
	) -> Bool {
		condition.lock()
		defer { condition.unlock() }
		let deadline: Date = Date().addingTimeInterval(timeout)
		while writeStartCount < expected {
			guard condition.wait(until: deadline) else {
				return writeStartCount >= expected
			}
		}
		return true
	}

	func waitForWrites(
		_ expected: Int,
		timeout: TimeInterval = 0.5
	) -> Bool {
		condition.lock()
		defer { condition.unlock() }
		let deadline: Date = Date().addingTimeInterval(timeout)
		while recordedWrites.count < expected {
			guard condition.wait(until: deadline) else {
				return recordedWrites.count >= expected
			}
		}
		return true
	}

	var writes: [RecordedWrite] {
		condition.lock()
		defer { condition.unlock() }
		return recordedWrites
	}

	var closeCallCount: Int {
		condition.lock()
		defer { condition.unlock() }
		return closeCount
	}

	private func send(_ write: RecordedWrite) throws {
		condition.lock()
		writeStartCount += 1
		condition.broadcast()
		while writesBlocked, !closed {
			condition.wait()
		}
		guard !closed else {
			condition.unlock()
			throw AttachmentClientError.closed
		}
		if let failure = writeFailure {
			writeFailure = nil
			condition.broadcast()
			condition.unlock()
			throw failure
		}
		recordedWrites.append(write)
		condition.broadcast()
		condition.unlock()
	}
}

private final class FakeConnector:
	TerminalAttachmentConnecting, @unchecked Sendable
{
	enum Action {
		case transport(FakeTransport)
		case failure(any Error)
		case delayedFailure(TimeInterval, any Error)
		case deadlineFailure(any Error)
	}

	private let condition: NSCondition = .init()
	private var actions: [Action]
	private let fallbackError: AttachmentClientError
	private var requestedOffsets: [UInt64] = []
	private var connectionAttemptTimes: [UInt64] = []
	private var connectionDeadlines: [UInt64] = []

	init(
		actions: [Action],
		fallbackError: AttachmentClientError = .transport("no scripted connection")
	) {
		self.actions = actions
		self.fallbackError = fallbackError
	}

	func connect(
		nextOffset: UInt64,
		deadline: AttachmentConnectionDeadline
	) throws -> any TerminalAttachmentTransport {
		condition.lock()
		requestedOffsets.append(nextOffset)
		connectionAttemptTimes.append(DispatchTime.now().uptimeNanoseconds)
		connectionDeadlines.append(deadline.uptimeNanoseconds)
		let action: Action
		if actions.isEmpty {
			action = .failure(fallbackError)
		} else {
			action = actions.removeFirst()
		}
		condition.broadcast()
		condition.unlock()

		switch action {
		case .transport(let transport):
			return transport
		case .failure(let error):
			throw error
		case .delayedFailure(let delay, let error):
			Thread.sleep(
				forTimeInterval: min(delay, deadline.remainingTimeInterval)
			)
			throw error
		case .deadlineFailure(let error):
			while !deadline.isExpired {
				Thread.sleep(
					forTimeInterval: min(
						0.005,
						deadline.remainingTimeInterval
					)
				)
			}
			throw error
		}
	}

	func waitForConnectionAttempts(
		_ expected: Int,
		timeout: TimeInterval = 0.5
	) -> Bool {
		condition.lock()
		defer { condition.unlock() }
		let deadline: Date = Date().addingTimeInterval(timeout)
		while requestedOffsets.count < expected {
			guard condition.wait(until: deadline) else {
				return requestedOffsets.count >= expected
			}
		}
		return true
	}

	var offsets: [UInt64] {
		condition.lock()
		defer { condition.unlock() }
		return requestedOffsets
	}

	var attemptTimes: [UInt64] {
		condition.lock()
		defer { condition.unlock() }
		return connectionAttemptTimes
	}

	var deadlineUptimes: [UInt64] {
		condition.lock()
		defer { condition.unlock() }
		return connectionDeadlines
	}
}

private final class BlockingDescriptionError:
	Error, CustomStringConvertible, @unchecked Sendable
{
	private let condition: NSCondition = .init()
	private let message: String
	private var descriptionStarted: Bool = false
	private var descriptionReleased: Bool = false

	init(_ message: String) {
		self.message = message
	}

	var description: String {
		condition.lock()
		descriptionStarted = true
		condition.broadcast()
		while !descriptionReleased {
			condition.wait()
		}
		condition.unlock()
		return message
	}

	func waitForDescription(timeout: TimeInterval = 0.5) -> Bool {
		condition.lock()
		defer { condition.unlock() }
		let deadline: Date = Date().addingTimeInterval(timeout)
		while !descriptionStarted {
			guard condition.wait(until: deadline) else {
				return descriptionStarted
			}
		}
		return true
	}

	func releaseDescription() {
		condition.lock()
		descriptionReleased = true
		condition.broadcast()
		condition.unlock()
	}

	var wasDescriptionRequested: Bool {
		condition.lock()
		defer { condition.unlock() }
		return descriptionStarted
	}
}

private final class EnqueueResultBox: @unchecked Sendable {
	private let condition: NSCondition = .init()
	private var storedResult: TerminalAttachmentEnqueueResult?

	func record(_ result: TerminalAttachmentEnqueueResult) {
		condition.lock()
		storedResult = result
		condition.broadcast()
		condition.unlock()
	}

	func wait(timeout: TimeInterval) -> Bool {
		condition.lock()
		defer { condition.unlock() }
		let deadline: Date = Date().addingTimeInterval(timeout)
		while storedResult == nil {
			guard condition.wait(until: deadline) else {
				return storedResult != nil
			}
		}
		return true
	}

	var result: TerminalAttachmentEnqueueResult? {
		condition.lock()
		defer { condition.unlock() }
		return storedResult
	}
}

private final class TrickleServerState: @unchecked Sendable {
	private let lock: NSLock = .init()
	private var acceptedConnection: Bool = false
	private var sentBytes: Int = 0

	func recordAcceptedConnection() {
		lock.lock()
		acceptedConnection = true
		lock.unlock()
	}

	func recordSentByte() {
		lock.lock()
		sentBytes += 1
		lock.unlock()
	}

	var snapshot: (accepted: Bool, sentBytes: Int) {
		lock.lock()
		defer { lock.unlock() }
		return (acceptedConnection, sentBytes)
	}
}

private final class FakeOutputSink:
	TerminalOutputSink, @unchecked Sendable
{
	private let condition: NSCondition = .init()
	private var recordedFeeds: [[UInt8]] = []
	private var feedStartCount: Int = 0
	private var feedsBlocked: Bool
	private var feedFailure: (any Error)?

	init(
		blockFeeds: Bool = false,
		feedFailure: (any Error)? = nil
	) {
		feedsBlocked = blockFeeds
		self.feedFailure = feedFailure
	}

	func feed(_ bytes: [UInt8]) throws {
		condition.lock()
		feedStartCount += 1
		condition.broadcast()
		while feedsBlocked {
			condition.wait()
		}
		if let failure = feedFailure {
			feedFailure = nil
			condition.broadcast()
			condition.unlock()
			throw failure
		}
		recordedFeeds.append(bytes)
		condition.broadcast()
		condition.unlock()
	}

	func releaseFeeds() {
		condition.lock()
		feedsBlocked = false
		condition.broadcast()
		condition.unlock()
	}

	func waitForFeedStarts(
		_ expected: Int,
		timeout: TimeInterval = 0.5
	) -> Bool {
		condition.lock()
		defer { condition.unlock() }
		let deadline: Date = Date().addingTimeInterval(timeout)
		while feedStartCount < expected {
			guard condition.wait(until: deadline) else {
				return feedStartCount >= expected
			}
		}
		return true
	}

	func waitForFeeds(
		_ expected: Int,
		timeout: TimeInterval = 0.5
	) -> Bool {
		condition.lock()
		defer { condition.unlock() }
		let deadline: Date = Date().addingTimeInterval(timeout)
		while recordedFeeds.count < expected {
			guard condition.wait(until: deadline) else {
				return recordedFeeds.count >= expected
			}
		}
		return true
	}

	var feeds: [[UInt8]] {
		condition.lock()
		defer { condition.unlock() }
		return recordedFeeds
	}

	var startedFeedCount: Int {
		condition.lock()
		defer { condition.unlock() }
		return feedStartCount
	}
}

private final class EventRecorder: @unchecked Sendable {
	private let condition: NSCondition = .init()
	private var recordedEvents: [TerminalAttachmentPumpEvent] = []

	func append(_ event: TerminalAttachmentPumpEvent) {
		condition.lock()
		recordedEvents.append(event)
		condition.broadcast()
		condition.unlock()
	}

	func waitForEvent(
		timeout: TimeInterval = 0.5,
		matching predicate: (TerminalAttachmentPumpEvent) -> Bool
	) -> Bool {
		condition.lock()
		defer { condition.unlock() }
		let deadline: Date = Date().addingTimeInterval(timeout)
		while !recordedEvents.contains(where: predicate) {
			guard condition.wait(until: deadline) else {
				return recordedEvents.contains(where: predicate)
			}
		}
		return true
	}

	func waitForEventCount(
		_ expected: Int,
		timeout: TimeInterval = 0.5,
		matching predicate: (TerminalAttachmentPumpEvent) -> Bool
	) -> Bool {
		condition.lock()
		defer { condition.unlock() }
		let deadline: Date = Date().addingTimeInterval(timeout)
		while recordedEvents.filter(predicate).count < expected {
			guard condition.wait(until: deadline) else {
				return recordedEvents.filter(predicate).count >= expected
			}
		}
		return true
	}

	var events: [TerminalAttachmentPumpEvent] {
		condition.lock()
		defer { condition.unlock() }
		return recordedEvents
	}
}

private func makeLimits(
	maximumInputBytes: Int = 1_024,
	maximumEvents: Int = 64,
	reconnectTimeout: TimeInterval = 0.2,
	detachDrainTimeout: TimeInterval = 0.1
) -> TerminalAttachmentPumpLimits {
	.init(
		maximumInputBytes: maximumInputBytes,
		maximumEvents: maximumEvents,
		reconnectTimeout: reconnectTimeout,
		detachDrainTimeout: detachDrainTimeout,
		reconnectRetryDelays: [0.002, 0.005, 0.01]
	)
}

private func makePump(
	connector: FakeConnector,
	sink: FakeOutputSink,
	limits: TerminalAttachmentPumpLimits = makeLimits()
) -> (TerminalAttachmentPump, EventRecorder) {
	let recorder: EventRecorder = .init()
	let queue: DispatchQueue = .init(
		label: "dev.teaser.terminal-attachment.tests.events"
	)
	let pump: TerminalAttachmentPump = .init(
		connector: connector,
		outputSink: sink,
		limits: limits,
		eventQueue: queue
	) { [recorder] event in
		recorder.append(event)
	}
	return (pump, recorder)
}

private func waitForConnected(_ recorder: EventRecorder) throws {
	try require(
		recorder.waitForEvent {
			if case .connected = $0 {
				return true
			}
			return false
		},
		"pump did not publish its initial connected event"
	)
}

private struct RecordedUncertainty: Equatable {
	let recoveryID: UInt64
	let reason: TerminalAttachmentUncertaintyReason
}

private struct RecordedRecovery: Equatable {
	let recoveryID: UInt64
	let offset: UInt64
	let inputPaused: Bool
}

private func uncertaintyEvents(
	in events: [TerminalAttachmentPumpEvent]
) -> [RecordedUncertainty] {
	events.compactMap { event in
		if case .inputDeliveryUncertain(let recoveryID, let reason) = event {
			return .init(recoveryID: recoveryID, reason: reason)
		}
		return nil
	}
}

private func recoveryEvents(
	in events: [TerminalAttachmentPumpEvent]
) -> [RecordedRecovery] {
	events.compactMap { event in
		if case .reconnected(let recoveryID, let offset, let inputPaused) = event {
			return .init(
				recoveryID: recoveryID,
				offset: offset,
				inputPaused: inputPaused
			)
		}
		return nil
	}
}

private func stoppedReason(
	in events: [TerminalAttachmentPumpEvent]
) -> TerminalAttachmentStopReason? {
	events.reversed().compactMap { event in
		if case .stopped(let reason, _) = event {
			return reason
		}
		return nil
	}.first
}

private func testEnqueueDoesNotBlockOnSlowWriter() throws {
	let transport: FakeTransport = .init(blockWrites: true)
	let connector: FakeConnector = .init(actions: [.transport(transport)])
	let sink: FakeOutputSink = .init()
	let (pump, recorder) = makePump(connector: connector, sink: sink)
	defer {
		transport.releaseWrites()
		pump.detach()
		_ = pump.waitUntilStopped(timeout: 0.5)
	}

	pump.start()
	try waitForConnected(recorder)
	try require(
		pump.enqueueInput([1]) == .accepted,
		"first input was not accepted"
	)
	try require(
		transport.waitForWriteStarts(1),
		"writer did not enter the blocking transport"
	)

	let started: UInt64 = DispatchTime.now().uptimeNanoseconds
	let result: TerminalAttachmentEnqueueResult = pump.enqueueInput([2, 3])
	let elapsed: TimeInterval = Double(
		DispatchTime.now().uptimeNanoseconds - started
	) / 1_000_000_000
	try require(result == .accepted, "second input was not accepted")
	try require(
		elapsed < 0.05,
		"enqueue waited \(elapsed) seconds for a blocked writer"
	)

	transport.releaseWrites()
	try require(
		transport.waitForWrites(2),
		"writer did not deliver both accepted inputs"
	)
}

private func testDetachBeforeStartStopsWithoutWorkers() throws {
	let connector: FakeConnector = .init(actions: [])
	let sink: FakeOutputSink = .init()
	let (pump, recorder) = makePump(connector: connector, sink: sink)

	pump.detach()
	try require(
		pump.waitUntilStopped(timeout: 0.1),
		"prepared pump did not stop without launching workers"
	)
	try require(
		recorder.waitForEvent {
			if case .stopped(reason: .detached, resumeOffset: 0) = $0 {
				return true
			}
			return false
		},
		"prepared pump did not publish a detached terminal event"
	)
	try require(
		connector.offsets.isEmpty,
		"detaching a prepared pump attempted a connection"
	)
}

private func testFifoAndTailResizeCoalescing() throws {
	let transport: FakeTransport = .init(blockWrites: true)
	let connector: FakeConnector = .init(actions: [.transport(transport)])
	let sink: FakeOutputSink = .init()
	let (pump, recorder) = makePump(connector: connector, sink: sink)
	let firstSize: AttachmentTerminalSize = .init(
		rows: 20,
		columns: 80,
		pixelWidth: 800,
		pixelHeight: 400
	)
	let secondSize: AttachmentTerminalSize = .init(
		rows: 30,
		columns: 120,
		pixelWidth: 1_200,
		pixelHeight: 600
	)
	defer {
		transport.releaseWrites()
		pump.detach()
		_ = pump.waitUntilStopped(timeout: 0.5)
	}

	pump.start()
	try waitForConnected(recorder)
	try require(pump.enqueueInput([1]) == .accepted, "input 1 rejected")
	try require(
		transport.waitForWriteStarts(1),
		"input 1 did not enter the writer"
	)
	try require(
		pump.enqueueResize(firstSize) == .accepted,
		"first resize rejected"
	)
	try require(
		pump.enqueueResize(secondSize) == .accepted,
		"second resize rejected"
	)
	try require(pump.enqueueInput([2]) == .accepted, "input 2 rejected")

	transport.releaseWrites()
	try require(
		transport.waitForWrites(3),
		"writer did not deliver the expected FIFO"
	)
	try require(
		transport.writes == [
			.input([1]),
			.resize(secondSize),
			.input([2]),
		],
		"writer reordered events or coalesced a resize across input"
	)
}

private func testByteOverflowIsAtomic() throws {
	let first: FakeTransport = .init(blockWrites: true)
	let second: FakeTransport = .init()
	let connector: FakeConnector = .init(
		actions: [.transport(first), .transport(second)]
	)
	let sink: FakeOutputSink = .init()
	let (pump, recorder) = makePump(
		connector: connector,
		sink: sink,
		limits: makeLimits(maximumInputBytes: 4)
	)
	defer {
		first.releaseWrites()
		pump.detach()
		_ = pump.waitUntilStopped(timeout: 0.5)
	}

	pump.start()
	try waitForConnected(recorder)
	try require(pump.enqueueInput([1, 2]) == .accepted, "input 1 rejected")
	try require(first.waitForWriteStarts(1), "input 1 did not begin sending")
	try require(pump.enqueueInput([3, 4]) == .accepted, "input 2 rejected")
	try require(
		pump.enqueueInput([5]) == .overflow,
		"byte overflow was not rejected"
	)
	try require(
		recorder.waitForEvent {
			if case .reconnected = $0 {
				return true
			}
			return false
		},
		"pump did not reconnect after byte overflow"
	)
	try require(
		uncertaintyEvents(in: recorder.events).map(\.reason) == [.queueOverflow],
		"byte overflow did not publish exactly one uncertainty event"
	)
	try require(
		pump.enqueueInput([6]) == .inputPaused,
		"input was not paused after overflow reconnect"
	)
	let recoveryID: UInt64? = recoveryEvents(in: recorder.events).last?.recoveryID
	try require(recoveryID != nil, "byte overflow recovery ID was not published")
	try require(
		pump.acknowledgeInputAfterReconnect(recoveryID: recoveryID ?? 0),
		"byte overflow recovery acknowledgement failed"
	)
	try require(
		pump.enqueueInput([99]) == .accepted,
		"byte overflow sentinel input was not accepted"
	)
	try require(
		second.waitForWrites(1),
		"byte overflow sentinel input was not delivered"
	)
	try require(
		second.writes == [.input([99])],
		"queued or overflowing input was replayed before the sentinel"
	)
}

private func testEventOverflowIsAtomic() throws {
	let first: FakeTransport = .init(blockWrites: true)
	let second: FakeTransport = .init()
	let connector: FakeConnector = .init(
		actions: [.transport(first), .transport(second)]
	)
	let sink: FakeOutputSink = .init()
	let (pump, recorder) = makePump(
		connector: connector,
		sink: sink,
		limits: makeLimits(maximumEvents: 2)
	)
	let rejectedSize: AttachmentTerminalSize = .init(
		rows: 40,
		columns: 160,
		pixelWidth: 1_600,
		pixelHeight: 800
	)
	defer {
		first.releaseWrites()
		pump.detach()
		_ = pump.waitUntilStopped(timeout: 0.5)
	}

	pump.start()
	try waitForConnected(recorder)
	try require(pump.enqueueInput([1]) == .accepted, "input 1 rejected")
	try require(first.waitForWriteStarts(1), "input 1 did not begin sending")
	try require(pump.enqueueInput([2]) == .accepted, "input 2 rejected")
	try require(
		pump.enqueueResize(rejectedSize) == .overflow,
		"event overflow was not rejected"
	)
	try require(
		recorder.waitForEvent {
			if case .reconnected = $0 {
				return true
			}
			return false
		},
		"pump did not reconnect after event overflow"
	)
	Thread.sleep(forTimeInterval: 0.02)
	try require(
		uncertaintyEvents(in: recorder.events).map(\.reason) == [.queueOverflow],
		"event overflow did not publish exactly one uncertainty event"
	)
	let recoveryID: UInt64? = recoveryEvents(in: recorder.events).last?.recoveryID
	try require(recoveryID != nil, "event overflow recovery ID was not published")
	try require(
		pump.acknowledgeInputAfterReconnect(recoveryID: recoveryID ?? 0),
		"event overflow recovery acknowledgement failed"
	)
	try require(
		pump.enqueueInput([98]) == .accepted,
		"event overflow sentinel input was not accepted"
	)
	try require(
		second.waitForWrites(1),
		"event overflow sentinel input was not delivered"
	)
	try require(
		second.writes == [.input([98])],
		"the rejected resize or queued input was replayed before the sentinel"
	)
}

private func testOutputOrderAndExitAfterFinalFeed() throws {
	let transport: FakeTransport = .init()
	let connector: FakeConnector = .init(actions: [.transport(transport)])
	let sink: FakeOutputSink = .init()
	let (pump, recorder) = makePump(connector: connector, sink: sink)

	pump.start()
	try waitForConnected(recorder)
	transport.push(.output(offset: 0, bytes: [1]))
	transport.push(.output(offset: 1, bytes: [2, 3]))
	transport.push(.exit(code: 7))

	try require(
		pump.waitUntilStopped(timeout: 0.5),
		"pump did not stop after exit"
	)
	try require(
		recorder.waitForEvent {
			if case .stopped = $0 {
				return true
			}
			return false
		},
		"pump did not publish its stopped event"
	)
	try require(
		sink.feeds == [[1], [2, 3]],
		"output was not fed in transport order"
	)
	try require(
		pump.committedOutputOffset == 3,
		"final output was not committed before stop"
	)
	try require(
		stoppedReason(in: recorder.events) == .processExited(7),
		"exit stop reason was not preserved"
	)
}

private func testReconnectUsesCommittedOffsetAndPausesInput() throws {
	let first: FakeTransport = .init(blockWrites: true)
	let second: FakeTransport = .init(nextUnreadOffset: 2)
	let connector: FakeConnector = .init(
		actions: [.transport(first), .transport(second)]
	)
	let sink: FakeOutputSink = .init()
	let (pump, recorder) = makePump(connector: connector, sink: sink)
	defer {
		first.releaseWrites()
		pump.detach()
		_ = pump.waitUntilStopped(timeout: 0.5)
	}

	pump.start()
	try waitForConnected(recorder)
	first.push(.output(offset: 0, bytes: [10, 11]))
	try require(sink.waitForFeeds(1), "initial output was not fed")
	try require(pump.committedOutputOffset == 2, "initial output not committed")

	try require(pump.enqueueInput([1]) == .accepted, "old input 1 rejected")
	try require(first.waitForWriteStarts(1), "old input did not begin sending")
	try require(pump.enqueueInput([2]) == .accepted, "old input 2 rejected")
	let retainedResize: AttachmentTerminalSize = .init(
		rows: 48,
		columns: 132,
		pixelWidth: 1_320,
		pixelHeight: 960
	)
	try require(
		pump.enqueueResize(retainedResize) == .accepted,
		"latest resize was not retained before reconnect"
	)
	first.failRead(.transport("injected drop"))

	try require(
		recorder.waitForEvent {
			if case .reconnected(
				recoveryID: _,
				offset: 2,
				inputPaused: true
			) = $0 {
				return true
			}
			return false
		},
		"pump did not reconnect from the committed offset with input paused"
	)
	try require(
		connector.offsets.prefix(2).elementsEqual([0, 2]),
		"reconnect did not request the committed offset"
	)
	try require(
		pump.enqueueInput([3]) == .inputPaused,
		"input was accepted before reconnect acknowledgement"
	)

	second.push(.output(offset: 2, bytes: [12]))
	try require(
		sink.waitForFeeds(2),
		"output did not resume while input remained paused"
	)
	try require(
		sink.feeds == [[10, 11], [12]],
		"reconnected output was not fed in order"
	)
	try require(
		second.waitForWrites(1),
		"latest accepted resize was not restored after reconnect"
	)
	try require(
		second.writes == [.resize(retainedResize)],
		"old input was replayed or the wrong resize was restored"
	)

	let recoveryID: UInt64? = recorder.events.compactMap { event in
		if case .reconnected(let recoveryID, 2, true) = event {
			return recoveryID
		}
		return nil
	}.last
	try require(recoveryID != nil, "reconnect recovery ID was not published")
	try require(
		pump.acknowledgeInputAfterReconnect(recoveryID: recoveryID ?? 0),
		"input acknowledgement was rejected"
	)
	try require(
		pump.enqueueInput([4]) == .accepted,
		"new input was not accepted after acknowledgement"
	)
	try require(
		second.waitForWrites(2),
		"new input was not delivered after acknowledgement"
	)
	try require(
		second.writes == [.resize(retainedResize), .input([4])],
		"replacement transport received unexpected input"
	)
}

private func testReconnectTimeoutStopsPump() throws {
	let first: FakeTransport = .init()
	let connector: FakeConnector = .init(
		actions: [.transport(first)],
		fallbackError: .transport("still offline")
	)
	let sink: FakeOutputSink = .init()
	let (pump, recorder) = makePump(
		connector: connector,
		sink: sink,
		limits: makeLimits(reconnectTimeout: 0.04)
	)

	pump.start()
	try waitForConnected(recorder)
	first.failRead(.transport("drop before timeout"))
	try require(
		pump.waitUntilStopped(timeout: 0.5),
		"pump did not stop after reconnect deadline"
	)
	try require(
		recorder.waitForEvent {
			if case .stopped(reason: .reconnectTimedOut, resumeOffset: 0) = $0 {
				return true
			}
			return false
		},
		"pump did not report reconnect timeout"
	)
	try require(
		connector.offsets.count >= 2,
		"pump did not attempt reconnect before timeout"
	)
	try require(
		uncertaintyEvents(in: recorder.events).count == 1,
		"transport loss uncertainty was not emitted exactly once"
	)
}

private func testReplayGapIsFatal() throws {
	let transport: FakeTransport = .init()
	let connector: FakeConnector = .init(actions: [.transport(transport)])
	let sink: FakeOutputSink = .init()
	let (pump, recorder) = makePump(connector: connector, sink: sink)

	pump.start()
	try waitForConnected(recorder)
	transport.push(.replayGap(requested: 4, availableFrom: 9))
	transport.push(.output(offset: 9, bytes: [99]))
	try require(
		pump.waitUntilStopped(timeout: 0.5),
		"pump did not stop on replay gap"
	)
	try require(
		recorder.waitForEvent {
			if case .stopped = $0 {
				return true
			}
			return false
		},
		"pump did not publish replay-gap stop"
	)
	try require(sink.feeds.isEmpty, "output after replay gap was fed")
	try require(
		stoppedReason(in: recorder.events)
			== .replayGap(requested: 4, availableFrom: 9),
		"replay-gap stop reason was not preserved"
	)
}

private func testDetachDrainsQueuedInput() throws {
	let transport: FakeTransport = .init(blockWrites: true)
	let connector: FakeConnector = .init(actions: [.transport(transport)])
	let sink: FakeOutputSink = .init()
	let (pump, recorder) = makePump(
		connector: connector,
		sink: sink,
		limits: makeLimits(detachDrainTimeout: 0.2)
	)
	defer { transport.releaseWrites() }

	pump.start()
	try waitForConnected(recorder)
	try require(pump.enqueueInput([9]) == .accepted, "drain input rejected")
	try require(
		transport.waitForWriteStarts(1),
		"drain input did not enter writer"
	)
	pump.detach()
	try require(
		!pump.waitUntilStopped(timeout: 0.02),
		"detach stopped before its in-flight input drained"
	)
	transport.releaseWrites()
	try require(
		pump.waitUntilStopped(timeout: 0.5),
		"detach did not stop after its input drained"
	)
	try require(
		recorder.waitForEvent {
			if case .stopped = $0 {
				return true
			}
			return false
		},
		"drained detach did not publish stopped"
	)
	try require(
		transport.writes == [.input([9])],
		"detach did not drain its accepted input"
	)
	try require(
		stoppedReason(in: recorder.events) == .detached,
		"successful drain did not stop as detached"
	)
	try require(
		uncertaintyEvents(in: recorder.events).isEmpty,
		"successful drain reported uncertain delivery"
	)
}

private func testTeardownWaitsForBlockedFeedAndUnblocksIO() throws {
	let transport: FakeTransport = .init(blockWrites: true)
	let connector: FakeConnector = .init(actions: [.transport(transport)])
	let sink: FakeOutputSink = .init(blockFeeds: true)
	let (pump, recorder) = makePump(
		connector: connector,
		sink: sink,
		limits: makeLimits(detachDrainTimeout: 0.03)
	)
	defer {
		transport.releaseWrites()
		sink.releaseFeeds()
	}

	pump.start()
	try waitForConnected(recorder)
	transport.push(.output(offset: 0, bytes: [1]))
	transport.push(.output(offset: 1, bytes: [2]))
	try require(
		sink.waitForFeedStarts(1),
		"output sink did not enter its blocking feed"
	)
	try require(pump.enqueueInput([7]) == .accepted, "teardown input rejected")
	try require(
		transport.waitForWriteStarts(1),
		"writer did not enter its blocking send"
	)
	pump.detach()
	try require(
		recorder.waitForEvent(timeout: 0.3) {
			if case .inputDeliveryUncertain(
				recoveryID: _,
				reason: .drainTimedOut
			) = $0 {
				return true
			}
			return false
		},
		"detach deadline did not report uncertain delivery"
	)
	try require(
		!pump.waitUntilStopped(timeout: 0.02),
		"pump stopped while output feed was still in flight"
	)
	try require(
		transport.closeCallCount > 0,
		"teardown did not close the transport to unblock I/O"
	)

	sink.releaseFeeds()
	try require(
		pump.waitUntilStopped(timeout: 0.5),
		"pump did not stop after its feed barrier cleared"
	)
	try require(
		recorder.waitForEvent {
			if case .stopped = $0 {
				return true
			}
			return false
		},
		"timed-out detach did not publish stopped"
	)
	try require(
		sink.feeds == [[1]],
		"pump fed output after teardown began"
	)
	try require(
		stoppedReason(in: recorder.events) == .drainTimedOut,
		"timed-out drain did not preserve its stop reason"
	)
	Thread.sleep(forTimeInterval: 0.02)
	try require(
		sink.feeds == [[1]],
		"output sink was called after stopped completion"
	)
}

private func testStaleRecoveryAcknowledgementCannotResumeInput() throws {
	let first: FakeTransport = .init()
	let second: FakeTransport = .init()
	let third: FakeTransport = .init()
	let connector: FakeConnector = .init(
		actions: [
			.transport(first),
			.transport(second),
			.transport(third),
		]
	)
	let sink: FakeOutputSink = .init()
	let (pump, recorder) = makePump(connector: connector, sink: sink)
	defer {
		pump.detach()
		_ = pump.waitUntilStopped(timeout: 0.5)
	}

	pump.start()
	try waitForConnected(recorder)
	first.failRead(.transport("first injected drop"))
	try require(
		recorder.waitForEventCount(1) {
			if case .reconnected = $0 {
				return true
			}
			return false
		},
		"first reconnect did not complete"
	)
	let firstRecoveryID: UInt64? =
		recoveryEvents(in: recorder.events).last?.recoveryID
	try require(
		firstRecoveryID != nil,
		"first reconnect did not publish a recovery ID"
	)

	second.failRead(.transport("second injected drop"))
	try require(
		recorder.waitForEventCount(2) {
			if case .reconnected = $0 {
				return true
			}
			return false
		},
		"second reconnect did not complete"
	)
	let recoveries: [RecordedRecovery] = recoveryEvents(in: recorder.events)
	let secondRecoveryID: UInt64? = recoveries.last?.recoveryID
	try require(
		secondRecoveryID != nil && secondRecoveryID != firstRecoveryID,
		"successive reconnects did not publish distinct recovery IDs"
	)
	try require(
		!pump.acknowledgeInputAfterReconnect(
			recoveryID: firstRecoveryID ?? 0
		),
		"stale recovery acknowledgement unexpectedly succeeded"
	)
	try require(
		pump.enqueueInput([1]) == .inputPaused,
		"stale recovery acknowledgement resumed input"
	)
	try require(
		pump.acknowledgeInputAfterReconnect(
			recoveryID: secondRecoveryID ?? 0
		),
		"current recovery acknowledgement failed"
	)
	try require(
		pump.enqueueInput([2]) == .accepted,
		"current recovery acknowledgement did not resume input"
	)
	try require(
		third.waitForWrites(1),
		"input resumed by the current recovery ID was not delivered"
	)
	try require(
		third.writes == [.input([2])],
		"replacement transport received stale or paused input"
	)
}

private func testStaleOldReaderTerminalFramesCannotStopNewGeneration() throws {
	let cases: [(name: String, frame: AttachmentServerFrame)] = [
		("exit", .exit(code: 23)),
		(
			"replay gap",
			.replayGap(requested: 0, availableFrom: 9)
		),
	]

	for testCase in cases {
		let first: FakeTransport = .init(
			blockReadReturns: true,
			writeFailure: AttachmentClientError.transport(
				"writer wins before stale \(testCase.name)"
			)
		)
		let second: FakeTransport = .init()
		let connector: FakeConnector = .init(
			actions: [.transport(first), .transport(second)]
		)
		let sink: FakeOutputSink = .init()
		let (pump, recorder) = makePump(connector: connector, sink: sink)
		defer {
			first.releaseReadReturns()
			pump.detach()
			_ = pump.waitUntilStopped(timeout: 0.5)
		}

		first.push(testCase.frame)
		pump.start()
		try waitForConnected(recorder)
		try require(
			first.waitForReadStarts(1),
			"old reader did not claim stale \(testCase.name)"
		)
		try require(
			pump.enqueueInput([1]) == .accepted,
			"generation-changing input was rejected for \(testCase.name)"
		)
		try require(
			recorder.waitForEvent {
				if case .reconnected = $0 {
					return true
				}
				return false
			},
			"writer failure did not reconnect before stale \(testCase.name)"
		)
		let recoveryID: UInt64? =
			recoveryEvents(in: recorder.events).last?.recoveryID
		try require(
			recoveryID != nil,
			"recovery ID missing before stale \(testCase.name)"
		)

		first.releaseReadReturns()
		try require(
			second.waitForReadStarts(1),
			"single reader did not advance past stale \(testCase.name)"
		)
		try require(
			pump.acknowledgeInputAfterReconnect(
				recoveryID: recoveryID ?? 0
			),
			"new generation could not acknowledge after stale \(testCase.name)"
		)
		try require(
			pump.enqueueInput([2]) == .accepted,
			"new generation stopped after stale \(testCase.name)"
		)
		try require(
			second.waitForWrites(1),
			"new generation did not send after stale \(testCase.name)"
		)
		try require(
			second.writes == [.input([2])],
			"new generation received unexpected writes after stale "
				+ testCase.name
		)

		pump.detach()
		try require(
			pump.waitUntilStopped(timeout: 0.5),
			"normal detach failed after stale \(testCase.name)"
		)
		try require(
			recorder.waitForEvent {
				if case .stopped = $0 {
					return true
				}
				return false
			},
			"normal detach was not published after stale \(testCase.name)"
		)
		try require(
			stoppedReason(in: recorder.events) == .detached,
			"stale \(testCase.name) claimed the new generation"
		)
	}
}

private func testRetryBroadcastDoesNotShortenBackoff() throws {
	let first: FakeTransport = .init()
	let second: FakeTransport = .init()
	let connector: FakeConnector = .init(
		actions: [
			.transport(first),
			.failure(AttachmentClientError.transport("retry once")),
			.transport(second),
		]
	)
	let sink: FakeOutputSink = .init()
	let limits: TerminalAttachmentPumpLimits = .init(
		maximumInputBytes: 1_024,
		maximumEvents: 64,
		reconnectTimeout: 0.4,
		detachDrainTimeout: 0.1,
		reconnectRetryDelays: [0.05]
	)
	let (pump, recorder) = makePump(
		connector: connector,
		sink: sink,
		limits: limits
	)
	defer {
		pump.detach()
		_ = pump.waitUntilStopped(timeout: 0.5)
	}

	pump.start()
	try waitForConnected(recorder)
	first.failRead(.transport("start retry backoff"))
	try require(
		connector.waitForConnectionAttempts(2),
		"first reconnect attempt did not occur"
	)

	for index in 0..<12 {
		let size: AttachmentTerminalSize = .init(
			rows: UInt16(20 + index),
			columns: UInt16(80 + index),
			pixelWidth: 800,
			pixelHeight: 400
		)
		try require(
			pump.enqueueResize(size) == .accepted,
			"resize during retry backoff was rejected"
		)
		Thread.sleep(forTimeInterval: 0.002)
	}

	try require(
		connector.waitForConnectionAttempts(3, timeout: 0.3),
		"replacement connection attempt did not occur"
	)
	let attempts: [UInt64] = connector.attemptTimes
	try require(attempts.count >= 3, "connection timestamps are incomplete")
	let retryDelay: TimeInterval = Double(attempts[2] - attempts[1])
		/ 1_000_000_000
	try require(
		retryDelay >= 0.04,
		"resize broadcast shortened 50 ms backoff to \(retryDelay) seconds"
	)
	try require(
		recorder.waitForEvent {
			if case .reconnected = $0 {
				return true
			}
			return false
		},
		"pump did not reconnect after the full retry backoff"
	)
}

private func testHistoricalStateChangesDoNotConsumeRetryBackoff() throws {
	let first: FakeTransport = .init()
	let second: FakeTransport = .init()
	let connector: FakeConnector = .init(
		actions: [
			.transport(first),
			.failure(
				AttachmentClientError.transport(
					"retry after historical state changes"
				)
			),
			.transport(second),
		]
	)
	let sink: FakeOutputSink = .init()
	let limits: TerminalAttachmentPumpLimits = .init(
		maximumInputBytes: 1_024,
		maximumEvents: 64,
		reconnectTimeout: 0.4,
		detachDrainTimeout: 0.1,
		reconnectRetryDelays: [0.05]
	)
	let (pump, recorder) = makePump(
		connector: connector,
		sink: sink,
		limits: limits
	)
	defer {
		pump.detach()
		_ = pump.waitUntilStopped(timeout: 0.5)
	}

	for index in 0..<5_000 {
		let size: AttachmentTerminalSize = .init(
			rows: UInt16(20 + index % 100),
			columns: UInt16(80 + index % 200),
			pixelWidth: 800,
			pixelHeight: 400
		)
		try require(
			pump.enqueueResize(size) == .accepted,
			"historical tail resize \(index) was rejected"
		)
	}

	pump.start()
	try waitForConnected(recorder)
	try require(
		first.waitForWrites(1),
		"coalesced historical resize was not delivered"
	)
	first.failRead(.transport("drop after historical state changes"))
	try require(
		connector.waitForConnectionAttempts(3, timeout: 0.3),
		"replacement attempt did not occur after historical state changes"
	)
	let attempts: [UInt64] = connector.attemptTimes
	try require(attempts.count >= 3, "connection timestamps are incomplete")
	let retryDelay: TimeInterval = Double(attempts[2] - attempts[1])
		/ 1_000_000_000
	try require(
		retryDelay >= 0.04,
		"historical state changes shortened 50 ms backoff to "
			+ "\(retryDelay) seconds"
	)
	try require(
		recorder.waitForEvent {
			if case .reconnected = $0 {
				return true
			}
			return false
		},
		"pump did not reconnect after preserving historical-signal backoff"
	)
}

private func testInstallEventPrecedesImmediateTransportFailure() throws {
	let initial: FakeTransport = .init()
	initial.failRead(.protocolViolation("instant initial failure"))
	let initialConnector: FakeConnector = .init(actions: [.transport(initial)])
	let initialSink: FakeOutputSink = .init()
	let (initialPump, initialRecorder) = makePump(
		connector: initialConnector,
		sink: initialSink
	)

	initialPump.start()
	try require(
		initialPump.waitUntilStopped(timeout: 0.5),
		"initial immediate failure did not stop the pump"
	)
	try require(
		initialRecorder.waitForEvent {
			if case .stopped = $0 {
				return true
			}
			return false
		},
		"initial immediate failure did not publish stopped"
	)
	let initialEvents: [TerminalAttachmentPumpEvent] = initialRecorder.events
	let connectedIndex: Int? = initialEvents.firstIndex {
		if case .connected = $0 {
			return true
		}
		return false
	}
	let initialStopIndex: Int? = initialEvents.firstIndex {
		if case .stopped = $0 {
			return true
		}
		return false
	}
	try require(
		connectedIndex != nil
			&& initialStopIndex != nil
			&& (connectedIndex ?? Int.max) < (initialStopIndex ?? Int.min),
		"connected was not published before the installed transport failed"
	)

	let first: FakeTransport = .init()
	let replacement: FakeTransport = .init()
	replacement.failRead(.protocolViolation("instant replacement failure"))
	let reconnectConnector: FakeConnector = .init(
		actions: [.transport(first), .transport(replacement)]
	)
	let reconnectSink: FakeOutputSink = .init()
	let (reconnectPump, reconnectRecorder) = makePump(
		connector: reconnectConnector,
		sink: reconnectSink
	)

	reconnectPump.start()
	try waitForConnected(reconnectRecorder)
	first.failRead(.transport("replace generation"))
	try require(
		reconnectPump.waitUntilStopped(timeout: 0.5),
		"replacement immediate failure did not stop the pump"
	)
	try require(
		reconnectRecorder.waitForEvent {
			if case .stopped = $0 {
				return true
			}
			return false
		},
		"replacement immediate failure did not publish stopped"
	)
	let reconnectEventsSnapshot: [TerminalAttachmentPumpEvent] =
		reconnectRecorder.events
	let reconnectedIndex: Int? = reconnectEventsSnapshot.firstIndex {
		if case .reconnected = $0 {
			return true
		}
		return false
	}
	let reconnectStopIndex: Int? = reconnectEventsSnapshot.firstIndex {
		if case .stopped = $0 {
			return true
		}
		return false
	}
	try require(
		reconnectedIndex != nil
			&& reconnectStopIndex != nil
			&& (reconnectedIndex ?? Int.max) < (reconnectStopIndex ?? Int.min),
		"reconnected was not published before the replacement transport failed"
	)
}

private func testConcurrentReadWriteFailureEmitsOneUncertainty() throws {
	let first: FakeTransport = .init(blockWrites: true)
	let second: FakeTransport = .init()
	let connector: FakeConnector = .init(
		actions: [.transport(first), .transport(second)]
	)
	let sink: FakeOutputSink = .init()
	let (pump, recorder) = makePump(connector: connector, sink: sink)
	defer {
		first.releaseWrites()
		pump.detach()
		_ = pump.waitUntilStopped(timeout: 0.5)
	}

	pump.start()
	try waitForConnected(recorder)
	try require(
		pump.enqueueInput([1]) == .accepted,
		"concurrent-failure input was rejected"
	)
	try require(
		first.waitForWriteStarts(1),
		"writer did not enter its failing transport"
	)
	first.failRead(.transport("concurrent read failure"))
	try require(
		recorder.waitForEvent {
			if case .reconnected = $0 {
				return true
			}
			return false
		},
		"pump did not recover from concurrent read/write failure"
	)
	Thread.sleep(forTimeInterval: 0.02)
	let connectionLosses: [RecordedUncertainty] =
		uncertaintyEvents(in: recorder.events).filter {
			if case .connectionLost = $0.reason {
				return true
			}
			return false
		}
	try require(
		connectionLosses.count == 1,
		"concurrent read/write failure emitted "
			+ "\(connectionLosses.count) connection-loss uncertainties"
	)
	try require(
		connectionLosses.first?.recoveryID
			== recoveryEvents(in: recorder.events).last?.recoveryID,
		"failure uncertainty and reconnect used different recovery IDs"
	)
}

private func testCompletedDrainDoesNotReportLateTimeout() throws {
	let transport: FakeTransport = .init(blockWrites: true)
	let connector: FakeConnector = .init(actions: [.transport(transport)])
	let sink: FakeOutputSink = .init()
	let limits: TerminalAttachmentPumpLimits = .init(
		maximumInputBytes: 1_024,
		maximumEvents: 64,
		reconnectTimeout: 0.2,
		detachDrainTimeout: 0.06,
		reconnectRetryDelays: [0.002]
	)
	let (pump, recorder) = makePump(
		connector: connector,
		sink: sink,
		limits: limits
	)
	defer { transport.releaseWrites() }

	pump.start()
	try waitForConnected(recorder)
	try require(
		pump.enqueueInput([8]) == .accepted,
		"drain-boundary input was rejected"
	)
	try require(
		transport.waitForWriteStarts(1),
		"drain-boundary input did not enter writer"
	)
	pump.detach()
	Thread.sleep(forTimeInterval: 0.015)
	transport.releaseWrites()
	try require(
		pump.waitUntilStopped(timeout: 0.5),
		"completed drain did not stop"
	)
	try require(
		recorder.waitForEvent {
			if case .stopped = $0 {
				return true
			}
			return false
		},
		"completed drain did not publish stopped"
	)
	Thread.sleep(forTimeInterval: 0.07)
	try require(
		stoppedReason(in: recorder.events) == .detached,
		"completed drain was misclassified as timed out"
	)
	let drainTimeouts: [RecordedUncertainty] =
		uncertaintyEvents(in: recorder.events).filter {
			$0.reason == .drainTimedOut
		}
	try require(
		drainTimeouts.isEmpty,
		"expired drain timer reported uncertainty after the queue drained"
	)
}

private func testReconnectDeadlineClaimsWhileFeedRemainsBlocked() throws {
	let transport: FakeTransport = .init(
		writeFailure: AttachmentClientError.transport(
			"trigger reconnect behind blocked feed"
		)
	)
	let connector: FakeConnector = .init(actions: [.transport(transport)])
	let sink: FakeOutputSink = .init(blockFeeds: true)
	let limits: TerminalAttachmentPumpLimits = .init(
		maximumInputBytes: 1_024,
		maximumEvents: 64,
		reconnectTimeout: 0.04,
		detachDrainTimeout: 0.1,
		reconnectRetryDelays: [0.002]
	)
	let (pump, recorder) = makePump(
		connector: connector,
		sink: sink,
		limits: limits
	)
	defer { sink.releaseFeeds() }

	pump.start()
	try waitForConnected(recorder)
	transport.push(.output(offset: 0, bytes: [1]))
	try require(
		sink.waitForFeedStarts(1),
		"output sink did not enter its blocking feed"
	)
	try require(
		pump.enqueueInput([1]) == .accepted,
		"reconnect-triggering input was rejected"
	)

	Thread.sleep(forTimeInterval: 0.07)
	try require(
		pump.enqueueInput([2]) == .stopped,
		"reconnect deadline did not claim terminal stop while feed was blocked"
	)
	try require(
		!pump.waitUntilStopped(timeout: 0.02),
		"pump completed stop before the blocked feed quiesced"
	)

	sink.releaseFeeds()
	try require(
		pump.waitUntilStopped(timeout: 0.5),
		"pump did not complete stop after the feed barrier cleared"
	)
	try require(
		recorder.waitForEvent {
			if case .stopped = $0 {
				return true
			}
			return false
		},
		"feed-deadline stop was not published"
	)
	guard case .reconnectTimedOut(let message)? =
		stoppedReason(in: recorder.events)
	else {
		throw TestFailure.assertion(
			"blocked feed did not stop as reconnectTimedOut"
		)
	}
	try require(
		message.contains("feed"),
		"reconnect timeout did not identify the blocked feed barrier"
	)
}

private func testConnectorAttemptsShareAbsoluteReconnectDeadline() throws {
	let first: FakeTransport = .init()
	let connector: FakeConnector = .init(
		actions: [
			.transport(first),
			.delayedFailure(
				0.015,
				AttachmentClientError.transport(
					"first delayed connect failure"
				)
			),
			.delayedFailure(
				0.015,
				AttachmentClientError.transport(
					"second delayed connect failure"
				)
			),
			.deadlineFailure(
				AttachmentClientError.transport(
					"deadline-bound connect failure"
				)
			),
		]
	)
	let sink: FakeOutputSink = .init()
	let reconnectTimeout: TimeInterval = 0.08
	let limits: TerminalAttachmentPumpLimits = .init(
		maximumInputBytes: 1_024,
		maximumEvents: 64,
		reconnectTimeout: reconnectTimeout,
		detachDrainTimeout: 0.1,
		reconnectRetryDelays: [0.005]
	)
	let (pump, recorder) = makePump(
		connector: connector,
		sink: sink,
		limits: limits
	)

	pump.start()
	try waitForConnected(recorder)
	let started: UInt64 = DispatchTime.now().uptimeNanoseconds
	first.failRead(.transport("begin absolute-deadline reconnect"))
	try require(
		pump.waitUntilStopped(timeout: 0.4),
		"absolute reconnect deadline did not stop the pump"
	)
	let elapsed: TimeInterval = Double(
		DispatchTime.now().uptimeNanoseconds - started
	) / 1_000_000_000
	try require(
		recorder.waitForEvent {
			if case .stopped = $0 {
				return true
			}
			return false
		},
		"absolute reconnect deadline did not publish stopped"
	)

	let reconnectDeadlines: [UInt64] =
		Array(connector.deadlineUptimes.dropFirst())
	try require(
		reconnectDeadlines.count == 3,
		"connector did not execute all deadline-bound attempts"
	)
	guard let sharedDeadline = reconnectDeadlines.first else {
		throw TestFailure.assertion("reconnect deadline was not recorded")
	}
	try require(
		reconnectDeadlines.allSatisfy { $0 == sharedDeadline },
		"connector attempts received different absolute reconnect deadlines"
	)
	try require(
		elapsed >= reconnectTimeout - 0.015,
		"reconnect stopped before its total retry window"
	)
	try require(
		elapsed < reconnectTimeout + 0.05,
		"reconnect attempts reset the total timeout window to \(elapsed) seconds"
	)
	guard case .reconnectTimedOut? = stoppedReason(in: recorder.events) else {
		throw TestFailure.assertion(
			"deadline-bound connector did not stop as reconnectTimedOut"
		)
	}
}

private func testUnknownConnectorErrorDoesNotExecuteDescription() throws {
	let first: FakeTransport = .init()
	let failure: BlockingDescriptionError = .init(
		"connector description must remain unexecuted"
	)
	let connector: FakeConnector = .init(
		actions: [
			.transport(first),
			.deadlineFailure(failure),
		]
	)
	let sink: FakeOutputSink = .init()
	let reconnectTimeout: TimeInterval = 0.05
	let limits: TerminalAttachmentPumpLimits = .init(
		maximumInputBytes: 1_024,
		maximumEvents: 64,
		reconnectTimeout: reconnectTimeout,
		detachDrainTimeout: 0.1,
		reconnectRetryDelays: [0.002]
	)
	let (pump, recorder) = makePump(
		connector: connector,
		sink: sink,
		limits: limits
	)
	defer { failure.releaseDescription() }

	pump.start()
	try waitForConnected(recorder)
	let started: UInt64 = DispatchTime.now().uptimeNanoseconds
	first.failRead(.transport("enter unknown connector failure"))
	try require(
		pump.waitUntilStopped(timeout: 0.3),
		"unknown connector error blocked pump termination"
	)
	let elapsed: TimeInterval = Double(
		DispatchTime.now().uptimeNanoseconds - started
	) / 1_000_000_000
	try require(
		recorder.waitForEvent {
			if case .stopped = $0 {
				return true
			}
			return false
		},
		"unknown connector error did not publish stopped"
	)
	try require(
		!failure.wasDescriptionRequested,
		"connector executed unknown error CustomStringConvertible.description"
	)
	guard case .reconnectTimedOut(let message)? =
		stoppedReason(in: recorder.events)
	else {
		throw TestFailure.assertion(
			"deadline-bound unknown connector error did not time out"
		)
	}
	try require(
		message.contains("BlockingDescriptionError")
			&& !message.contains("connector description must"),
		"unknown connector error did not use its static type name"
	)
	try require(
		elapsed >= reconnectTimeout - 0.015
			&& elapsed < reconnectTimeout + 0.06,
		"unknown connector error violated total deadline: \(elapsed) seconds"
	)
}

private func testFailingWriteAtDrainDeadlineIsNotDetached() throws {
	let failure: BlockingDescriptionError = .init(
		"controlled write failure at drain deadline"
	)
	let transport: FakeTransport = .init(
		blockWrites: true,
		writeFailure: failure
	)
	let connector: FakeConnector = .init(actions: [.transport(transport)])
	let sink: FakeOutputSink = .init()
	let limits: TerminalAttachmentPumpLimits = .init(
		maximumInputBytes: 1_024,
		maximumEvents: 64,
		reconnectTimeout: 0.2,
		detachDrainTimeout: 0.04,
		reconnectRetryDelays: [0.002]
	)
	let (pump, recorder) = makePump(
		connector: connector,
		sink: sink,
		limits: limits
	)
	defer {
		transport.releaseWrites()
		failure.releaseDescription()
	}

	pump.start()
	try waitForConnected(recorder)
	try require(
		pump.enqueueInput([7]) == .accepted,
		"drain-race input was rejected"
	)
	try require(
		transport.waitForWriteStarts(1),
		"drain-race send did not enter the transport"
	)
	pump.detach()
	let failureStarted: UInt64 = DispatchTime.now().uptimeNanoseconds
	transport.releaseWrites()
	_ = failure.waitForDescription(timeout: 0.02)
	let callbackResult: EnqueueResultBox = .init()
	let callbackSize: AttachmentTerminalSize = .init(
		rows: 24,
		columns: 80,
		pixelWidth: 800,
		pixelHeight: 480
	)
	DispatchQueue.global(qos: .userInitiated).async {
		callbackResult.record(pump.enqueueResize(callbackSize))
	}
	let callbackCompletedWithoutUnlock: Bool = callbackResult.wait(timeout: 0.03)
	let descriptionWasRequested: Bool = failure.wasDescriptionRequested
	failure.releaseDescription()
	if !callbackCompletedWithoutUnlock {
		_ = callbackResult.wait(timeout: 0.5)
	}
	try require(
		callbackCompletedWithoutUnlock,
		"enqueue callback was blocked by transport error formatting"
	)
	try require(
		callbackResult.result == .stopped,
		"enqueue callback did not observe the claimed transport stop"
	)
	try require(
		!descriptionWasRequested,
		"unknown transport error executed CustomStringConvertible.description"
	)
	try require(
		pump.waitUntilStopped(timeout: 0.1),
		"drain-race failure did not rapidly stop the pump"
	)
	let failureElapsed: TimeInterval = Double(
		DispatchTime.now().uptimeNanoseconds - failureStarted
	) / 1_000_000_000
	try require(
		failureElapsed < 0.09,
		"transport failure claim took \(failureElapsed) seconds"
	)
	try require(
		recorder.waitForEvent {
			if case .stopped = $0 {
				return true
			}
			return false
		},
		"drain-race failure did not publish stopped"
	)
	guard case .transportFailed(let message)? =
		stoppedReason(in: recorder.events)
	else {
		throw TestFailure.assertion(
			"failing drain write was incorrectly classified as "
				+ "\(String(describing: stoppedReason(in: recorder.events)))"
		)
	}
	try require(
		message.contains("BlockingDescriptionError")
			&& !message.contains("controlled write failure"),
		"unknown transport failure did not use its static type name"
	)
	let connectionLosses: [RecordedUncertainty] =
		uncertaintyEvents(in: recorder.events).filter {
			if case .connectionLost = $0.reason {
				return true
			}
			return false
		}
	try require(
		connectionLosses.count == 1,
		"failing drain write did not publish exactly one delivery uncertainty"
	)
	try require(
		uncertaintyEvents(in: recorder.events).allSatisfy {
			$0.reason != .drainTimedOut
		},
		"failing drain write was misclassified as drain timeout"
	)
}

private func testOutputSinkFailureClaimsBeforeReconnectInstall() throws {
	let first: FakeTransport = .init(
		writeFailure: AttachmentClientError.transport(
			"drop while output sink is blocked"
		)
	)
	let replacement: FakeTransport = .init()
	let connector: FakeConnector = .init(
		actions: [.transport(first), .transport(replacement)]
	)
	let sink: FakeOutputSink = .init(
		blockFeeds: true,
		feedFailure: AttachmentClientError.transport("fatal output sink")
	)
	let limits: TerminalAttachmentPumpLimits = .init(
		maximumInputBytes: 1_024,
		maximumEvents: 64,
		reconnectTimeout: 0.2,
		detachDrainTimeout: 0.1,
		reconnectRetryDelays: [0.002]
	)
	let (pump, recorder) = makePump(
		connector: connector,
		sink: sink,
		limits: limits
	)
	defer { sink.releaseFeeds() }

	pump.start()
	try waitForConnected(recorder)
	first.push(.output(offset: 0, bytes: [1]))
	try require(
		sink.waitForFeedStarts(1),
		"fatal sink did not enter its blocking feed"
	)
	try require(
		pump.enqueueInput([1]) == .accepted,
		"sink-race reconnect trigger was rejected"
	)
	try require(
		recorder.waitForEvent {
			if case .inputDeliveryUncertain(
				recoveryID: _,
				reason: .connectionLost
			) = $0 {
				return true
			}
			return false
		},
		"writer failure did not enter reconnect before sink release"
	)
	try require(
		!pump.waitUntilStopped(timeout: 0.02),
		"pump stopped before the blocked sink completed"
	)
	try require(
		connector.offsets.count == 1,
		"replacement connector ran before the feed barrier"
	)

	sink.releaseFeeds()
	try require(
		pump.waitUntilStopped(timeout: 0.5),
		"fatal sink did not complete teardown"
	)
	try require(
		recorder.waitForEvent {
			if case .stopped = $0 {
				return true
			}
			return false
		},
		"fatal sink stop was not published"
	)
	guard case .outputSinkFailed(let message)? =
		stoppedReason(in: recorder.events)
	else {
		throw TestFailure.assertion(
			"fatal sink did not atomically claim outputSinkFailed"
		)
	}
	try require(
		message.contains("fatal output sink"),
		"fatal sink stop did not preserve its error"
	)
	try require(
		connector.offsets.count == 1,
		"replacement connector ran after fatal sink failure"
	)
	try require(
		!recorder.events.contains {
			if case .reconnected = $0 {
				return true
			}
			return false
		},
		"replacement transport installed after fatal sink failure"
	)
	try require(
		sink.startedFeedCount == 1 && sink.feeds.isEmpty,
		"fatal sink received feed after teardown or committed failed output"
	)
}

private func testAttachmentClientHandshakeUsesAbsoluteDeadline() throws {
	let socketPath: String =
		"/tmp/teaser-deadline-\(UUID().uuidString.prefix(12)).sock"
	_ = socketPath.withCString { Darwin.unlink($0) }
	let listener: Int32 = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
	try require(listener >= 0, "could not create Unix listener: errno \(errno)")
	defer {
		Darwin.close(listener)
		_ = socketPath.withCString { Darwin.unlink($0) }
	}

	let pathBytes: [UInt8] = Array(socketPath.utf8)
	var address: sockaddr_un = .init()
	let pathCapacity: Int = MemoryLayout.size(ofValue: address.sun_path)
	try require(
		pathBytes.count < pathCapacity,
		"test Unix socket path exceeded sockaddr_un capacity"
	)
	address.sun_family = sa_family_t(AF_UNIX)
	let addressHeaderBytes: Int =
		MemoryLayout.size(ofValue: address.sun_len)
		+ MemoryLayout.size(ofValue: address.sun_family)
	let addressBytes: Int = addressHeaderBytes + pathBytes.count + 1
	guard let addressLength = UInt8(exactly: addressBytes) else {
		throw TestFailure.assertion("test Unix socket address was too long")
	}
	address.sun_len = addressLength
	withUnsafeMutableBytes(of: &address.sun_path) { destination in
		for index: Int in destination.indices {
			destination[index] = 0
		}
		pathBytes.withUnsafeBytes { source in
			destination.copyBytes(from: source)
		}
	}
	let bindStatus: Int32 = withUnsafePointer(to: &address) { pointer in
		pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
			Darwin.bind(
				listener,
				$0,
				socklen_t(addressLength)
			)
		}
	}
	try require(bindStatus == 0, "could not bind Unix listener: errno \(errno)")
	try require(
		Darwin.listen(listener, 1) == 0,
		"could not listen on Unix socket: errno \(errno)"
	)

	let surfaceID: UInt64 = 42
	let sessionID: String = UUID().uuidString
	let response: [UInt8] = Array(
		(
			"{\"version\":1,\"request_id\":42,\"status\":\"error\","
				+ "\"error\":{\"code\":\"expected\",\"message\":\"complete\"}}\n"
		).utf8
	)
	let serverState: TrickleServerState = .init()
	let serverGroup: DispatchGroup = .init()
	let serverReady: DispatchSemaphore = .init(value: 0)
	serverGroup.enter()
	DispatchQueue.global(qos: .userInitiated).async {
		defer { serverGroup.leave() }
		serverReady.signal()
		let client: Int32 = Darwin.accept(listener, nil, nil)
		guard client >= 0 else { return }
		serverState.recordAcceptedConnection()
		defer {
			_ = Darwin.shutdown(client, SHUT_RDWR)
			Darwin.close(client)
		}

		var noSignal: Int32 = 1
		_ = withUnsafePointer(to: &noSignal) { pointer in
			Darwin.setsockopt(
				client,
				SOL_SOCKET,
				SO_NOSIGPIPE,
				pointer,
				socklen_t(MemoryLayout<Int32>.size)
			)
		}

		var requestByte: UInt8 = 0
		while true {
			let readCount: Int = withUnsafeMutableBytes(of: &requestByte) {
				buffer in
				guard let baseAddress = buffer.baseAddress else { return 0 }
				return Darwin.read(client, baseAddress, 1)
			}
			guard readCount == 1 else { return }
			if requestByte == 0x0A {
				break
			}
		}

		for responseByte in response {
			var byte: UInt8 = responseByte
			let written: Int = withUnsafeBytes(of: &byte) { buffer in
				guard let baseAddress = buffer.baseAddress else { return 0 }
				return Darwin.write(client, baseAddress, 1)
			}
			guard written == 1 else { return }
			serverState.recordSentByte()
			Thread.sleep(forTimeInterval: 0.01)
		}
	}
	try require(
		serverReady.wait(timeout: .now() + 0.5) == .success,
		"trickle server did not reach accept"
	)

	let budget: TimeInterval = 0.12
	let deadline: AttachmentConnectionDeadline = .init(timeout: budget)
	let started: UInt64 = DispatchTime.now().uptimeNanoseconds
	var connectionError: Error?
	var unexpectedlyConnected: Bool = false
	do {
		let client: AttachmentClient = try AttachmentClient.connect(
			socketPath: socketPath,
			sessionID: sessionID,
			surfaceID: surfaceID,
			nextOffset: 0,
			timeoutSeconds: 1,
			deadline: deadline,
			frameReadTimeoutSeconds: nil
		)
		unexpectedlyConnected = true
		client.close()
	} catch {
		connectionError = error
	}
	let elapsed: TimeInterval = Double(
		DispatchTime.now().uptimeNanoseconds - started
	) / 1_000_000_000
	let serverFinished: Bool =
		serverGroup.wait(timeout: .now() + 0.5) == .success

	try require(!unexpectedlyConnected, "trickle handshake unexpectedly succeeded")
	guard case .transport(let message)? =
		connectionError as? AttachmentClientError
	else {
		throw TestFailure.assertion(
			"trickle handshake did not fail as transport deadline: "
				+ "\(String(describing: connectionError))"
		)
	}
	try require(
		message.contains("deadline"),
		"trickle handshake failure did not report its deadline"
	)
	try require(
		elapsed >= budget - 0.035,
		"trickle handshake failed before its original budget"
	)
	try require(
		elapsed < budget + 0.1,
		"trickle progress reset the original budget to \(elapsed) seconds"
	)
	try require(serverFinished, "trickle server thread did not terminate")
	let serverSnapshot = serverState.snapshot
	try require(
		serverSnapshot.accepted && serverSnapshot.sentBytes >= 2,
		"server did not provide incremental handshake progress"
	)
}

private typealias TestCase = (name: String, body: () throws -> Void)

private let tests: [TestCase] = [
	("enqueue remains nonblocking", testEnqueueDoesNotBlockOnSlowWriter),
	("detach before start is terminal", testDetachBeforeStartStopsWithoutWorkers),
	("FIFO and tail resize coalescing", testFifoAndTailResizeCoalescing),
	("byte overflow is atomic", testByteOverflowIsAtomic),
	("event overflow is atomic", testEventOverflowIsAtomic),
	("output order precedes exit", testOutputOrderAndExitAfterFinalFeed),
	(
		"reconnect uses committed offset and pauses input",
		testReconnectUsesCommittedOffsetAndPausesInput
	),
	("reconnect timeout stops pump", testReconnectTimeoutStopsPump),
	("replay gap is fatal", testReplayGapIsFatal),
	("detach drains queued input", testDetachDrainsQueuedInput),
	(
		"teardown waits for feed and unblocks I/O",
		testTeardownWaitsForBlockedFeedAndUnblocksIO
	),
	(
		"stale recovery acknowledgement stays paused",
		testStaleRecoveryAcknowledgementCannotResumeInput
	),
	(
		"stale reader terminal frames cannot stop new generation",
		testStaleOldReaderTerminalFramesCannotStopNewGeneration
	),
	(
		"retry broadcasts preserve minimum backoff",
		testRetryBroadcastDoesNotShortenBackoff
	),
	(
		"historical state changes preserve retry backoff",
		testHistoricalStateChangesDoNotConsumeRetryBackoff
	),
	(
		"install event precedes immediate failure",
		testInstallEventPrecedesImmediateTransportFailure
	),
	(
		"concurrent failures emit one uncertainty",
		testConcurrentReadWriteFailureEmitsOneUncertainty
	),
	(
		"completed drain ignores expired deadline",
		testCompletedDrainDoesNotReportLateTimeout
	),
	(
		"reconnect deadline waits for feed barrier",
		testReconnectDeadlineClaimsWhileFeedRemainsBlocked
	),
	(
		"connector attempts share absolute deadline",
		testConnectorAttemptsShareAbsoluteReconnectDeadline
	),
	(
		"unknown connector error skips description",
		testUnknownConnectorErrorDoesNotExecuteDescription
	),
	(
		"failing drain write is never detached",
		testFailingWriteAtDrainDeadlineIsNotDetached
	),
	(
		"fatal output sink prevents reconnect install",
		testOutputSinkFailureClaimsBeforeReconnectInstall
	),
	(
		"attachment handshake shares absolute deadline",
		testAttachmentClientHandshakeUsesAbsoluteDeadline
	),
]

private var failures: [String] = []
for test in tests {
	do {
		try test.body()
		print("PASS \(test.name)")
	} catch {
		let failure: String = "FAIL \(test.name): \(error)"
		failures.append(failure)
		fputs("\(failure)\n", stderr)
	}
}

if !failures.isEmpty {
	fputs(
		"\(failures.count) of \(tests.count) terminal attachment pump tests failed\n",
		stderr
	)
	exit(EXIT_FAILURE)
}

print("PASS all \(tests.count) terminal attachment pump tests")
