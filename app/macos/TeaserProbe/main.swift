import AppKit
import CoreFoundation
import Darwin
import Foundation
import GhosttyKit
import IOSurface
import QuartzCore

private let probePrefix: String = "[TeaserProbe]"

private struct ProbeFailure: Error, CustomStringConvertible {
	let description: String
}

private func resizeMatchesSurface(
	_ event: TerminalResizeEvent?,
	size: ghostty_surface_size_s
) -> Bool {
	guard let event else { return false }
	guard event.columns == size.columns, event.rows == size.rows else {
		return false
	}

	let minimumWidth: UInt32 = UInt32(size.columns) * size.cell_width_px
	let minimumHeight: UInt32 = UInt32(size.rows) * size.cell_height_px
	let maximumWidth: UInt32 = minimumWidth + size.cell_width_px
	let maximumHeight: UInt32 = minimumHeight + size.cell_height_px

	return event.widthPixels >= minimumWidth
		&& event.widthPixels < maximumWidth
		&& event.heightPixels >= minimumHeight
		&& event.heightPixels < maximumHeight
		&& event.widthPixels <= size.width_px
		&& event.heightPixels <= size.height_px
}

private struct ProbeBootstrap: Decodable, Sendable {
	let socketPath: String
	let sessionID: String
	let processID: UInt32

	enum CodingKeys: String, CodingKey {
		case socketPath = "socket_path"
		case sessionID = "session_id"
		case processID = "process_id"
	}
}

private final class FaultInjectingTransport:
	TerminalAttachmentTransport, @unchecked Sendable
{
	private let base: AttachmentClient
	private let lock: NSLock = .init()
	private var successfulInputBytes: [UInt8] = []

	init(base: AttachmentClient) {
		self.base = base
	}

	var nextUnreadOffset: UInt64 {
		base.nextUnreadOffset
	}

	var upgrade: AttachmentUpgrade {
		base.upgrade
	}

	func sendInput(_ bytes: [UInt8]) throws {
		try base.sendInput(bytes)
		lock.lock()
		successfulInputBytes.append(contentsOf: bytes)
		lock.unlock()
	}

	func sendResize(_ size: AttachmentTerminalSize) throws {
		try base.sendResize(size)
	}

	func readFrame() throws -> AttachmentServerFrame {
		try base.readFrame()
	}

	func close() {
		base.close()
	}

	func injectDrop() {
		DispatchQueue.global(qos: .utility).async { [base] in
			base.close()
		}
	}

	func successfulInputContains(_ bytes: [UInt8]) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		return Data(successfulInputBytes).range(of: Data(bytes)) != nil
	}
}

private final class ProbeAttachmentConnector:
	TerminalAttachmentConnecting, @unchecked Sendable
{
	private let socketPath: String
	private let sessionID: String
	private let surfaceID: UInt64
	private let lock: NSLock = .init()
	private var connectionOffsets: [UInt64] = []
	private var transports: [FaultInjectingTransport] = []
	private var reconnectNotBeforeUptimeNanoseconds: UInt64?

	init(socketPath: String, sessionID: String, surfaceID: UInt64) {
		self.socketPath = socketPath
		self.sessionID = sessionID
		self.surfaceID = surfaceID
	}

	func connect(
		nextOffset: UInt64,
		deadline: AttachmentConnectionDeadline
	) throws -> any TerminalAttachmentTransport {
		lock.lock()
		let reconnectNotBefore: UInt64? =
			transports.isEmpty ? nil : reconnectNotBeforeUptimeNanoseconds
		lock.unlock()
		if
			let reconnectNotBefore,
			DispatchTime.now().uptimeNanoseconds < reconnectNotBefore
		{
			throw AttachmentClientError.transport(
				"native probe is holding reconnect until offline output is retained"
			)
		}
		let remaining: TimeInterval = deadline.remainingTimeInterval
		guard remaining > 0 else {
			throw AttachmentClientError.transport("connection deadline expired")
		}
		let client: AttachmentClient = try .connect(
			socketPath: socketPath,
			sessionID: sessionID,
			surfaceID: surfaceID,
			nextOffset: nextOffset,
			deadline: deadline,
			frameReadTimeoutSeconds: nil
		)
		lock.lock()
		let transport: FaultInjectingTransport = .init(
			base: client
		)
		connectionOffsets.append(nextOffset)
		transports.append(transport)
		lock.unlock()
		return transport
	}

	func holdReconnect(for interval: TimeInterval) {
		precondition(interval.isFinite && interval > 0)
		let delayNanoseconds: UInt64 = UInt64(
			(interval * 1_000_000_000).rounded(.up)
		)
		lock.lock()
		reconnectNotBeforeUptimeNanoseconds =
			DispatchTime.now().uptimeNanoseconds + delayNanoseconds
		lock.unlock()
	}

	func offsets() -> [UInt64] {
		lock.lock()
		defer { lock.unlock() }
		return connectionOffsets
	}

	func transport(generation: Int) -> FaultInjectingTransport? {
		lock.lock()
		defer { lock.unlock() }
		guard generation > 0, generation <= transports.count else {
			return nil
		}
		return transports[generation - 1]
	}

}

