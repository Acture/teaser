import AppKit
import CoreFoundation
import Darwin
import Foundation
import GhosttyKit
import IOSurface
import QuartzCore

private let probePrefix: String = "[TACOProbe]"

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
			let binaryPath = ProcessInfo.processInfo.environment["TACO_TACOD_BIN"],
			!binaryPath.isEmpty
		else {
			throw ProbeFailure(
				description: "TACO_TACOD_BIN must name the tacod probe binary"
			)
		}
		guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
			throw ProbeFailure(
				description: "TACO_TACOD_BIN is not executable: \(binaryPath)"
			)
		}

		let runtimeToken: String = UUID().uuidString.lowercased()
		let runtimeDirectory: URL = URL(
			fileURLWithPath: "/tmp",
			isDirectory: true
		)
			.appendingPathComponent(
				"taco-m09-\(runtimeToken)",
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
					description: "invalid tacod probe bootstrap: \(error)"
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
				description: "timed out waiting for tacod bootstrap"
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
				description: "timed out waiting for tacod bootstrap"
			)
		}
		if pollResult < 0 {
			if errno == EINTR {
				continue
			}
			throw ProbeFailure(
				description: "polling tacod bootstrap failed: "
					+ probeErrnoDescription()
			)
		}
		guard
			let data = try handle.read(upToCount: 1),
			!data.isEmpty
		else {
			throw ProbeFailure(
				description: "tacod ended stdout before its bootstrap newline"
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
				description: "tacod bootstrap exceeds \(maximumBytes) bytes"
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
	var executable: [CChar] = Array("TACOProbe".utf8CString)
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

private func feed(_ bytes: [UInt8], to surface: ghostty_surface_t) {
	bytes.withUnsafeBufferPointer { buffer in
		ghostty_surface_feed_output(surface, buffer.baseAddress, buffer.count)
	}
}

private func feed(_ string: String, to surface: ghostty_surface_t) {
	feed(Array(string.utf8), to: surface)
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

private func readOutput(
	containing marker: String,
	from client: AttachmentClient,
	feeding surface: ghostty_surface_t
) throws -> String {
	var received: [UInt8] = []
	let maximumProbeOutputBytes: Int = 1 * 1_024 * 1_024
	while received.count <= maximumProbeOutputBytes {
		switch try client.readFrame() {
		case .output(_, let bytes):
			feed(bytes, to: surface)
			received.append(contentsOf: bytes)
			let text: String = String(decoding: received, as: UTF8.self)
			if text.contains(marker) {
				return text
			}
		case .replayGap(let requested, let availableFrom):
			throw ProbeFailure(
				description: "unexpected replay gap \(requested)..<\(availableFrom) "
					+ "while waiting for \(marker)"
			)
		case .exit(let code):
			throw ProbeFailure(
				description: "probe child exited with \(code) before \(marker)"
			)
		}
	}
	throw ProbeFailure(
		description: "probe output exceeded \(maximumProbeOutputBytes) bytes "
			+ "while waiting for \(marker)"
	)
}

private func readExit(from client: AttachmentClient) throws -> UInt32 {
	while true {
		switch try client.readFrame() {
		case .output:
			throw ProbeFailure(
				description: "received unexpected output after the EXIT marker"
			)
		case .replayGap(let requested, let availableFrom):
			throw ProbeFailure(
				description: "received replay gap \(requested)..<\(availableFrom) "
					+ "while waiting for process exit"
			)
		case .exit(let code):
			return code
		}
	}
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
			description: "tacod allowed a second live attachment"
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
private func connectAfterDetach(
	socketPath: String,
	sessionID: String,
	surfaceID: UInt64,
	nextOffset: UInt64,
	timeout: TimeInterval
) throws -> AttachmentClient {
	let deadline: Date = Date().addingTimeInterval(timeout)
	while true {
		do {
			return try .connect(
				socketPath: socketPath,
				sessionID: sessionID,
				surfaceID: surfaceID,
				nextOffset: nextOffset,
				frameReadTimeoutSeconds: 5
			)
		} catch let error as AttachmentClientError {
			guard
				case .serverRejected(let code, _) = error,
				code == "session_already_attached"
			else {
				throw error
			}
			guard Date() < deadline else {
				throw ProbeFailure(
					description: "timed out waiting for the first "
						+ "attachment lease to detach"
				)
			}
			_ = RunLoop.main.run(
				mode: .default,
				before: Date().addingTimeInterval(0.01)
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
	window.title = "TACO libghostty probe"
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

	logStep("starting tacod probe Session")
	let daemon: ProbeDaemon = try .start()
	defer {
		logStep("stopping tacod probe daemon")
		daemon.stop()
	}
	let bootstrap: ProbeBootstrap = daemon.bootstrap
	logStep(
		"tacod Session \(bootstrap.sessionID) owns child "
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

	logStep("attaching the Ghostty Surface to tacod")
	let surfaceID: UInt64 = 9_001
	let firstClient: AttachmentClient = try .connect(
		socketPath: bootstrap.socketPath,
		sessionID: bootstrap.sessionID,
		surfaceID: surfaceID,
		nextOffset: 0,
		frameReadTimeoutSeconds: 5
	)
	try require(
		firstClient.upgrade.replayFrom == 0,
		"initial attachment did not start at offset zero"
	)
	try expectExclusiveAttachRejection(
		socketPath: bootstrap.socketPath,
		sessionID: bootstrap.sessionID,
		nextOffset: firstClient.nextUnreadOffset
	)
	logStep("second live attachment was rejected")

	logStep("creating EXTERNAL Ghostty surface")
	let adapter: TerminalSurfaceAdapter = .init(client: firstClient)
	var surfaceConfig: ghostty_surface_config_s = adapter.makeConfiguration(
		view: view,
		scaleFactor: window.backingScaleFactor
	)
	let createdSurface: ghostty_surface_t? = withExtendedLifetime(adapter) {
		ghostty_surface_new(ghosttyApp, &surfaceConfig)
	}
	guard let surface: ghostty_surface_t = createdSurface else {
		throw ProbeFailure(description: "ghostty_surface_new returned nil for EXTERNAL surface")
	}
	var liveSurface: ghostty_surface_t? = surface
	defer {
		if let liveSurface {
			logStep("quiescing callbacks and detaching the tacod lease")
			adapter.quiesceAndDetach()
			logStep("freeing Ghostty surface")
			withExtendedLifetime(adapter) {
				ghostty_surface_free(liveSurface)
			}
		}
	}

	let readyMarker: String = "READY \(bootstrap.processID)"
	logStep("feeding real PTY output through Ghostty: \(readyMarker)")
	_ = try readOutput(
		containing: readyMarker,
		from: firstClient,
		feeding: surface
	)

	logStep("resizing Ghostty and forwarding the resize frame to tacod")
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
	_ = try readOutput(
		containing: sizeMarker,
		from: firstClient,
		feeding: surface
	)
	logStep("probe child observed \(sizeMarker)")

	logStep("sending PING through Ghostty's external write callback")
	sendCommand("PING", to: surface)
	let pongMarker: String = "PONG \(bootstrap.processID)"
	_ = try readOutput(
		containing: pongMarker,
		from: firstClient,
		feeding: surface
	)
	logStep("real PTY input returned \(pongMarker)")

	logStep("forcing a real Metal draw")
	try validateRenderedIOSurface(view: view, surface: surface)

	logStep("arming offline output and detaching the first lease")
	let detachOffset: UInt64 = firstClient.nextUnreadOffset
	try firstClient.sendInput(Array("ARM\n".utf8))
	adapter.detach()
	try require(
		firstClient.isClosed,
		"detaching the Surface left the first attachment open"
	)
	try require(
		processExists(bootstrap.processID),
		"probe child died when its Surface detached"
	)

	logStep("reattaching at offset \(detachOffset)")
	let secondClient: AttachmentClient = try connectAfterDetach(
		socketPath: bootstrap.socketPath,
		sessionID: bootstrap.sessionID,
		surfaceID: surfaceID,
		nextOffset: detachOffset,
		timeout: 5
	)
	try require(
		secondClient.upgrade.replayFrom == detachOffset,
		"reattachment replay began at \(secondClient.upgrade.replayFrom), "
			+ "expected \(detachOffset)"
	)
	try adapter.install(client: secondClient)
	let offlineMarker: String = "OFFLINE \(bootstrap.processID)"
	_ = try readOutput(
		containing: offlineMarker,
		from: secondClient,
		feeding: surface
	)
	try require(
		secondClient.nextUnreadOffset > detachOffset,
		"reattachment did not consume retained offline output"
	)
	try require(
		processExists(bootstrap.processID),
		"reattachment did not preserve child PID \(bootstrap.processID)"
	)
	logStep("replayed \(offlineMarker) from the unchanged child")

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
	_ = try readOutput(
		containing: "\(exitMarker)\r\n",
		from: secondClient,
		feeding: surface
	)
	let exitCode: UInt32 = try readExit(from: secondClient)
	try require(exitCode == 0, "probe child exited with status \(exitCode)")
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
	try require(daemon.isRunning, "tacod exited before Surface teardown")

	logStep("quiescing callbacks, detaching, and freeing the Surface")
	adapter.quiesceAndDetach()
	withExtendedLifetime(adapter) {
		ghostty_surface_free(surface)
	}
	liveSurface = nil
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
