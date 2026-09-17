import AppKit
import CoreGraphics
import Foundation

// The replaceable boundary of the window-adoption chain: pointer input, time,
// window queries, and per-window leases. Production wires the Accessibility
// implementations that live beside the AXUIElement code in
// `ManagedExternalWindow.swift`. A test substitutes deterministic pointer events,
// window snapshots, and time, so the same orchestration runs without a user
// desktop, a global event monitor, an Accessibility prompt, or any movement of a
// real window.

enum ExternalWindowPointerPhase: Equatable, Sendable {
	case down
	case dragged
	case up
}

/// `monitored` carries one delivered mouse event. `sampled` carries one periodic
/// button-state reading, because native title-bar tracking can omit drag and up
/// deliveries entirely. Edge detection between the two stays in the observer.
enum ExternalWindowPointerEvent: Equatable, Sendable {
	case monitored(phase: ExternalWindowPointerPhase, appKitScreenLocation: CGPoint)
	case sampled(isButtonDown: Bool, appKitScreenLocation: CGPoint)
}

typealias ExternalWindowPointerEventHandler = @MainActor @Sendable (
	ExternalWindowPointerEvent
) -> Void

@MainActor
protocol ExternalWindowPointerSource: AnyObject {
	func start(handler: @escaping ExternalWindowPointerEventHandler) throws
	func stop()
}

@MainActor
protocol ExternalWindowClock: AnyObject {
	var now: TimeInterval { get }
}

/// A typed selection handle. The production handle is `ExternalWindowSelection`
/// and carries live Accessibility references; a substitute carries a fixture.
/// Neither exposes an `AXUIElement` across this boundary, and a substitute handle
/// is rejected by the Accessibility implementation rather than adapted.
@MainActor
protocol ExternalWindowHandle: AnyObject {
	var identity: ExternalWindowIdentity { get }
	var initialSnapshot: ManagedExternalWindowSnapshot { get }
}

/// One adopted window's lease: bind an exact identity, read it, move it, restore
/// it, and release it.
@MainActor
protocol ExternalWindowLease: AnyObject {
	var identity: ExternalWindowIdentity? { get }

	@discardableResult
	func bind(handle: any ExternalWindowHandle) throws -> ManagedExternalWindowSnapshot
	@discardableResult
	func bind(identity: ExternalWindowIdentity) throws -> ManagedExternalWindowSnapshot
	func snapshot() throws -> ManagedExternalWindowSnapshot
	@discardableResult
	func apply(appKitScreenFrame: CGRect) throws -> ManagedExternalWindowSnapshot
	func applyCoalesced(appKitScreenFrame: CGRect)
	@discardableResult
	func restore(
		snapshot: ManagedExternalWindowSnapshot
	) throws -> ManagedExternalWindowSnapshot
	func raise() throws
	func focusAndRaise() throws
	@discardableResult
	func release(restoringOriginalFrame: Bool) -> Bool
}

/// One window a user could bind to a Panel, visible or not. A picker shows the
/// rejected ones too: an empty list cannot distinguish "nothing to adopt" from
/// "everything was filtered away".
struct ExternalWindowCandidate: Equatable, Sendable {
	let identity: ExternalWindowIdentity
	let applicationName: String
	let bundleIdentifier: String?
	/// Absent when the provider publishes no usable title. macOS reports an empty
	/// Core Graphics name for most windows, and an Accessibility title only for
	/// the windows it still resolves.
	let windowTitle: String?
	let appKitScreenFrame: CGRect
	let isVisibleOnCurrentSpace: Bool
	/// Why this window cannot be adopted right now, or nil when it can.
	let rejectionReason: String?

	var isAdoptable: Bool { rejectionReason == nil }
}