private final class ProbeSurfaceOutputSink: TerminalOutputSink, @unchecked Sendable {
	private let surface: ghostty_surface_t
	private let lock: NSLock = .init()
	private var outputBytes: [UInt8] = []

	init(surface: ghostty_surface_t) {
		self.surface = surface
	}

	func feed(_ bytes: [UInt8]) throws {
		bytes.withUnsafeBufferPointer { buffer in
			ghostty_surface_feed_output(
				surface,
				buffer.baseAddress,
				buffer.count
			)
		}
		lock.lock()
		outputBytes.append(contentsOf: bytes)
		lock.unlock()
	}

	func contains(_ marker: String) -> Bool {
		let markerBytes: [UInt8] = Array(marker.utf8)
		lock.lock()
		defer { lock.unlock() }
		return Data(outputBytes).range(of: Data(markerBytes)) != nil
	}

	func byteCount() -> UInt64 {
		lock.lock()
		defer { lock.unlock() }
		return UInt64(outputBytes.count)
	}

	func occurrenceCount(of marker: String) -> Int {
		lock.lock()
		defer { lock.unlock() }
		return String(decoding: outputBytes, as: UTF8.self)
			.components(separatedBy: marker)
			.count - 1
	}
}

private final class ProbePumpEventRecorder: @unchecked Sendable {
	private let lock: NSLock = .init()
	private var events: [TerminalAttachmentPumpEvent] = []

	func record(_ event: TerminalAttachmentPumpEvent) {
		lock.lock()
		events.append(event)
		lock.unlock()
	}

	func sawInitialConnection() -> Bool {
		snapshot().contains { event in
			if case .connected(offset: 0) = event {
				return true
			}
			return false
		}
	}

	func pausedRecoveryID(offset: UInt64) -> UInt64? {
		snapshot().reversed().compactMap { event in
			if
				case .reconnected(
					recoveryID: let recoveryID,
					offset: let eventOffset,
					inputPaused: true
				) = event
			{
				return eventOffset == offset ? recoveryID : nil
			}
			return nil
		}.first
	}

	func sawConnectionUncertainty() -> Bool {
		snapshot().contains { event in
			if
				case .inputDeliveryUncertain(
					recoveryID: _,
					reason: .connectionLost(_)
				) = event
			{
				return true
			}
			return false
		}
	}

	func sawCleanExit() -> Bool {
		snapshot().contains { event in
			if
				case .stopped(
					reason: .processExited(0),
					resumeOffset: _
				) = event
			{
				return true
			}
			return false
		}
	}

	private func snapshot() -> [TerminalAttachmentPumpEvent] {
		lock.lock()
		defer { lock.unlock() }
		return events
	}
}

@MainActor
private final class ProbeDaemon {
	let bootstrap: ProbeBootstrap

	private let process: Process
	private let runtimeDirectory: URL
	private var stopped: Bool = false

	private init(
		process: Process,
		runtimeDirectory: URL,
		bootstrap: ProbeBootstrap
	) {
		self.process = process
		self.runtimeDirectory = runtimeDirectory
		self.bootstrap = bootstrap
	}

	static func start() throws -> ProbeDaemon {
		guard
			let binaryPath = ProcessInfo.processInfo.environment["TEASERD_BIN"],
			!binaryPath.isEmpty
		else {
			throw ProbeFailure(
				description: "TEASERD_BIN must name the teaserd probe binary"
			)
		}
		guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
			throw ProbeFailure(
				description: "TEASERD_BIN is not executable: \(binaryPath)"
			)
		}

