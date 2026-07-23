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

private struct ResizeEvent: Equatable, CustomStringConvertible {
	let columns: UInt16
	let rows: UInt16
	let widthPixels: UInt32
	let heightPixels: UInt32

	var description: String {
		"\(columns)x\(rows) cells, \(widthPixels)x\(heightPixels) px"
	}

	init(
		columns: UInt16,
		rows: UInt16,
		widthPixels: UInt32,
		heightPixels: UInt32
	) {
		self.columns = columns
		self.rows = rows
		self.widthPixels = widthPixels
		self.heightPixels = heightPixels
	}

	init(size: ghostty_surface_size_s) {
		self.init(
			columns: size.columns,
			rows: size.rows,
			widthPixels: size.width_px,
			heightPixels: size.height_px
		)
	}
}

private func resizeMatchesSurface(
	_ event: ResizeEvent?,
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

private final class ExternalCallbackState: @unchecked Sendable {
	private let condition: NSCondition = .init()
	private var acceptingCallbacks: Bool = true
	private var activeCallbacks: Int = 0
	private var outputBytes: [UInt8] = []
	private var resizeHistory: [ResizeEvent] = []
	private var callbackFailures: [String] = []

	func recordWrite(bytes: UnsafePointer<UInt8>?, count: Int) {
		guard beginCallback() else { return }
		defer { endCallback() }

		guard count >= 0 else {
			recordFailure("write callback reported a negative byte count")
			return
		}
		guard count == 0 || bytes != nil else {
			recordFailure("write callback reported \(count) bytes with a nil pointer")
			return
		}
		guard let bytes, count > 0 else { return }
		let copy: [UInt8] = Array(UnsafeBufferPointer(start: bytes, count: count))

		condition.lock()
		outputBytes.append(contentsOf: copy)
		condition.broadcast()
		condition.unlock()
	}

	func recordResize(
		columns: UInt16,
		rows: UInt16,
		widthPixels: UInt32,
		heightPixels: UInt32
	) {
		guard beginCallback() else { return }
		defer { endCallback() }

		let event: ResizeEvent = .init(
			columns: columns,
			rows: rows,
			widthPixels: widthPixels,
			heightPixels: heightPixels
		)
		condition.lock()
		resizeHistory.append(event)
		condition.broadcast()
		condition.unlock()
	}

	func resetWrites() {
		condition.lock()
		outputBytes.removeAll(keepingCapacity: true)
		condition.unlock()
	}

	func writes() -> [UInt8] {
		condition.lock()
		defer { condition.unlock() }
		return outputBytes
	}

	func lastResize() -> ResizeEvent? {
		condition.lock()
		defer { condition.unlock() }
		return resizeHistory.last
	}

	func resetResizes() {
		condition.lock()
		resizeHistory.removeAll(keepingCapacity: true)
		condition.unlock()
	}

	func failures() -> [String] {
		condition.lock()
		defer { condition.unlock() }
		return callbackFailures
	}

	func quiesce() {
		condition.lock()
		acceptingCallbacks = false
		while activeCallbacks > 0 {
			condition.wait()
		}
		condition.unlock()
	}

	private func beginCallback() -> Bool {
		condition.lock()
		defer { condition.unlock() }
		guard acceptingCallbacks else { return false }
		activeCallbacks += 1
		return true
	}

	private func endCallback() {
		condition.lock()
		activeCallbacks -= 1
		condition.broadcast()
		condition.unlock()
	}

	private func recordFailure(_ message: String) {
		condition.lock()
		callbackFailures.append(message)
		condition.broadcast()
		condition.unlock()
	}
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

private func makeExternalSurfaceConfig(
	view: NSView,
	callbacks: ExternalCallbackState,
	scaleFactor: CGFloat
) -> ghostty_surface_config_s {
	var config: ghostty_surface_config_s = ghostty_surface_config_new()
	config.platform_tag = GHOSTTY_PLATFORM_MACOS
	config.platform = ghostty_platform_u(
		macos: ghostty_platform_macos_s(
			nsview: Unmanaged.passUnretained(view).toOpaque()
		)
	)
	config.scale_factor = Double(scaleFactor)
	config.io_mode = GHOSTTY_SURFACE_IO_EXTERNAL
	config.external_userdata = Unmanaged.passUnretained(callbacks).toOpaque()
	config.external_write_cb = { userdata, bytes, count in
		guard let userdata else { return }
		let state: ExternalCallbackState = Unmanaged<ExternalCallbackState>
			.fromOpaque(userdata)
			.takeUnretainedValue()
		state.recordWrite(bytes: bytes, count: count)
	}
	config.external_resize_cb = {
		userdata,
		columns,
		rows,
		widthPixels,
		heightPixels in
		guard let userdata else { return }
		let state: ExternalCallbackState = Unmanaged<ExternalCallbackState>
			.fromOpaque(userdata)
			.takeUnretainedValue()
		state.recordResize(
			columns: columns,
			rows: rows,
			widthPixels: widthPixels,
			heightPixels: heightPixels
		)
	}
	return config
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

private func feed(_ string: String, to surface: ghostty_surface_t) {
	let bytes: [UInt8] = Array(string.utf8)
	bytes.withUnsafeBufferPointer { buffer in
		ghostty_surface_feed_output(surface, buffer.baseAddress, buffer.count)
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

private func sendProbeInput(to surface: ghostty_surface_t) {
	let text: String = "probe"
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

	logStep("verifying EXTERNAL plus command is rejected")
	let rejectedCallbacks: ExternalCallbackState = .init()
	let rejectedView: NSView = .init(frame: view.frame)
	var rejectedConfig: ghostty_surface_config_s = makeExternalSurfaceConfig(
		view: rejectedView,
		callbacks: rejectedCallbacks,
		scaleFactor: window.backingScaleFactor
	)
	let acceptedRejectedSurface: Bool = withExtendedLifetime(
		(rejectedCallbacks, rejectedView)
	) {
		let rejectedSurface: ghostty_surface_t? = "printf unexpected".withCString {
			command in
			rejectedConfig.command = command
			return ghostty_surface_new(ghosttyApp, &rejectedConfig)
		}
		guard let rejectedSurface else { return false }
		rejectedCallbacks.quiesce()
		ghostty_surface_free(rejectedSurface)
		return true
	}
	if acceptedRejectedSurface {
		throw ProbeFailure(
			description: "Ghostty accepted a command on an EXTERNAL surface"
		)
	}
	try assertNoNewChildren(
		baseline: baselineChildren,
		phase: "rejected external command"
	)

	logStep("creating EXTERNAL Ghostty surface")
	let callbacks: ExternalCallbackState = .init()
	var surfaceConfig: ghostty_surface_config_s = makeExternalSurfaceConfig(
		view: view,
		callbacks: callbacks,
		scaleFactor: window.backingScaleFactor
	)
	let createdSurface: ghostty_surface_t? = withExtendedLifetime(callbacks) {
		ghostty_surface_new(ghosttyApp, &surfaceConfig)
	}
	guard let surface: ghostty_surface_t = createdSurface else {
		throw ProbeFailure(description: "ghostty_surface_new returned nil for EXTERNAL surface")
	}
	var liveSurface: ghostty_surface_t? = surface
	defer {
		if let liveSurface {
			logStep("quiescing host callbacks and completed feed path")
			callbacks.quiesce()
			logStep("freeing Ghostty surface")
			withExtendedLifetime(callbacks) {
				ghostty_surface_free(liveSurface)
			}
		}
	}

	logStep("resizing surface and checking host resize callback")
	let framebuffer: NSSize = view.convertToBacking(view.bounds).size
	let contentScale: Double = Double(window.backingScaleFactor)
	let widthPixels: UInt32 = UInt32(framebuffer.width.rounded())
	let heightPixels: UInt32 = UInt32(framebuffer.height.rounded())
	callbacks.resetResizes()
	ghostty_surface_set_content_scale(surface, contentScale, contentScale)
	ghostty_surface_set_size(surface, widthPixels, heightPixels)
	let reportedSize: ghostty_surface_size_s = ghostty_surface_size(surface)
	let expectedResize: ResizeEvent = .init(size: reportedSize)
	let resizeMatched: Bool = pumpMainRunLoop(timeout: 5) {
		resizeMatchesSurface(callbacks.lastResize(), size: reportedSize)
	}
	try require(
		resizeMatched,
		"resize callback inconsistent with \(expectedResize), "
			+ "last callback \(String(describing: callbacks.lastResize()))"
	)
	logStep(
		"resize callback matched grid \(reportedSize.columns)x\(reportedSize.rows): "
			+ "\(String(describing: callbacks.lastResize()))"
	)

	logStep("feeding marker and reading the full terminal screen")
	let marker: String = "TACO-EXTERNAL-IO-MARKER"
	feed("\u{1B}[2J\u{1B}[H\(marker)", to: surface)
	let screen: String = try readFullScreen(from: surface)
	try require(
		screen.contains(marker),
		"full-screen readback did not contain marker; got \(String(reflecting: screen))"
	)
	logStep("full-screen readback contained marker")

	logStep("sending text plus Return and checking exact encoded bytes")
	callbacks.resetWrites()
	sendProbeInput(to: surface)
	let expectedInput: [UInt8] = Array("probe\r".utf8)
	let receivedInput: Bool = pumpMainRunLoop(timeout: 5) {
		callbacks.writes().count >= expectedInput.count
	}
	try require(receivedInput, "timed out waiting for external input callback")
	_ = pumpMainRunLoop(timeout: 0.05) { false }
	let actualInput: [UInt8] = callbacks.writes()
	try require(
		actualInput == expectedInput,
		"external input mismatch: expected \(String(reflecting: expectedInput)), "
			+ "got \(String(reflecting: actualInput))"
	)
	logStep("external input callback returned exact probe\\r bytes")

	logStep("forcing a real Metal draw")
	try validateRenderedIOSurface(view: view, surface: surface)

	let callbackFailures: [String] = callbacks.failures()
	try require(
		callbackFailures.isEmpty,
		"host callback failure(s): \(callbackFailures.joined(separator: "; "))"
	)
	try assertNoNewChildren(
		baseline: baselineChildren,
		phase: "live external surface"
	)

	logStep("quiescing callbacks before explicit surface teardown")
	callbacks.quiesce()
	withExtendedLifetime(callbacks) {
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