/// Permission state, window selection and validation, and lease creation.
@MainActor
protocol ExternalWindowService: AnyObject {
	func permissionStatus(prompt: Bool) -> ExternalWindowPermissionStatus
	func selectWindow(
		atAppKitScreenPoint point: CGPoint,
		excludingProcessIdentifiers: Set<pid_t>
	) throws -> any ExternalWindowHandle
	func selectWindow(identity: ExternalWindowIdentity) throws -> any ExternalWindowHandle
	/// Every window a user could bind to a Panel, including ones hidden by Stage
	/// Manager or resident on another Space. Windows that cannot be adopted are
	/// returned carrying their reason rather than dropped.
	func adoptableWindows(
		excludingProcessIdentifiers: Set<pid_t>
	) -> [ExternalWindowCandidate]
	func validateIdentity(of handle: any ExternalWindowHandle) throws
	/// Fails only when the window server no longer lists the window. A window
	/// hidden by Stage Manager or sitting on another Space is still live, still
	/// identifiable, and still movable.
	func validateWindowIsLive(of handle: any ExternalWindowHandle) throws
	func snapshot(of handle: any ExternalWindowHandle) throws -> ManagedExternalWindowSnapshot
	func bundleIdentifier(forProcessIdentifier processIdentifier: pid_t) -> String?
	func makeLease(
		onEvent: @escaping ManagedExternalWindowEventHandler,
		onApplyError: @escaping ManagedExternalWindowApplyErrorHandler
	) -> any ExternalWindowLease
}

@MainActor
final class SystemExternalWindowClock: ExternalWindowClock {
	var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// Installs the passive global mouse monitor and the button-state sampler that
/// production adoption depends on. Nothing here runs in a default test.
@MainActor
final class SystemExternalWindowPointerSource: ExternalWindowPointerSource {
	static let samplingInterval: TimeInterval = 1.0 / 30.0

	private final class MonitorRelay: @unchecked Sendable {
		private weak var owner: SystemExternalWindowPointerSource?

		init(owner: SystemExternalWindowPointerSource) {
			self.owner = owner
		}

		func receive(_ event: ExternalWindowPointerEvent) {
			Task { @MainActor [weak owner, self] in
				guard owner?.relay === self else { return }
				owner?.deliver(event)
			}
		}
	}

	private final class MonitorToken: @unchecked Sendable {
		let value: Any

		init(value: Any) {
			self.value = value
		}

		deinit { NSEvent.removeMonitor(value) }
	}

	private var handler: ExternalWindowPointerEventHandler?
	private var monitor: MonitorToken?
	private var relay: MonitorRelay?
	private var samplingTimer: Timer?

	func start(handler: @escaping ExternalWindowPointerEventHandler) throws {
		guard monitor == nil else { return }
		let relay: MonitorRelay = .init(owner: self)
		let mask: NSEvent.EventTypeMask = [
			.leftMouseDown,
			.leftMouseDragged,
			.leftMouseUp,
		]
		guard let monitor = NSEvent.addGlobalMonitorForEvents(
			matching: mask,
			handler: { event in
				let phase: ExternalWindowPointerPhase
				switch event.type {
				case .leftMouseDown: phase = .down
				case .leftMouseDragged: phase = .dragged
				case .leftMouseUp: phase = .up
				default: return
				}
				relay.receive(
					.monitored(
						phase: phase,
						appKitScreenLocation: NSEvent.mouseLocation
					)
				)
			}
		) else {
			throw ManagedExternalWindowError.globalMonitorUnavailable
		}
		self.handler = handler
		self.relay = relay
		self.monitor = .init(value: monitor)
		// Native title-bar tracking can omit NSEvent drag/up deliveries. Sample
		// actual button state until release as well.
		let timer: Timer = .init(
			timeInterval: Self.samplingInterval,
			repeats: true
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.sample() }
		}
		samplingTimer = timer
		RunLoop.main.add(timer, forMode: .common)
	}

	func stop() {
		samplingTimer?.invalidate()
		samplingTimer = nil
		monitor = nil
		relay = nil
		handler = nil
	}

	private func sample() {
		deliver(
			.sampled(
				isButtonDown: CGEventSource.buttonState(
					.combinedSessionState,
					button: .left
				),
				appKitScreenLocation: NSEvent.mouseLocation
			)
		)
	}

	private func deliver(_ event: ExternalWindowPointerEvent) {
		handler?(event)
	}
}