		let runtimeToken: String = UUID().uuidString.lowercased()
		let runtimeDirectory: URL = URL(
			fileURLWithPath: "/tmp",
			isDirectory: true
			)
			.appendingPathComponent(
				"teaser-m010-\(runtimeToken)",
				isDirectory: true
			)
		try FileManager.default.createDirectory(
			at: runtimeDirectory,
			withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700]
		)
		let process: Process = .init()
		let stdout: Pipe = .init()
		process.executableURL = URL(fileURLWithPath: binaryPath)
		process.arguments = [
			"--runtime-dir",
			runtimeDirectory.path,
			"--probe-session",
		]
		process.standardInput = FileHandle.nullDevice
		process.standardOutput = stdout
		process.standardError = FileHandle.standardError

		do {
			try process.run()
			let line: [UInt8] = try readBoundedLine(
				from: stdout.fileHandleForReading,
				maximumBytes: 16 * 1_024,
				timeout: 5
			)
			let bootstrap: ProbeBootstrap
			do {
				bootstrap = try JSONDecoder().decode(
					ProbeBootstrap.self,
					from: Data(line)
				)
			} catch {
				throw ProbeFailure(
					description: "invalid teaserd probe bootstrap: \(error)"
				)
			}
			try require(
				UUID(uuidString: bootstrap.sessionID) != nil,
				"probe bootstrap session_id is not a UUID"
			)
			try require(
				!bootstrap.socketPath.isEmpty,
				"probe bootstrap socket_path is empty"
			)
			try require(
				bootstrap.processID > 0,
				"probe bootstrap process_id is zero"
			)
			return ProbeDaemon(
				process: process,
				runtimeDirectory: runtimeDirectory,
				bootstrap: bootstrap
			)
		} catch {
			stopProcess(process, timeout: 2)
			try? FileManager.default.removeItem(at: runtimeDirectory)
			throw error
		}
	}

	var isRunning: Bool {
		process.isRunning
	}

	func stop() {
		guard !stopped else { return }
		stopped = true
		Self.stopProcess(process, timeout: 2)
		try? FileManager.default.removeItem(at: runtimeDirectory)
	}

	private static func stopProcess(
		_ process: Process,
		timeout: TimeInterval
	) {
		guard process.isRunning else { return }
		process.terminate()
		let deadline: Date = Date().addingTimeInterval(timeout)
		while process.isRunning, Date() < deadline {
			_ = RunLoop.main.run(
				mode: .default,
				before: Date().addingTimeInterval(0.01)
			)
		}
		if process.isRunning {
			_ = kill(process.processIdentifier, SIGKILL)
		}
		process.waitUntilExit()
	}
}

private func readBoundedLine(
	from handle: FileHandle,
	maximumBytes: Int,
	timeout: TimeInterval
) throws -> [UInt8] {
	precondition(maximumBytes > 0)
	precondition(timeout > 0)
	var line: [UInt8] = []
	line.reserveCapacity(256)
	let deadline: Date = Date().addingTimeInterval(timeout)
	while true {
		let remaining: TimeInterval = deadline.timeIntervalSinceNow
		guard remaining > 0 else {
			throw ProbeFailure(
				description: "timed out waiting for teaserd bootstrap"
			)
		}
		let timeoutMilliseconds: Int32 = Int32(
			min(ceil(remaining * 1_000), Double(Int32.max))
		)
		var descriptor: pollfd = .init(
			fd: handle.fileDescriptor,
			events: Int16(POLLIN),
			revents: 0
		)
		let pollResult: Int32 = Darwin.poll(
			&descriptor,
			nfds_t(1),
			timeoutMilliseconds
		)
		if pollResult == 0 {
			throw ProbeFailure(
				description: "timed out waiting for teaserd bootstrap"
			)
		}
		if pollResult < 0 {
			if errno == EINTR {
				continue
			}
			throw ProbeFailure(
				description: "polling teaserd bootstrap failed: "
					+ probeErrnoDescription()
			)
		}
		guard
			let data = try handle.read(upToCount: 1),
			!data.isEmpty
		else {
			throw ProbeFailure(
				description: "teaserd ended stdout before its bootstrap newline"
			)
		}
		let byte: UInt8 = data[data.startIndex]
		if byte == 0x0A {
			if line.last == 0x0D {
				line.removeLast()
			}
			return line
		}
		guard line.count < maximumBytes else {
			throw ProbeFailure(
				description: "teaserd bootstrap exceeds \(maximumBytes) bytes"
			)
		}
		line.append(byte)
	}
}

private func probeErrnoDescription() -> String {
	let code: Int32 = errno
	guard let message = strerror(code) else {
		return "errno \(code)"
	}
	return "errno \(code) (\(String(cString: message)))"
}

private final class RuntimeState: @unchecked Sendable {
	private let lock: NSLock = .init()
	private var app: ghostty_app_t?
	private var enabled: Bool = true
	private var pendingTicks: Int = 0

	func install(app: ghostty_app_t) {
		lock.lock()
		self.app = app
		lock.unlock()
	}

	func clearApp() {
		lock.lock()
		app = nil
		lock.unlock()
	}

	func scheduleTick() {
		lock.lock()
		guard enabled else {
			lock.unlock()
			return
		}
		pendingTicks += 1
		lock.unlock()

		DispatchQueue.main.async { [self] in
			lock.lock()
			let currentApp: ghostty_app_t? = app
			let shouldTick: Bool = enabled
			lock.unlock()
			if shouldTick, let currentApp {
				ghostty_app_tick(currentApp)
			}

			lock.lock()
			pendingTicks -= 1
			lock.unlock()
		}
	}

	func disableAndDrain(timeout: TimeInterval) -> Bool {
		lock.lock()
		enabled = false
		lock.unlock()

		return pumpMainRunLoop(timeout: timeout) { [self] in
			lock.lock()
			let drained: Bool = pendingTicks == 0
			lock.unlock()
			return drained
		}
	}
}

private func logStep(_ message: String) {
	let line: Data = Data("\(probePrefix) \(message)\n".utf8)
	FileHandle.standardError.write(line)
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
	guard condition() else { throw ProbeFailure(description: message) }
}

private func pumpMainRunLoop(
	timeout: TimeInterval,
	until condition: () -> Bool
) -> Bool {
	let deadline: Date = Date().addingTimeInterval(timeout)
	while !condition(), Date() < deadline {
		_ = RunLoop.main.run(
			mode: .default,
			before: Date().addingTimeInterval(0.01)
		)
	}
	return condition()
}

private func directChildPIDs() throws -> Set<pid_t> {
	var capacity: Int = 64
	while capacity <= 16_384 {
		var pids: [pid_t] = .init(repeating: 0, count: capacity)
		errno = 0
		let count: Int32 = pids.withUnsafeMutableBytes { buffer in
			proc_listchildpids(
				getpid(),
				buffer.baseAddress,
				Int32(buffer.count)
			)
		}
		let resultErrno: Int32 = errno
		guard count >= 0, count != 0 || resultErrno == 0 else {
			throw ProbeFailure(
				description: "proc_listchildpids failed with errno \(resultErrno)"
			)
		}
		if Int(count) < capacity {
			return Set(pids.prefix(Int(count)).filter { $0 > 0 })
		}
		capacity *= 2
	}
	throw ProbeFailure(description: "direct-child PID audit exceeded its safety bound")
}

private func describePIDs(_ pids: Set<pid_t>) -> String {
	guard !pids.isEmpty else { return "none" }
	return pids.sorted().map(String.init).joined(separator: ",")
}

private func assertNoNewChildren(
	baseline: Set<pid_t>,
	phase: String
) throws {
	let current: Set<pid_t> = try directChildPIDs()
	let added: Set<pid_t> = current.subtracting(baseline)
	logStep("child audit \(phase): \(describePIDs(current))")
	try require(
		added.isEmpty,
		"external surface spawned direct child PID(s) during \(phase): "
			+ describePIDs(added)
	)
}

private func makeRuntimeConfig(state: RuntimeState) -> ghostty_runtime_config_s {
	var config: ghostty_runtime_config_s = .init()
	config.userdata = Unmanaged.passUnretained(state).toOpaque()
	config.supports_selection_clipboard = false
	config.wakeup_cb = { userdata in
		guard let userdata else { return }
		let state: RuntimeState = Unmanaged<RuntimeState>
			.fromOpaque(userdata)
			.takeUnretainedValue()
		state.scheduleTick()
	}
	config.action_cb = { _, _, _ in false }
	config.read_clipboard_cb = { _, _, _ in false }
	config.confirm_read_clipboard_cb = { _, _, _, _ in }
	config.write_clipboard_cb = { _, _, _, _, _ in }
	config.close_surface_cb = { _, _ in }
	return config
}

private func initializeGhostty() -> Int32 {
	var executable: [CChar] = Array("TeaserProbe".utf8CString)
	return executable.withUnsafeMutableBufferPointer { executableBuffer in
		var arguments: [UnsafeMutablePointer<CChar>?] = [
			executableBuffer.baseAddress,
			nil,
		]
		return arguments.withUnsafeMutableBufferPointer { argumentBuffer in
			ghostty_init(1, argumentBuffer.baseAddress)
		}
	}
}

private func readFullScreen(from surface: ghostty_surface_t) throws -> String {
	let selection: ghostty_selection_s = .init(
		top_left: ghostty_point_s(
			tag: GHOSTTY_POINT_SCREEN,
			coord: GHOSTTY_POINT_COORD_TOP_LEFT,
			x: 0,
			y: 0
		),
		bottom_right: ghostty_point_s(
			tag: GHOSTTY_POINT_SCREEN,
			coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
			x: 0,
			y: 0
		),
		rectangle: false
	)
	var text: ghostty_text_s = .init()
	guard ghostty_surface_read_text(surface, selection, &text) else {
		throw ProbeFailure(description: "ghostty_surface_read_text rejected full-screen readback")
	}
	defer { ghostty_surface_free_text(surface, &text) }
	guard let pointer = text.text else {
		throw ProbeFailure(description: "full-screen readback returned a nil text pointer")
	}
	let bytes: UnsafeRawBufferPointer = .init(
		start: UnsafeRawPointer(pointer),
		count: Int(text.text_len)
	)
	return String(decoding: bytes, as: UTF8.self)
}

private func sendCommand(_ command: String, to surface: ghostty_surface_t) {
	precondition(!command.contains("\r") && !command.contains("\n"))
	let text: String = command
	text.withCString { pointer in
		ghostty_surface_text(
			surface,
			pointer,
			UInt(text.lengthOfBytes(using: .utf8))
		)
	}

	var returnKey: ghostty_input_key_s = .init()
	returnKey.action = GHOSTTY_ACTION_PRESS
	returnKey.mods = GHOSTTY_MODS_NONE
	returnKey.consumed_mods = GHOSTTY_MODS_NONE
	returnKey.keycode = 0x24
	returnKey.text = nil
	returnKey.unshifted_codepoint = 0
	returnKey.composing = false
	_ = ghostty_surface_key(surface, returnKey)
}

private func processExists(_ processID: UInt32) -> Bool {
	guard let pid = pid_t(exactly: processID) else { return false }
	errno = 0
	return kill(pid, 0) == 0 || errno == EPERM
}

private func expectExclusiveAttachRejection(
	socketPath: String,
	sessionID: String,
	nextOffset: UInt64
) throws {
	do {
		let unexpectedClient: AttachmentClient = try .connect(
			socketPath: socketPath,
			sessionID: sessionID,
			surfaceID: 9_002,
			nextOffset: nextOffset,
			frameReadTimeoutSeconds: 5
		)
		unexpectedClient.close()
		throw ProbeFailure(
			description: "teaserd allowed a second live attachment"
		)
	} catch let error as AttachmentClientError {
		guard
			case .serverRejected(let code, _) = error,
			code == "session_already_attached"
		else {
			throw ProbeFailure(
				description: "second attachment failed for the wrong reason: \(error)"
			)
		}
	}
}

@MainActor
private func validateRenderedIOSurface(
	view: NSView,
	surface: ghostty_surface_t
) throws {
	ghostty_surface_draw(surface)
	let receivedContents: Bool = pumpMainRunLoop(timeout: 5) {
		view.layer?.contents != nil
	}
	try require(receivedContents, "draw completed without installing layer contents")
	guard let layer = view.layer else {
		throw ProbeFailure(description: "Ghostty did not install a backing layer")
	}
	let className: String = NSStringFromClass(type(of: layer))
	try require(
		className.hasSuffix("IOSurfaceLayer"),
		"expected Ghostty IOSurfaceLayer, got \(className)"
	)
	guard let contents = layer.contents else {
		throw ProbeFailure(description: "IOSurfaceLayer has no rendered contents")
	}
	let contentsType: CFTypeID = CFGetTypeID(contents as CFTypeRef)
	let ioSurfaceType: CFTypeID = IOSurfaceGetTypeID()
	try require(
		contentsType == ioSurfaceType,
		"IOSurfaceLayer contents are not an IOSurface "
			+ "(type \(contentsType), expected \(ioSurfaceType))"
	)
	logStep("rendered \(className) with live IOSurface contents")
}

@MainActor
private func runProbe() throws {
	logStep("initializing Ghostty")
	let initResult: Int32 = initializeGhostty()
	try require(
		initResult == GHOSTTY_SUCCESS,
		"ghostty_init failed with status \(initResult)"
	)

	logStep("initializing NSApplication, NSWindow, and NSView")
	let application: NSApplication = .shared
	application.setActivationPolicy(.accessory)
	application.finishLaunching()

	let contentSize: NSSize = .init(width: 720, height: 420)
	let window: NSWindow = .init(
		contentRect: NSRect(origin: .zero, size: contentSize),
		styleMask: [.titled, .closable, .resizable],
		backing: .buffered,
		defer: false
	)
	window.title = "Teaser libghostty probe"
	window.setContentSize(contentSize)
	let view: NSView = .init(frame: NSRect(origin: .zero, size: contentSize))
	window.contentView = view
	window.makeKeyAndOrderFront(nil)
	application.activate(ignoringOtherApps: true)
	application.updateWindows()
	defer {
		window.orderOut(nil)
		window.close()
	}

	logStep("starting teaserd probe Session")
	let daemon: ProbeDaemon = try .start()
	defer {
		logStep("stopping teaserd probe daemon")
		daemon.stop()
	}
	let bootstrap: ProbeBootstrap = daemon.bootstrap
	logStep(
		"teaserd Session \(bootstrap.sessionID) owns child "
			+ "\(bootstrap.processID)"
	)

	logStep("creating finalized Ghostty config")
	guard let ghosttyConfig: ghostty_config_t = ghostty_config_new() else {
		throw ProbeFailure(description: "ghostty_config_new returned nil")
	}
	ghostty_config_finalize(ghosttyConfig)
	defer {
		logStep("freeing Ghostty config")
		ghostty_config_free(ghosttyConfig)
	}

	logStep("creating Ghostty app with host runtime callbacks")
	let runtimeState: RuntimeState = .init()
	var runtimeConfig: ghostty_runtime_config_s = makeRuntimeConfig(
		state: runtimeState
	)
	guard let ghosttyApp: ghostty_app_t = ghostty_app_new(
		&runtimeConfig,
		ghosttyConfig
	) else {
		throw ProbeFailure(description: "ghostty_app_new returned nil")
	}
	runtimeState.install(app: ghosttyApp)
	defer {
		logStep("freeing Ghostty app")
		withExtendedLifetime(runtimeState) {
			if !runtimeState.disableAndDrain(timeout: 5) {
				logStep("runtime wakeup queue did not drain before app teardown")
			}
			runtimeState.clearApp()
			ghostty_app_free(ghosttyApp)
		}
	}

	let baselineChildren: Set<pid_t> = try directChildPIDs()
	logStep("child audit before surface: \(describePIDs(baselineChildren))")

	logStep("creating EXTERNAL Ghostty surface")
	let surfaceID: UInt64 = 9_001
	let adapter: TerminalSurfaceAdapter = .init()
	var surfaceConfig: ghostty_surface_config_s = adapter.makeConfiguration(
		view: view,
		scaleFactor: window.backingScaleFactor
	)
	let createdSurface: ghostty_surface_t? = withExtendedLifetime(adapter) {
		ghostty_surface_new(ghosttyApp, &surfaceConfig)
	}
	guard let surface: ghostty_surface_t = createdSurface else {
		throw ProbeFailure(
			description: "ghostty_surface_new returned nil for EXTERNAL surface"
		)
	}
	var liveSurface: ghostty_surface_t? = surface
	var livePump: TerminalAttachmentPump?
	defer {
		if let liveSurface {
			logStep("quiescing Ghostty callbacks")
			adapter.quiesce()
			if let livePump {
				logStep("draining and stopping the attachment pump")
				livePump.detach()
				if !livePump.waitUntilStopped(timeout: 6) {
					logStep(
						"attachment pump missed its teardown barrier; "
							+ "stopping teaserd before retry"
					)
					daemon.stop()
					if !livePump.waitUntilStopped(timeout: 2) {
						logStep(
							"refusing to free a Surface with feed or socket "
								+ "work still in flight"
						)
						Darwin._exit(EXIT_FAILURE)
					}
				}
			}
			logStep("freeing Ghostty surface")
			withExtendedLifetime(adapter) {
				ghostty_surface_free(liveSurface)
			}
		}
	}

	logStep("starting the asynchronous attachment pump")
	let connector: ProbeAttachmentConnector = .init(
		socketPath: bootstrap.socketPath,
		sessionID: bootstrap.sessionID,
		surfaceID: surfaceID
	)
	let outputSink: ProbeSurfaceOutputSink = .init(surface: surface)
	let pumpEvents: ProbePumpEventRecorder = .init()
	let pump: TerminalAttachmentPump = .init(
		connector: connector,
		outputSink: outputSink,
		eventHandler: { [pumpEvents] event in
			pumpEvents.record(event)
		}
	)
	livePump = pump
	try adapter.install(enqueuer: pump)
	pump.start()

	let readyMarker: String = "READY \(bootstrap.processID)"
	let initiallyConnected: Bool = pumpMainRunLoop(timeout: 5) {
		pumpEvents.sawInitialConnection()
			&& outputSink.contains(readyMarker)
			&& pump.committedOutputOffset == outputSink.byteCount()
	}
	try require(
		initiallyConnected,
		"asynchronous pump did not connect and feed \(readyMarker)"
	)
	try require(connector.offsets() == [0], "initial attach did not request offset zero")
	try expectExclusiveAttachRejection(
		socketPath: bootstrap.socketPath,
		sessionID: bootstrap.sessionID,
		nextOffset: pump.committedOutputOffset
	)
	logStep("second live attachment was rejected")

	logStep("resizing Ghostty and forwarding the resize frame to teaserd")
	let framebuffer: NSSize = view.convertToBacking(view.bounds).size
	let contentScale: Double = Double(window.backingScaleFactor)
	let widthPixels: UInt32 = UInt32(framebuffer.width.rounded())
	let heightPixels: UInt32 = UInt32(framebuffer.height.rounded())
	adapter.resetResizes()
	ghostty_surface_set_content_scale(surface, contentScale, contentScale)
	ghostty_surface_set_size(surface, widthPixels, heightPixels)
	let reportedSize: ghostty_surface_size_s = ghostty_surface_size(surface)
	let expectedResize: TerminalResizeEvent = .init(size: reportedSize)
	let resizeMatched: Bool = pumpMainRunLoop(timeout: 5) {
		resizeMatchesSurface(adapter.lastResize(), size: reportedSize)
	}
	try require(
		resizeMatched,
		"resize callback inconsistent with \(expectedResize), "
			+ "last callback \(String(describing: adapter.lastResize()))"
	)
	logStep(
		"resize callback matched grid \(reportedSize.columns)x\(reportedSize.rows): "
			+ "\(String(describing: adapter.lastResize()))"
	)
	sendCommand("SIZE", to: surface)
	let sizeMarker: String = "SIZE \(reportedSize.rows) \(reportedSize.columns)"
	let sizeObserved: Bool = pumpMainRunLoop(timeout: 5) {
		outputSink.contains(sizeMarker)
			&& pump.committedOutputOffset == outputSink.byteCount()
	}
	try require(
		sizeObserved,
		"continuous pump output omitted \(sizeMarker)"
	)
	logStep("probe child observed \(sizeMarker)")

	logStep("sending PING through Ghostty's external write callback")
	sendCommand("PING", to: surface)
	let pongMarker: String = "PONG \(bootstrap.processID)"
	let firstPongObserved: Bool = pumpMainRunLoop(timeout: 5) {
		outputSink.occurrenceCount(of: pongMarker) == 1
			&& pump.committedOutputOffset == outputSink.byteCount()
	}
	try require(
		firstPongObserved,
		"real PTY input did not return the first \(pongMarker)"
	)
	logStep("real PTY input returned \(pongMarker)")

	logStep("forcing a real Metal draw")
	try validateRenderedIOSurface(view: view, surface: surface)

	logStep("arming offline output through the Surface")
	let disconnectOffset: UInt64 = pump.committedOutputOffset
	sendCommand("ARM", to: surface)
	let armBytes: [UInt8] = Array("ARM\r".utf8)
	let armDelivered: Bool = pumpMainRunLoop(timeout: 5) {
		connector.transport(generation: 1)?
			.successfulInputContains(armBytes) == true
	}
	try require(
		armDelivered,
		"first transport did not successfully write ARM before fault injection"
	)
	connector.holdReconnect(for: 0.35)

	logStep("injecting a real attachment-socket drop")
	guard let firstTransport = connector.transport(generation: 1) else {
		throw ProbeFailure(description: "missing first fault-injecting transport")
	}
	firstTransport.injectDrop()
	try require(
		processExists(bootstrap.processID),
		"probe child died when its attachment socket dropped"
	)

	let offlineMarker: String = "OFFLINE \(bootstrap.processID)"
	let automaticallyReconnected: Bool = pumpMainRunLoop(timeout: 6) {
		pumpEvents.sawConnectionUncertainty()
			&& pumpEvents.pausedRecoveryID(offset: disconnectOffset) != nil
			&& outputSink.contains(offlineMarker)
			&& pump.committedOutputOffset == outputSink.byteCount()
	}
	try require(
		automaticallyReconnected,
		"pump did not reconnect at \(disconnectOffset) and replay \(offlineMarker)"
	)
	let connectionOffsets: [UInt64] = connector.offsets()
	try require(
		connectionOffsets.count == 2
			&& connectionOffsets.last == disconnectOffset,
		"reconnect offsets were \(connectionOffsets), expected [0, \(disconnectOffset)]"
	)
	guard let secondTransport = connector.transport(generation: 2) else {
		throw ProbeFailure(description: "missing reconnected transport")
	}
	let offlineEndOffset: UInt64 =
		disconnectOffset + UInt64("\(offlineMarker)\r\n".utf8.count)
	try require(
		secondTransport.upgrade.replayFrom == disconnectOffset
			&& secondTransport.upgrade.liveOffset >= offlineEndOffset,
		"reconnect upgrade did not prove offline replay: replay_from "
			+ "\(secondTransport.upgrade.replayFrom), live_offset "
			+ "\(secondTransport.upgrade.liveOffset), expected at least "
			+ "\(offlineEndOffset)"
	)
	try require(
		!secondTransport.successfulInputContains(armBytes),
		"reconnected transport replayed old ARM input"
	)
	try require(
		processExists(bootstrap.processID),
		"automatic reconnect did not preserve child PID \(bootstrap.processID)"
	)
	guard
		let recoveryID: UInt64 =
			pumpEvents.pausedRecoveryID(offset: disconnectOffset)
	else {
		throw ProbeFailure(description: "missing reconnect recovery identifier")
	}
	logStep("replayed \(offlineMarker) from the unchanged child with input paused")

	logStep("proving paused input is not forwarded")
	let pingBytes: [UInt8] = Array("PING\r".utf8)
	sendCommand("PING", to: surface)
	_ = pumpMainRunLoop(timeout: 0.25) {
		secondTransport.successfulInputContains(pingBytes)
	}
	try require(
		!secondTransport.successfulInputContains(pingBytes),
		"input was forwarded before reconnect uncertainty was acknowledged"
	)
	try require(
		pump.acknowledgeInputAfterReconnect(recoveryID: recoveryID),
		"pump rejected explicit input-resume acknowledgement"
	)
	sendCommand("PING", to: surface)
	let resumedInputWorked: Bool = pumpMainRunLoop(timeout: 5) {
		secondTransport.successfulInputContains(pingBytes)
			&& outputSink.occurrenceCount(of: pongMarker) == 2
	}
	try require(
		resumedInputWorked,
		"explicit acknowledgement did not resume fresh input"
	)
	logStep("fresh input resumed without retransmitting old input")

	let screen: String = try readFullScreen(from: surface)
	try require(
		screen.contains(offlineMarker),
		"full-screen readback omitted real child output; got "
			+ String(reflecting: screen)
	)
	logStep("Ghostty full-screen readback contained real child output")

	logStep("requesting an ordered probe-child exit")
	sendCommand("EXIT", to: surface)
	let exitMarker: String = "EXIT \(bootstrap.processID)"
	let cleanExitObserved: Bool = pumpMainRunLoop(timeout: 5) {
		outputSink.contains("\(exitMarker)\r\n")
			&& pumpEvents.sawCleanExit()
	}
	try require(
		cleanExitObserved,
		"pump did not feed the EXIT marker before the clean stopped event"
	)
	try require(
		pump.waitUntilStopped(timeout: 0),
		"pump stopped event arrived before its teardown barrier"
	)
	let childExited: Bool = pumpMainRunLoop(timeout: 5) {
		!processExists(bootstrap.processID)
	}
	try require(childExited, "probe child remained alive after EXIT")

	let callbackFailures: [String] = adapter.failures()
	try require(
		callbackFailures.isEmpty,
		"host callback failure(s): \(callbackFailures.joined(separator: "; "))"
	)
	try assertNoNewChildren(
		baseline: baselineChildren,
		phase: "live external surface"
	)
	try require(daemon.isRunning, "teaserd exited before Surface teardown")

	logStep("quiescing callbacks after the pump teardown barrier")
	adapter.quiesce()
	withExtendedLifetime(adapter) {
		ghostty_surface_free(surface)
	}
	liveSurface = nil
	livePump = nil
	logStep("disabling and draining Ghostty runtime wakeups")
	try require(
		runtimeState.disableAndDrain(timeout: 5),
		"timed out draining queued Ghostty runtime wakeups"
	)
	try assertNoNewChildren(
		baseline: baselineChildren,
		phase: "after external surface teardown"
	)
}

do {
	try runProbe()
	logStep("PASS")
	exit(EXIT_SUCCESS)
} catch {
	logStep("FAIL: \(error)")
	exit(EXIT_FAILURE)
}
