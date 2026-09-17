import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog
import TeaserPrivateAccessibility

enum ExternalWindowDiagnostics {
	static let logger: Logger = .init(subsystem: "com.acture.teaser", category: "window-adoption")
}

enum ExternalWindowPermissionStatus: Equatable, Sendable {
	case authorized
	case notAuthorized
}

struct ExternalWindowIdentity: Equatable, Hashable, Sendable {
	let processIdentifier: pid_t
	let windowID: CGWindowID
}

struct ManagedExternalWindowSnapshot: Equatable, Sendable {
	let identity: ExternalWindowIdentity
	let applicationName: String
	let title: String
	let appKitScreenFrame: CGRect
	let isMinimized: Bool
}

enum ManagedExternalWindowEvent: Equatable, Sendable {
	case moved
	case resized
	case destroyed
}

typealias ManagedExternalWindowEventHandler = @MainActor @Sendable (
	ManagedExternalWindowEvent
) -> Void

typealias ManagedExternalWindowApplyErrorHandler = @MainActor @Sendable (
	ManagedExternalWindowError
) -> Void

enum ManagedExternalWindowError: Error, Equatable, LocalizedError, Sendable {
	case accessibilityPermissionRequired
	case alreadyBound
	case invalidIdentity(ExternalWindowIdentity)
	case invalidFrame(CGRect)
	case noScreens
	case windowAtPointUnavailable
	case windowIdentifierUnavailable(processIdentifier: pid_t, code: AXError)
	case windowUnavailable(ExternalWindowIdentity?)
	case windowElementNotFound(ExternalWindowIdentity)
	case windowNotOnCurrentSpace(ExternalWindowIdentity)
	case windowNotStandard
	case windowIsMinimized
	case windowIsFullScreen
	case windowCannotMove
	case windowCannotResize
	case windowCannotFit(requested: CGRect, actual: CGRect)
	case windowCannotMinimize
	case snapshotIdentityMismatch(
		expected: ExternalWindowIdentity,
		actual: ExternalWindowIdentity
	)
	case globalMonitorUnavailable
	case accessibilityOperationFailed(operation: String, code: AXError)

	var errorDescription: String? {
		switch self {
		case .accessibilityPermissionRequired:
			return "Teaser needs Accessibility permission to manage external windows."
		case .alreadyBound:
			return "This external-window lease is already bound."
		case .invalidIdentity(let identity):
			return "The external-window identity is invalid: \(identity)."
		case .invalidFrame(let frame):
			return "The requested AppKit screen frame is invalid: \(frame)."
		case .noScreens:
			return "macOS did not report a menu-bar screen."
		case .windowAtPointUnavailable:
			return "No eligible external window exists at that screen location."
		case .windowIdentifierUnavailable(let processIdentifier, let code):
			return "macOS did not report a window ID for a window of process \(processIdentifier) (\(code))."
		case .windowUnavailable(let identity):
			guard let identity else { return "The managed external window is unavailable." }
			return "External window \(identity.windowID) from process \(identity.processIdentifier) is unavailable."
		case .windowElementNotFound(let identity):
			return """
				Process \(identity.processIdentifier) reports no Accessibility window \
				with ID \(identity.windowID). Teaser manages a provider's own standard \
				windows, not system surfaces or windows an application does not publish.
				"""
		case .windowNotOnCurrentSpace(let identity):
			return "External window \(identity.windowID) is not on the current Space."
		case .windowNotStandard:
			return "Teaser only manages standard application windows."
		case .windowIsMinimized:
			return "A minimized external window cannot be adopted by dragging."
		case .windowIsFullScreen:
			return "A full-screen external window cannot be adopted on its current Space."
		case .windowCannotMove:
			return "The external window does not allow its position to be changed."
		case .windowCannotResize:
			return "The external window does not allow its size to be changed."
		case .windowCannotFit(let requested, let actual):
			return "The external window cannot fit \(requested); it applied \(actual)."
		case .windowCannotMinimize:
			return "The external window does not allow its minimized state to be changed."
		case .snapshotIdentityMismatch(let expected, let actual):
			return "Cannot restore snapshot for \(actual) through lease \(expected)."
		case .globalMonitorUnavailable:
			return "macOS did not install the passive global window-drag monitor."
		case .accessibilityOperationFailed(let operation, let code):
			return "Accessibility operation \(operation) failed with \(code)."
		}
	}
}

struct ExternalWindowCurrentSpaceWindow: Equatable, Sendable {
	let identity: ExternalWindowIdentity
	let layer: Int
	let isOnscreen: Bool
	/// Only `NSApplication.ActivationPolicy.regular` owners are user applications.
	/// Accessory and prohibited owners — Stage Manager's `WindowManager`, the
	/// Dock, menu-bar agents — publish layer-zero windows the user never drags.
	let ownerIsRegularApplication: Bool
	let accessibilityFrame: CGRect
}

/// Window-server order is front to back. Exclude Teaser's transparent chrome
/// before resolving a candidate; a system-wide AX hit can land on that chrome.
func externalWindowAtPoint(
	_ point: CGPoint,
	windows: [ExternalWindowCurrentSpaceWindow],
	excludingProcessIdentifiers: Set<pid_t>
) -> ExternalWindowIdentity? {
	// Accessory owners are skipped rather than treated as blockers: their windows
	// are system chrome such as Stage Manager's strip, never drag candidates.
	guard let candidate: ExternalWindowCurrentSpaceWindow = windows.first(where: {
		$0.isOnscreen && $0.layer == 0 && $0.ownerIsRegularApplication
			&& $0.accessibilityFrame.contains(point)
	}), !excludingProcessIdentifiers.contains(candidate.identity.processIdentifier)
	else { return nil }
	return candidate.identity
}

/// The window server's own window ID is exact, so an Accessibility element is
/// selected by matching it. A duplicate or missing ID means the element list
/// cannot be trusted for this identity, and selection fails closed.
func externalWindowUniqueIndex(
	ofWindowID windowID: CGWindowID,
	in identifiers: [CGWindowID?]
) -> Int? {
	guard windowID != kCGNullWindowID else { return nil }
	let matches: [Int] = identifiers.indices.filter { identifiers[$0] == windowID }
	guard matches.count == 1 else { return nil }
	return matches.first
}

func managedExternalWindowAccessibilityFrame(
	fromAppKitScreenFrame frame: CGRect,
	menuBarScreenFrame: CGRect
) -> CGRect {
	.init(
		x: frame.minX,
		y: menuBarScreenFrame.maxY - frame.maxY,
		width: frame.width,
		height: frame.height
	)
}

func managedExternalWindowAppKitScreenFrame(
	fromAccessibilityFrame frame: CGRect,
	menuBarScreenFrame: CGRect
) -> CGRect {
	.init(
		x: frame.minX,
		y: menuBarScreenFrame.maxY - frame.maxY,
		width: frame.width,
		height: frame.height
	)
}

func managedExternalWindowAccessibilityPoint(
	fromAppKitScreenPoint point: CGPoint,
	menuBarScreenFrame: CGRect
) -> CGPoint {
	.init(x: point.x, y: menuBarScreenFrame.maxY - point.y)
}

func managedExternalWindowFramesAreApproximatelyEqual(
	_ lhs: CGRect,
	_ rhs: CGRect,
	tolerance: CGFloat = 1
) -> Bool {
	abs(lhs.minX - rhs.minX) <= tolerance
		&& abs(lhs.minY - rhs.minY) <= tolerance
		&& abs(lhs.width - rhs.width) <= tolerance
		&& abs(lhs.height - rhs.height) <= tolerance
}

func managedExternalWindowEvent(
	forAccessibilityNotification notification: String
) -> ManagedExternalWindowEvent? {
	switch notification {
	case kAXMovedNotification: return .moved
	case kAXResizedNotification: return .resized
	case kAXUIElementDestroyedNotification: return .destroyed
	default: return nil
	}
}

enum ExternalWindowPanelDropRegion: Equatable, Sendable {
	case empty
	case center
	case leading
	case trailing
	case top
	case bottom
}

struct ExternalWindowPanelGeometry: Equatable, Sendable {
	let panelID: String
	let appKitScreenFrame: CGRect
	let isOccupied: Bool
}

struct ExternalWindowPanelDropTarget: Equatable, Sendable {
	let panelID: String
	let region: ExternalWindowPanelDropRegion
}

struct ExternalWindowPanelHitTestConfiguration: Equatable, Sendable {
	let edgeFraction: CGFloat
	let minimumEdgeWidth: CGFloat
	let maximumEdgeWidth: CGFloat

	init(
		edgeFraction: CGFloat = 0.22,
		minimumEdgeWidth: CGFloat = 44,
		maximumEdgeWidth: CGFloat = 120
	) {
		self.edgeFraction = edgeFraction
		self.minimumEdgeWidth = minimumEdgeWidth
		self.maximumEdgeWidth = maximumEdgeWidth
	}
}

func externalWindowPanelDropTarget(
	at point: CGPoint,
	panels: [ExternalWindowPanelGeometry],
	configuration: ExternalWindowPanelHitTestConfiguration = .init()
) -> ExternalWindowPanelDropTarget? {
	guard point.x.isFinite,
		point.y.isFinite,
		configuration.edgeFraction.isFinite,
		configuration.edgeFraction > 0,
		configuration.edgeFraction < 0.5,
		configuration.minimumEdgeWidth.isFinite,
		configuration.minimumEdgeWidth >= 0,
		configuration.maximumEdgeWidth.isFinite,
		configuration.maximumEdgeWidth >= configuration.minimumEdgeWidth
	else { return nil }
	let containing: [ExternalWindowPanelGeometry] = panels.filter {
		$0.appKitScreenFrame.isValidManagedExternalWindowFrame
			&& $0.appKitScreenFrame.contains(point)
	}
	guard containing.count == 1, let panel = containing.first else { return nil }
	guard panel.isOccupied else {
		return .init(panelID: panel.panelID, region: .empty)
	}
	let frame: CGRect = panel.appKitScreenFrame
	let edgeWidth: CGFloat = min(
		max(
			min(frame.width, frame.height) * configuration.edgeFraction,
			configuration.minimumEdgeWidth
		),
		configuration.maximumEdgeWidth
	)
	let edges: [(ExternalWindowPanelDropRegion, CGFloat)] = [
		(.leading, point.x - frame.minX),
		(.trailing, frame.maxX - point.x),
		(.top, frame.maxY - point.y),
		(.bottom, point.y - frame.minY),
	]
	let edge = edges.filter { $0.1 <= edgeWidth }.min { $0.1 < $1.1 }
	return .init(panelID: panel.panelID, region: edge?.0 ?? .center)
}

struct ExternalWindowDragQualificationConfiguration: Equatable, Sendable {
	let minimumMouseMovement: CGFloat
	let minimumWindowMovement: CGFloat
	let maximumDeltaError: CGFloat
	let maximumSizeDelta: CGFloat

	init(
		minimumMouseMovement: CGFloat = 6,
		minimumWindowMovement: CGFloat = 4,
		maximumDeltaError: CGFloat = 10,
		maximumSizeDelta: CGFloat = 2
	) {
		self.minimumMouseMovement = minimumMouseMovement
		self.minimumWindowMovement = minimumWindowMovement
		self.maximumDeltaError = maximumDeltaError
		self.maximumSizeDelta = maximumSizeDelta
	}
}

struct ExternalWindowDragSample: Equatable, Sendable {
	let mouseAppKitScreenLocation: CGPoint
	let windowAppKitScreenFrame: CGRect
}

func qualifiesExternalWindowDrag(
	initial: ExternalWindowDragSample,
	current: ExternalWindowDragSample,
	configuration: ExternalWindowDragQualificationConfiguration = .init()
) -> Bool {
	guard initial.windowAppKitScreenFrame.isValidManagedExternalWindowFrame,
		current.windowAppKitScreenFrame.isValidManagedExternalWindowFrame,
		configuration.minimumMouseMovement.isFinite,
		configuration.minimumMouseMovement >= 0,
		configuration.minimumWindowMovement.isFinite,
		configuration.minimumWindowMovement >= 0,
		configuration.maximumDeltaError.isFinite,
		configuration.maximumDeltaError >= 0,
		configuration.maximumSizeDelta.isFinite,
		configuration.maximumSizeDelta >= 0
	else { return false }
	let mouseDelta = CGVector(
		dx: current.mouseAppKitScreenLocation.x - initial.mouseAppKitScreenLocation.x,
		dy: current.mouseAppKitScreenLocation.y - initial.mouseAppKitScreenLocation.y
	)
	let windowDelta = CGVector(
		dx: current.windowAppKitScreenFrame.minX - initial.windowAppKitScreenFrame.minX,
		dy: current.windowAppKitScreenFrame.minY - initial.windowAppKitScreenFrame.minY
	)
	return hypot(mouseDelta.dx, mouseDelta.dy) >= configuration.minimumMouseMovement
		&& hypot(windowDelta.dx, windowDelta.dy) >= configuration.minimumWindowMovement
		&& abs(mouseDelta.dx - windowDelta.dx) <= configuration.maximumDeltaError
		&& abs(mouseDelta.dy - windowDelta.dy) <= configuration.maximumDeltaError
		&& abs(current.windowAppKitScreenFrame.width - initial.windowAppKitScreenFrame.width)
			<= configuration.maximumSizeDelta
		&& abs(current.windowAppKitScreenFrame.height - initial.windowAppKitScreenFrame.height)
			<= configuration.maximumSizeDelta
}

@MainActor
final class ExternalWindowSelection: ExternalWindowHandle {
	let identity: ExternalWindowIdentity
	let initialSnapshot: ManagedExternalWindowSnapshot
	fileprivate let applicationElement: AXUIElement
	fileprivate let windowElement: AXUIElement
	fileprivate let originalAccessibilityFrame: CGRect
	fileprivate let originalMinimizedState: Bool

	fileprivate init(
		identity: ExternalWindowIdentity,
		applicationElement: AXUIElement,
		windowElement: AXUIElement,
		initialSnapshot: ManagedExternalWindowSnapshot,
		originalAccessibilityFrame: CGRect,
		originalMinimizedState: Bool
	) {
		self.identity = identity
		self.applicationElement = applicationElement
		self.windowElement = windowElement
		self.initialSnapshot = initialSnapshot
		self.originalAccessibilityFrame = originalAccessibilityFrame
		self.originalMinimizedState = originalMinimizedState
	}
}

struct ExternalWindowDragSnapshot {
	let selection: any ExternalWindowHandle
	let initialSample: ExternalWindowDragSample
	let currentSample: ExternalWindowDragSample
}

enum ExternalWindowDragCancellationReason: Equatable, Sendable {
	case windowUnavailable
	case observerStopped
}

enum ExternalWindowDragEvent {
	case began(ExternalWindowDragSnapshot)
	case changed(ExternalWindowDragSnapshot)
	case ended(ExternalWindowDragSnapshot)
	case cancelled(
		identity: ExternalWindowIdentity,
		reason: ExternalWindowDragCancellationReason
	)
}

typealias ExternalWindowDragEventHandler = @MainActor @Sendable (
	ExternalWindowDragEvent
) -> Void

@MainActor
private enum ExternalWindowSystem {
	static func permissionStatus(prompt: Bool) -> ExternalWindowPermissionStatus {
		let trusted: Bool
		if prompt {
			trusted = AXIsProcessTrustedWithOptions(
				["AXTrustedCheckOptionPrompt": true] as CFDictionary
			)
		} else {
			trusted = AXIsProcessTrusted()
		}
		return trusted ? .authorized : .notAuthorized
	}

	static func selection(
		atAppKitScreenPoint point: CGPoint,
		excludingProcessIdentifiers: Set<pid_t>
	) throws -> ExternalWindowSelection {
		guard permissionStatus(prompt: false) == .authorized else {
			throw ManagedExternalWindowError.accessibilityPermissionRequired
		}
		let accessibilityPoint: CGPoint = try accessibilityPoint(fromAppKit: point)
		guard let identity: ExternalWindowIdentity = externalWindowAtPoint(
			accessibilityPoint,
			windows: currentSpaceWindows(),
			excludingProcessIdentifiers: excludingProcessIdentifiers
		) else {
			throw ManagedExternalWindowError.windowAtPointUnavailable
		}
		return try selection(identity: identity)
	}

	static func selection(identity: ExternalWindowIdentity) throws -> ExternalWindowSelection {
		guard identity.processIdentifier > 0, identity.windowID != kCGNullWindowID else {
			throw ManagedExternalWindowError.invalidIdentity(identity)
		}
		let applicationElement = AXUIElementCreateApplication(identity.processIdentifier)
		AXUIElementSetMessagingTimeout(applicationElement, 0.75)
		let applicationWindows: [AXUIElement] = try windows(of: applicationElement)
		let identifiers: [CGWindowID?] = applicationWindows.map {
			try? windowID(of: $0, processIdentifier: identity.processIdentifier)
		}
		guard let index: Int = externalWindowUniqueIndex(
			ofWindowID: identity.windowID,
			in: identifiers
		) else {
			throw ManagedExternalWindowError.windowElementNotFound(identity)
		}
		guard isOnCurrentSpace(identity) else {
			throw ManagedExternalWindowError.windowNotOnCurrentSpace(identity)
		}
		return try makeSelection(
			applicationElement: applicationElement,
			windowElement: applicationWindows[index],
			identity: identity
		)
	}

	static func validateCurrentSpace(
		identity: ExternalWindowIdentity,
		windowElement: AXUIElement
	) throws {
		try validateElement(identity: identity, windowElement: windowElement)
		guard isOnCurrentSpace(identity) else {
			throw ManagedExternalWindowError.windowNotOnCurrentSpace(identity)
		}
	}

	static func validateRegardlessOfSpace(
		identity: ExternalWindowIdentity,
		windowElement: AXUIElement
	) throws {
		try validateElement(identity: identity, windowElement: windowElement)
		// A window on another Space keeps both its ID and its owning process in
		// the window server's list, so identity stays verifiable off-Space.
		let ids: [NSNumber] = [NSNumber(value: identity.windowID)]
		guard let descriptions = CGWindowListCreateDescriptionFromArray(ids as CFArray)
			as? [[String: Any]],
			descriptions.count == 1,
			let description = descriptions.first,
			let ownerPID = description[kCGWindowOwnerPID as String] as? NSNumber,
			ownerPID.int32Value == identity.processIdentifier,
			let layer = description[kCGWindowLayer as String] as? NSNumber,
			layer.intValue == 0
		else {
			throw ManagedExternalWindowError.windowUnavailable(identity)
		}
	}

	static func isOnCurrentSpace(_ identity: ExternalWindowIdentity) -> Bool {
		currentSpaceWindows(processIdentifier: identity.processIdentifier).contains {
			$0.identity == identity && $0.layer == 0 && $0.isOnscreen
				&& $0.ownerIsRegularApplication
		}
	}

	static func snapshot(
		identity: ExternalWindowIdentity,
		windowElement: AXUIElement
	) throws -> ManagedExternalWindowSnapshot {
		try validateElement(identity: identity, windowElement: windowElement)
		return .init(
			identity: identity,
			applicationName: NSRunningApplication(
				processIdentifier: identity.processIdentifier
			)?.localizedName ?? "Application",
			title: stringAttribute(kAXTitleAttribute as CFString, of: windowElement)
				?? "Window",
			appKitScreenFrame: try appKitFrame(
				fromAccessibility: accessibilityFrame(of: windowElement)
			),
			isMinimized: try boolAttribute(
				kAXMinimizedAttribute as CFString,
				of: windowElement
			)
		)
	}

	static func requireManageable(_ selection: ExternalWindowSelection) throws {
		let element: AXUIElement = selection.windowElement
		guard stringAttribute(kAXRoleAttribute as CFString, of: element) == kAXWindowRole,
			stringAttribute(kAXSubroleAttribute as CFString, of: element)
				== kAXStandardWindowSubrole
		else { throw ManagedExternalWindowError.windowNotStandard }
		guard try !boolAttribute(kAXMinimizedAttribute as CFString, of: element) else {
			throw ManagedExternalWindowError.windowIsMinimized
		}
		if (try? boolAttribute("AXFullScreen" as CFString, of: element)) == true {
			throw ManagedExternalWindowError.windowIsFullScreen
		}
		try requireSettable(
			kAXPositionAttribute as CFString,
			on: element,
			error: .windowCannotMove
		)
		try requireSettable(
			kAXSizeAttribute as CFString,
			on: element,
			error: .windowCannotResize
		)
	}

	static func accessibilityFrame(of element: AXUIElement) throws -> CGRect {
		.init(
			origin: try pointAttribute(kAXPositionAttribute as CFString, of: element),
			size: try sizeAttribute(kAXSizeAttribute as CFString, of: element)
		)
	}

	static func accessibilityFrame(fromAppKit frame: CGRect) throws -> CGRect {
		guard let screenFrame = NSScreen.screens.first?.frame else {
			throw ManagedExternalWindowError.noScreens
		}
		return managedExternalWindowAccessibilityFrame(
			fromAppKitScreenFrame: frame,
			menuBarScreenFrame: screenFrame
		)
	}

	static func appKitFrame(fromAccessibility frame: CGRect) throws -> CGRect {
		guard let screenFrame = NSScreen.screens.first?.frame else {
			throw ManagedExternalWindowError.noScreens
		}
		return managedExternalWindowAppKitScreenFrame(
			fromAccessibilityFrame: frame,
			menuBarScreenFrame: screenFrame
		)
	}

	static func writeFrame(_ frame: CGRect, to element: AXUIElement) throws {
		guard frame.isValidManagedExternalWindowFrame else {
			throw ManagedExternalWindowError.invalidFrame(frame)
		}
		var size: CGSize = frame.size
		guard let sizeValue = AXValueCreate(.cgSize, &size) else {
			throw ManagedExternalWindowError.invalidFrame(frame)
		}
		try setAttribute(
			kAXSizeAttribute as CFString,
			value: sizeValue,
			on: element,
			operation: "resize external window"
		)
		var position: CGPoint = frame.origin
		guard let positionValue = AXValueCreate(.cgPoint, &position) else {
			throw ManagedExternalWindowError.invalidFrame(frame)
		}
		try setAttribute(
			kAXPositionAttribute as CFString,
			value: positionValue,
			on: element,
			operation: "move external window"
		)
	}

	static func stringAttribute(_ attribute: CFString, of element: AXUIElement) -> String? {
		var raw: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else {
			return nil
		}
		return raw as? String
	}

	static func boolAttribute(_ attribute: CFString, of element: AXUIElement) throws -> Bool {
		var raw: CFTypeRef?
		let error = AXUIElementCopyAttributeValue(element, attribute, &raw)
		guard error == .success, let value = raw as? Bool else {
			throw ManagedExternalWindowError.accessibilityOperationFailed(
				operation: "read \(attribute)",
				code: error == .success ? .failure : error
			)
		}
		return value
	}

	static func setAttribute(
		_ attribute: CFString,
		value: CFTypeRef,
		on element: AXUIElement,
		operation: String
	) throws {
		let error = AXUIElementSetAttributeValue(element, attribute, value)
		guard error == .success else {
			throw ManagedExternalWindowError.accessibilityOperationFailed(
				operation: operation,
				code: error
			)
		}
	}

	static func setBoolAttribute(
		_ attribute: CFString,
		value: Bool,
		on element: AXUIElement,
		operation: String
	) throws {
		try setAttribute(
			attribute,
			value: value ? kCFBooleanTrue : kCFBooleanFalse,
			on: element,
			operation: operation
		)
	}

	private static func makeSelection(
		applicationElement: AXUIElement,
		windowElement: AXUIElement,
		identity: ExternalWindowIdentity
	) throws -> ExternalWindowSelection {
		let frame: CGRect = try accessibilityFrame(of: windowElement)
		let minimized: Bool = try boolAttribute(
			kAXMinimizedAttribute as CFString,
			of: windowElement
		)
		let selection = ExternalWindowSelection(
			identity: identity,
			applicationElement: applicationElement,
			windowElement: windowElement,
			initialSnapshot: try snapshot(
				identity: identity,
				windowElement: windowElement
			),
			originalAccessibilityFrame: frame,
			originalMinimizedState: minimized
		)
		try requireManageable(selection)
		return selection
	}

	/// The exact identity of an Accessibility window, straight from the window
	/// server. Teaser fails closed when macOS refuses it; it never falls back to
	/// guessing a window from its frame.
	static func windowID(
		of element: AXUIElement,
		processIdentifier: pid_t
	) throws -> CGWindowID {
		var windowID: CGWindowID = kCGNullWindowID
		let error: AXError = _AXUIElementGetWindow(element, &windowID)
		guard error == .success, windowID != kCGNullWindowID else {
			throw ManagedExternalWindowError.windowIdentifierUnavailable(
				processIdentifier: processIdentifier,
				code: error
			)
		}
		return windowID
	}

	static func currentSpaceWindows(
		processIdentifier: pid_t? = nil
	) -> [ExternalWindowCurrentSpaceWindow] {
		guard let info = CGWindowListCopyWindowInfo(
			[.optionOnScreenOnly, .excludeDesktopElements],
			kCGNullWindowID
		) as? [[String: Any]] else { return [] }
		var regularOwners: [pid_t: Bool] = [:]
		return info.compactMap { entry in
			guard let ownerPID = entry[kCGWindowOwnerPID as String] as? NSNumber,
				(processIdentifier == nil || ownerPID.int32Value == processIdentifier),
				let windowID = entry[kCGWindowNumber as String] as? NSNumber,
				let layer = entry[kCGWindowLayer as String] as? NSNumber,
				let onscreen = entry[kCGWindowIsOnscreen as String] as? NSNumber,
				let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
				let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
			else { return nil }
			let owner: pid_t = ownerPID.int32Value
			let isRegular: Bool
			if let cached: Bool = regularOwners[owner] {
				isRegular = cached
			} else {
				isRegular = NSRunningApplication(processIdentifier: owner)?
					.activationPolicy == .regular
				regularOwners[owner] = isRegular
			}
			return .init(
				identity: .init(
					processIdentifier: owner,
					windowID: CGWindowID(windowID.uint32Value)
				),
				layer: layer.intValue,
				isOnscreen: onscreen.boolValue,
				ownerIsRegularApplication: isRegular,
				accessibilityFrame: frame
			)
		}
	}

	static func validateElement(
		identity: ExternalWindowIdentity,
		windowElement: AXUIElement
	) throws {
		var processIdentifier: pid_t = 0
		guard AXUIElementGetPid(windowElement, &processIdentifier) == .success,
			processIdentifier == identity.processIdentifier,
			stringAttribute(kAXRoleAttribute as CFString, of: windowElement)
				== kAXWindowRole,
			(try? windowID(
				of: windowElement,
				processIdentifier: identity.processIdentifier
			)) == identity.windowID
		else { throw ManagedExternalWindowError.windowUnavailable(identity) }
	}

	private static func accessibilityPoint(fromAppKit point: CGPoint) throws -> CGPoint {
		guard let screenFrame = NSScreen.screens.first?.frame else {
			throw ManagedExternalWindowError.noScreens
		}
		return managedExternalWindowAccessibilityPoint(
			fromAppKitScreenPoint: point,
			menuBarScreenFrame: screenFrame
		)
	}

	private static func windows(of application: AXUIElement) throws -> [AXUIElement] {
		var raw: CFTypeRef?
		let error = AXUIElementCopyAttributeValue(
			application,
			kAXWindowsAttribute as CFString,
			&raw
		)
		guard error == .success else {
			throw ManagedExternalWindowError.accessibilityOperationFailed(
				operation: "enumerate external windows",
				code: error
			)
		}
		return raw as? [AXUIElement] ?? []
	}

	private static func requireSettable(
		_ attribute: CFString,
		on element: AXUIElement,
		error unavailableError: ManagedExternalWindowError
	) throws {
		var settable: DarwinBoolean = false
		let result = AXUIElementIsAttributeSettable(element, attribute, &settable)
		guard result == .success else {
			throw ManagedExternalWindowError.accessibilityOperationFailed(
				operation: "test \(attribute) writability",
				code: result
			)
		}
		guard settable.boolValue else { throw unavailableError }
	}

	private static func pointAttribute(
		_ attribute: CFString,
		of element: AXUIElement
	) throws -> CGPoint {
		let value: AXValue = try axValueAttribute(attribute, of: element)
		guard AXValueGetType(value) == .cgPoint else {
			throw ManagedExternalWindowError.accessibilityOperationFailed(
				operation: "decode \(attribute)",
				code: .failure
			)
		}
		var point: CGPoint = .zero
		guard AXValueGetValue(value, .cgPoint, &point) else {
			throw ManagedExternalWindowError.accessibilityOperationFailed(
				operation: "decode \(attribute)",
				code: .failure
			)
		}
		return point
	}

	private static func sizeAttribute(
		_ attribute: CFString,
		of element: AXUIElement
	) throws -> CGSize {
		let value: AXValue = try axValueAttribute(attribute, of: element)
		guard AXValueGetType(value) == .cgSize else {
			throw ManagedExternalWindowError.accessibilityOperationFailed(
				operation: "decode \(attribute)",
				code: .failure
			)
		}
		var size: CGSize = .zero
		guard AXValueGetValue(value, .cgSize, &size) else {
			throw ManagedExternalWindowError.accessibilityOperationFailed(
				operation: "decode \(attribute)",
				code: .failure
			)
		}
		return size
	}

	private static func axValueAttribute(
		_ attribute: CFString,
		of element: AXUIElement
	) throws -> AXValue {
		var raw: CFTypeRef?
		let error = AXUIElementCopyAttributeValue(element, attribute, &raw)
		guard error == .success,
			let raw,
			CFGetTypeID(raw) == AXValueGetTypeID()
		else {
			throw ManagedExternalWindowError.accessibilityOperationFailed(
				operation: "read \(attribute)",
				code: error == .success ? .failure : error
			)
		}
		return unsafeDowncast(raw, to: AXValue.self)
	}
}

@MainActor
final class ManagedExternalWindow {
	private final class ObserverRelay: @unchecked Sendable {
		private weak var owner: ManagedExternalWindow?
		private let generation: UInt

		init(owner: ManagedExternalWindow, generation: UInt) {
			self.owner = owner
			self.generation = generation
		}

		func receive(_ event: ManagedExternalWindowEvent) {
			let eventGeneration: UInt = generation
			Task { @MainActor [weak owner] in
				owner?.receiveObservedEvent(event, generation: eventGeneration)
			}
		}
	}

	private final class Observation: @unchecked Sendable {
		let observer: AXObserver
		let windowElement: AXUIElement
		let notifications: [CFString]
		let runLoop: CFRunLoop
		let relay: ObserverRelay
		private var isActive: Bool = true

		init(
			observer: AXObserver,
			windowElement: AXUIElement,
			notifications: [CFString],
			runLoop: CFRunLoop,
			relay: ObserverRelay
		) {
			self.observer = observer
			self.windowElement = windowElement
			self.notifications = notifications
			self.runLoop = runLoop
			self.relay = relay
		}

		func invalidate() {
			guard isActive else { return }
			isActive = false
			for notification: CFString in notifications {
				AXObserverRemoveNotification(observer, windowElement, notification)
			}
			CFRunLoopRemoveSource(
				runLoop,
				AXObserverGetRunLoopSource(observer),
				.commonModes
			)
		}

		deinit { invalidate() }
	}

	private struct Binding {
		let selection: ExternalWindowSelection
		let originalAccessibilityFrame: CGRect
		let originalMinimizedState: Bool
		var lastAppliedAccessibilityFrame: CGRect?
		var lastAppliedMinimizedState: Bool?
	}

	var onEvent: ManagedExternalWindowEventHandler?
	var onApplyError: ManagedExternalWindowApplyErrorHandler?
	private(set) var identity: ExternalWindowIdentity?

	private var binding: Binding?
	private var observation: Observation?
	private var observationGeneration: UInt = 0
	private var activeObservationGeneration: UInt?
	private var pendingObservedEvent: ManagedExternalWindowEvent?
	private var observedEventTask: Task<Void, Never>?
	private var pendingApplyFrame: CGRect?
	private var applyTask: Task<Void, Never>?

	init(
		onEvent: ManagedExternalWindowEventHandler? = nil,
		onApplyError: ManagedExternalWindowApplyErrorHandler? = nil
	) {
		self.onEvent = onEvent
		self.onApplyError = onApplyError
	}

	deinit {
		observation?.invalidate()
		observedEventTask?.cancel()
		applyTask?.cancel()
	}

	static func permissionStatus(prompt: Bool) -> ExternalWindowPermissionStatus {
		ExternalWindowSystem.permissionStatus(prompt: prompt)
	}

	static func selectWindow(
		atAppKitScreenPoint point: CGPoint,
		excludingProcessIdentifiers: Set<pid_t> = [getpid()]
	) throws -> ExternalWindowSelection {
		try ExternalWindowSystem.selection(
			atAppKitScreenPoint: point,
			excludingProcessIdentifiers: excludingProcessIdentifiers
		)
	}

	static func selectWindow(
		identity: ExternalWindowIdentity
	) throws -> ExternalWindowSelection {
		try ExternalWindowSystem.selection(identity: identity)
	}

	static func visibleWindowIdentities(processIdentifier: pid_t) -> [ExternalWindowIdentity] {
		ExternalWindowSystem.currentSpaceWindows(processIdentifier: processIdentifier)
			.filter { $0.layer == 0 && $0.isOnscreen && $0.ownerIsRegularApplication }
			.map(\.identity)
	}

	/// Whether macOS runs this process as an ordinary application. Accessory and
	/// prohibited processes own no window a user can drag into a Panel.
	static func isRegularApplication(processIdentifier: pid_t) -> Bool {
		NSRunningApplication(processIdentifier: processIdentifier)?
			.activationPolicy == .regular
	}

	@discardableResult
	func bind(selection: ExternalWindowSelection) throws -> ManagedExternalWindowSnapshot {
		guard Self.permissionStatus(prompt: false) == .authorized else {
			throw ManagedExternalWindowError.accessibilityPermissionRequired
		}
		guard binding == nil else { throw ManagedExternalWindowError.alreadyBound }
		try ExternalWindowSystem.validateCurrentSpace(
			identity: selection.identity,
			windowElement: selection.windowElement
		)
		try ExternalWindowSystem.requireManageable(selection)
		let newObservation: Observation = try makeObservation(selection: selection)
		binding = .init(
			selection: selection,
			originalAccessibilityFrame: selection.originalAccessibilityFrame,
			originalMinimizedState: selection.originalMinimizedState,
			lastAppliedAccessibilityFrame: nil,
			lastAppliedMinimizedState: nil
		)
		identity = selection.identity
		observation = newObservation
		activeObservationGeneration = observationGeneration
		return try snapshot()
	}

	@discardableResult
	func bind(identity: ExternalWindowIdentity) throws -> ManagedExternalWindowSnapshot {
		try bind(selection: Self.selectWindow(identity: identity))
	}

	func snapshot() throws -> ManagedExternalWindowSnapshot {
		guard let binding else {
			throw ManagedExternalWindowError.windowUnavailable(nil)
		}
		return try ExternalWindowSystem.snapshot(
			identity: binding.selection.identity,
			windowElement: binding.selection.windowElement
		)
	}

	@discardableResult
	func apply(
		appKitScreenFrame requestedFrame: CGRect
	) throws -> ManagedExternalWindowSnapshot {
		cancelPendingApply()
		guard requestedFrame.isValidManagedExternalWindowFrame else {
			throw ManagedExternalWindowError.invalidFrame(requestedFrame)
		}
		guard var binding else {
			throw ManagedExternalWindowError.windowUnavailable(nil)
		}
		try requireCurrentSpace(binding)
		let targetFrame: CGRect = try ExternalWindowSystem.accessibilityFrame(
			fromAppKit: requestedFrame
		)
		let currentFrame: CGRect = try ExternalWindowSystem.accessibilityFrame(
			of: binding.selection.windowElement
		)
		if managedExternalWindowFramesAreApproximatelyEqual(currentFrame, targetFrame) {
			binding.lastAppliedAccessibilityFrame = currentFrame
			self.binding = binding
			return try snapshot()
		}
		do {
			try ExternalWindowSystem.writeFrame(
				targetFrame,
				to: binding.selection.windowElement
			)
			let appliedFrame: CGRect = try ExternalWindowSystem.accessibilityFrame(
				of: binding.selection.windowElement
			)
			guard managedExternalWindowFramesAreApproximatelyEqual(
				appliedFrame,
				targetFrame
			) else {
				throw ManagedExternalWindowError.windowCannotFit(
					requested: requestedFrame,
					actual: try ExternalWindowSystem.appKitFrame(
						fromAccessibility: appliedFrame
					)
				)
			}
			binding.lastAppliedAccessibilityFrame = appliedFrame
			self.binding = binding
		} catch {
			try? ExternalWindowSystem.writeFrame(
				currentFrame,
				to: binding.selection.windowElement
			)
			throw error
		}
		return try snapshot()
	}

	func applyCoalesced(appKitScreenFrame requestedFrame: CGRect) {
		guard requestedFrame.isValidManagedExternalWindowFrame else {
			onApplyError?(.invalidFrame(requestedFrame))
			return
		}
		pendingApplyFrame = requestedFrame
		schedulePendingApplyIfNeeded()
	}

	@discardableResult
	func restore(
		snapshot: ManagedExternalWindowSnapshot
	) throws -> ManagedExternalWindowSnapshot {
		guard let identity else {
			throw ManagedExternalWindowError.windowUnavailable(nil)
		}
		guard snapshot.identity == identity else {
			throw ManagedExternalWindowError.snapshotIdentityMismatch(
				expected: identity,
				actual: snapshot.identity
			)
		}
		let previous: ManagedExternalWindowSnapshot = try self.snapshot()
		do {
			if previous.isMinimized { try setMinimized(false) }
			_ = try apply(appKitScreenFrame: snapshot.appKitScreenFrame)
			try setMinimized(snapshot.isMinimized)
			return try self.snapshot()
		} catch {
			if (try? self.snapshot().isMinimized) == true {
				try? setMinimized(false)
			}
			_ = try? apply(appKitScreenFrame: previous.appKitScreenFrame)
			try? setMinimized(previous.isMinimized)
			throw error
		}
	}

	func raise() throws {
		guard let binding else {
			throw ManagedExternalWindowError.windowUnavailable(nil)
		}
		try requireCurrentSpace(binding)
		let error: AXError = AXUIElementPerformAction(
			binding.selection.windowElement,
			kAXRaiseAction as CFString
		)
		guard error == .success else {
			throw ManagedExternalWindowError.accessibilityOperationFailed(
				operation: "raise external window",
				code: error
			)
		}
	}

	func focusAndRaise() throws {
		guard let binding else {
			throw ManagedExternalWindowError.windowUnavailable(nil)
		}
		let isMinimized: Bool = try ExternalWindowSystem.boolAttribute(
			kAXMinimizedAttribute as CFString,
			of: binding.selection.windowElement
		)
		if isMinimized { try setMinimized(false) }
		try requireCurrentSpace(binding)
		_ = NSRunningApplication(
			processIdentifier: binding.selection.identity.processIdentifier
		)?.activate(options: [])
		try ExternalWindowSystem.setAttribute(
			kAXFocusedWindowAttribute as CFString,
			value: binding.selection.windowElement,
			on: binding.selection.applicationElement,
			operation: "focus external window"
		)
		try raise()
	}

	func setMinimized(_ minimized: Bool) throws {
		guard var binding else {
			throw ManagedExternalWindowError.windowUnavailable(nil)
		}
		if minimized {
			try requireCurrentSpace(binding)
		} else {
			try ExternalWindowSystem.validateRegardlessOfSpace(
				identity: binding.selection.identity,
				windowElement: binding.selection.windowElement
			)
		}
		let current: Bool = try ExternalWindowSystem.boolAttribute(
			kAXMinimizedAttribute as CFString,
			of: binding.selection.windowElement
		)
		guard current != minimized else {
			binding.lastAppliedMinimizedState = current
			self.binding = binding
			return
		}
		var settable: DarwinBoolean = false
		let result = AXUIElementIsAttributeSettable(
			binding.selection.windowElement,
			kAXMinimizedAttribute as CFString,
			&settable
		)
		guard result == .success, settable.boolValue else {
			throw ManagedExternalWindowError.windowCannotMinimize
		}
		try ExternalWindowSystem.setBoolAttribute(
			kAXMinimizedAttribute as CFString,
			value: minimized,
			on: binding.selection.windowElement,
			operation: minimized ? "minimize external window" : "restore external window"
		)
		guard try ExternalWindowSystem.boolAttribute(
			kAXMinimizedAttribute as CFString,
			of: binding.selection.windowElement
		) == minimized else {
			throw ManagedExternalWindowError.windowCannotMinimize
		}
		binding.lastAppliedMinimizedState = minimized
		self.binding = binding
	}

	@discardableResult
	func release(restoringOriginalFrame: Bool) -> Bool {
		cancelPendingApply()
		guard let binding else {
			clearBinding()
			return true
		}
		guard restoringOriginalFrame else {
			clearBinding()
			return true
		}
		do {
			try ExternalWindowSystem.validateRegardlessOfSpace(
				identity: binding.selection.identity,
				windowElement: binding.selection.windowElement
			)
			if let appliedFrame = binding.lastAppliedAccessibilityFrame {
				let currentFrame = try ExternalWindowSystem.accessibilityFrame(
					of: binding.selection.windowElement
				)
				if managedExternalWindowFramesAreApproximatelyEqual(
					currentFrame,
					appliedFrame
				) {
					try ExternalWindowSystem.writeFrame(
						binding.originalAccessibilityFrame,
						to: binding.selection.windowElement
					)
					let restoredFrame = try ExternalWindowSystem.accessibilityFrame(
						of: binding.selection.windowElement
					)
					guard managedExternalWindowFramesAreApproximatelyEqual(
						restoredFrame,
						binding.originalAccessibilityFrame
					) else {
						throw ManagedExternalWindowError.windowCannotFit(
							requested: try ExternalWindowSystem.appKitFrame(
								fromAccessibility: binding.originalAccessibilityFrame
							),
							actual: try ExternalWindowSystem.appKitFrame(
								fromAccessibility: restoredFrame
							)
						)
					}
				}
			}
			if let appliedMinimized = binding.lastAppliedMinimizedState {
				let currentMinimized = try ExternalWindowSystem.boolAttribute(
					kAXMinimizedAttribute as CFString,
					of: binding.selection.windowElement
				)
				if currentMinimized == appliedMinimized,
					currentMinimized != binding.originalMinimizedState
				{
					try ExternalWindowSystem.setBoolAttribute(
						kAXMinimizedAttribute as CFString,
						value: binding.originalMinimizedState,
						on: binding.selection.windowElement,
						operation: "restore external window minimized state"
					)
					guard try ExternalWindowSystem.boolAttribute(
						kAXMinimizedAttribute as CFString,
						of: binding.selection.windowElement
					) == binding.originalMinimizedState else {
						throw ManagedExternalWindowError.windowCannotMinimize
					}
				}
			}
			clearBinding()
			return true
		} catch {
			return false
		}
	}

	private func schedulePendingApplyIfNeeded() {
		guard applyTask == nil else { return }
		applyTask = Task { @MainActor [weak self] in
			await Task.yield()
			guard !Task.isCancelled else { return }
			guard let self else { return }
			self.applyTask = nil
			guard let frame = self.pendingApplyFrame else { return }
			self.pendingApplyFrame = nil
			do {
				_ = try self.apply(appKitScreenFrame: frame)
			} catch let error as ManagedExternalWindowError {
				self.onApplyError?(error)
			} catch {
				self.onApplyError?(.windowUnavailable(self.identity))
			}
			if self.pendingApplyFrame != nil {
				self.schedulePendingApplyIfNeeded()
			}
		}
	}

	private func requireCurrentSpace(_ binding: Binding) throws {
		try ExternalWindowSystem.validateCurrentSpace(
			identity: binding.selection.identity,
			windowElement: binding.selection.windowElement
		)
	}

	private func makeObservation(selection: ExternalWindowSelection) throws -> Observation {
		observationGeneration &+= 1
		let relay = ObserverRelay(owner: self, generation: observationGeneration)
		var createdObserver: AXObserver?
		let createError = AXObserverCreate(
			selection.identity.processIdentifier,
			{ _, _, notification, context in
				guard let context,
					let event = managedExternalWindowEvent(
						forAccessibilityNotification: notification as String
					)
				else { return }
				Unmanaged<ObserverRelay>
					.fromOpaque(context)
					.takeUnretainedValue()
					.receive(event)
			},
			&createdObserver
		)
		guard createError == .success, let observer = createdObserver else {
			throw ManagedExternalWindowError.accessibilityOperationFailed(
				operation: "create external window observer",
				code: createError
			)
		}
		let notifications: [CFString] = [
			kAXMovedNotification as CFString,
			kAXResizedNotification as CFString,
			kAXUIElementDestroyedNotification as CFString,
		]
		var installed: [CFString] = []
		for notification in notifications {
			let error = AXObserverAddNotification(
				observer,
				selection.windowElement,
				notification,
				Unmanaged.passUnretained(relay).toOpaque()
			)
			guard error == .success else {
				for existing in installed {
					AXObserverRemoveNotification(observer, selection.windowElement, existing)
				}
				throw ManagedExternalWindowError.accessibilityOperationFailed(
					operation: "observe external window notification \(notification)",
					code: error
				)
			}
			installed.append(notification)
		}
		let runLoop: CFRunLoop = CFRunLoopGetMain()
		CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .commonModes)
		return .init(
			observer: observer,
			windowElement: selection.windowElement,
			notifications: notifications,
			runLoop: runLoop,
			relay: relay
		)
	}

	private func receiveObservedEvent(
		_ event: ManagedExternalWindowEvent,
		generation: UInt
	) {
		guard activeObservationGeneration == generation else { return }
		if event == .destroyed {
			clearBinding()
			onEvent?(.destroyed)
			return
		}
		if let binding,
			let appliedFrame = binding.lastAppliedAccessibilityFrame,
			let currentFrame = try? ExternalWindowSystem.accessibilityFrame(
				of: binding.selection.windowElement
			),
			managedExternalWindowFramesAreApproximatelyEqual(currentFrame, appliedFrame)
		{
			return
		}
		pendingObservedEvent = event == .resized ? .resized : (pendingObservedEvent ?? .moved)
		guard observedEventTask == nil else { return }
		observedEventTask = Task { @MainActor [weak self] in
			await Task.yield()
			guard let self else { return }
			self.observedEventTask = nil
			guard let event = self.pendingObservedEvent else { return }
			self.pendingObservedEvent = nil
			self.onEvent?(event)
		}
	}

	private func cancelPendingApply() {
		applyTask?.cancel()
		applyTask = nil
		pendingApplyFrame = nil
	}

	private func clearBinding() {
		cancelPendingApply()
		observedEventTask?.cancel()
		observedEventTask = nil
		pendingObservedEvent = nil
		activeObservationGeneration = nil
		observation?.invalidate()
		observation = nil
		binding = nil
		identity = nil
	}
}

extension ManagedExternalWindow: ExternalWindowLease {
	/// A lease binds live Accessibility references only. A substitute handle is
	/// rejected here instead of being adapted into a usable AX object.
	@discardableResult
	func bind(handle: any ExternalWindowHandle) throws -> ManagedExternalWindowSnapshot {
		guard let selection = handle as? ExternalWindowSelection else {
			throw ManagedExternalWindowError.windowUnavailable(handle.identity)
		}
		return try bind(selection: selection)
	}
}

/// The production `ExternalWindowService`. Accessibility objects stay inside this
/// file; the boundary carries only identities, snapshots, and opaque handles.
@MainActor
final class SystemExternalWindowService: ExternalWindowService {
	static let shared: SystemExternalWindowService = .init()

	func permissionStatus(prompt: Bool) -> ExternalWindowPermissionStatus {
		ExternalWindowSystem.permissionStatus(prompt: prompt)
	}

	func selectWindow(
		atAppKitScreenPoint point: CGPoint,
		excludingProcessIdentifiers: Set<pid_t>
	) throws -> any ExternalWindowHandle {
		try ExternalWindowSystem.selection(
			atAppKitScreenPoint: point,
			excludingProcessIdentifiers: excludingProcessIdentifiers
		)
	}

	func selectWindow(identity: ExternalWindowIdentity) throws -> any ExternalWindowHandle {
		try ExternalWindowSystem.selection(identity: identity)
	}

	func validateIdentity(of handle: any ExternalWindowHandle) throws {
		let selection: ExternalWindowSelection = try Self.selection(handle)
		try ExternalWindowSystem.validateElement(
			identity: selection.identity,
			windowElement: selection.windowElement
		)
	}

	func validateCurrentSpace(of handle: any ExternalWindowHandle) throws {
		let selection: ExternalWindowSelection = try Self.selection(handle)
		try ExternalWindowSystem.validateCurrentSpace(
			identity: selection.identity,
			windowElement: selection.windowElement
		)
	}

	func snapshot(
		of handle: any ExternalWindowHandle
	) throws -> ManagedExternalWindowSnapshot {
		let selection: ExternalWindowSelection = try Self.selection(handle)
		return try ExternalWindowSystem.snapshot(
			identity: selection.identity,
			windowElement: selection.windowElement
		)
	}

	func bundleIdentifier(forProcessIdentifier processIdentifier: pid_t) -> String? {
		NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier
	}

	func makeLease(
		onEvent: @escaping ManagedExternalWindowEventHandler,
		onApplyError: @escaping ManagedExternalWindowApplyErrorHandler
	) -> any ExternalWindowLease {
		ManagedExternalWindow(onEvent: onEvent, onApplyError: onApplyError)
	}

	private static func selection(
		_ handle: any ExternalWindowHandle
	) throws -> ExternalWindowSelection {
		guard let selection = handle as? ExternalWindowSelection else {
			throw ManagedExternalWindowError.windowUnavailable(handle.identity)
		}
		return selection
	}
}

@MainActor
final class WindowDragObserver {
	private struct PendingDrag {
		let handle: any ExternalWindowHandle
		let initialSample: ExternalWindowDragSample
		var currentSample: ExternalWindowDragSample
		var isQualified: Bool
	}

	/// Resampling floor for a held drag; the production pointer source delivers
	/// button-state samples at the same rate.
	private static let samplingInterval: TimeInterval = 1.0 / 30.0
	/// A rejected candidate is reported only once the press becomes a real drag.
	private static let diagnosticMovementThreshold: CGFloat = 10

	var onEvent: ExternalWindowDragEventHandler?
	var onDiagnostic: (@MainActor @Sendable (String) -> Void)?
	let qualificationConfiguration: ExternalWindowDragQualificationConfiguration
	let excludedProcessIdentifiers: Set<pid_t>
	private let service: any ExternalWindowService
	private let clock: any ExternalWindowClock
	private let pointerSource: any ExternalWindowPointerSource
	private var isObserving: Bool = false
	private var pendingDrag: PendingDrag?
	/// One held press. Its rejection reason lives and dies with it, so a later
	/// delivery cannot report a press that has already ended.
	private struct PressState {
		let location: CGPoint
		var selectionFailure: String?
	}

	private var press: PressState?
	private var lastSampleTime: TimeInterval?

	init(
		service: any ExternalWindowService,
		clock: any ExternalWindowClock,
		pointerSource: any ExternalWindowPointerSource,
		qualificationConfiguration: ExternalWindowDragQualificationConfiguration = .init(),
		excludedProcessIdentifiers: Set<pid_t> = [getpid()],
		onEvent: ExternalWindowDragEventHandler? = nil
	) {
		self.service = service
		self.clock = clock
		self.pointerSource = pointerSource
		self.qualificationConfiguration = qualificationConfiguration
		self.excludedProcessIdentifiers = excludedProcessIdentifiers
		self.onEvent = onEvent
	}

	convenience init(
		qualificationConfiguration: ExternalWindowDragQualificationConfiguration = .init(),
		excludedProcessIdentifiers: Set<pid_t> = [getpid()],
		onEvent: ExternalWindowDragEventHandler? = nil
	) {
		self.init(
			service: SystemExternalWindowService.shared,
			clock: SystemExternalWindowClock(),
			pointerSource: SystemExternalWindowPointerSource(),
			qualificationConfiguration: qualificationConfiguration,
			excludedProcessIdentifiers: excludedProcessIdentifiers,
			onEvent: onEvent
		)
	}

	func start(promptForAccessibility: Bool = false) throws {
		guard !isObserving else { return }
		guard service.permissionStatus(prompt: promptForAccessibility) == .authorized else {
			throw ManagedExternalWindowError.accessibilityPermissionRequired
		}
		try pointerSource.start { [weak self] event in
			self?.receive(event)
		}
		isObserving = true
		ExternalWindowDiagnostics.logger.notice("observer-started")
	}

	func stop() {
		if isObserving { ExternalWindowDiagnostics.logger.notice("observer-stopped") }
		isObserving = false
		pointerSource.stop()
		press = nil
		lastSampleTime = nil
		if let pendingDrag, pendingDrag.isQualified {
			onEvent?(
				.cancelled(
					identity: pendingDrag.handle.identity,
					reason: .observerStopped
				)
			)
		}
		pendingDrag = nil
	}

	private func receive(_ event: ExternalWindowPointerEvent) {
		switch event {
		case .monitored(let phase, let location):
			receive(phase: phase, appKitScreenLocation: location)
		case .sampled(let isButtonDown, let location):
			if isButtonDown && press == nil {
				receive(phase: .down, appKitScreenLocation: location)
			} else if !isButtonDown && press != nil {
				receive(phase: .up, appKitScreenLocation: location)
			} else if isButtonDown {
				receive(phase: .dragged, appKitScreenLocation: location)
			}
		}
	}

	private func receive(
		phase: ExternalWindowPointerPhase,
		appKitScreenLocation: CGPoint
	) {
		switch phase {
		case .down:
			guard press == nil else { return }
			press = .init(location: appKitScreenLocation)
			beginPendingDrag(at: appKitScreenLocation)
		case .dragged:
			// Only a live press can report a rejection, and only once it has
			// travelled far enough to be a real drag rather than a click.
			if let current: PressState = press,
				let failure: String = current.selectionFailure,
				hypot(
					appKitScreenLocation.x - current.location.x,
					appKitScreenLocation.y - current.location.y
				) >= Self.diagnosticMovementThreshold
			{
				onDiagnostic?(failure)
				press?.selectionFailure = nil
			}
			updatePendingDrag(at: appKitScreenLocation)
		case .up:
			endPendingDrag(at: appKitScreenLocation)
			// The press owned its rejection; releasing retires both together.
			press = nil
		}
	}

	private func beginPendingDrag(at location: CGPoint) {
		lastSampleTime = nil
		pendingDrag = nil
		press?.selectionFailure = nil
		let handle: any ExternalWindowHandle
		do {
			handle = try service.selectWindow(
				atAppKitScreenPoint: location,
				excludingProcessIdentifiers: excludedProcessIdentifiers
			)
		} catch {
			press?.selectionFailure = error.localizedDescription
			// This error type contains geometry/API errors, never window titles
			// or provider document contents. Keep the reason available in logs.
			ExternalWindowDiagnostics.logger.notice("candidate-rejected: \(error.localizedDescription, privacy: .public)")
			return
		}
		let sample = ExternalWindowDragSample(
			mouseAppKitScreenLocation: location,
			windowAppKitScreenFrame: handle.initialSnapshot.appKitScreenFrame
		)
		ExternalWindowDiagnostics.logger.notice("candidate-selected pid=\(handle.identity.processIdentifier, privacy: .public) window=\(handle.identity.windowID, privacy: .public)")
		pendingDrag = .init(
			handle: handle,
			initialSample: sample,
			currentSample: sample,
			isQualified: false
		)
	}

	private func updatePendingDrag(at location: CGPoint) {
		guard var pendingDrag else { return }
		let now: TimeInterval = clock.now
		if let lastSampleTime, now - lastSampleTime < Self.samplingInterval { return }
		lastSampleTime = now
		do {
			try service.validateIdentity(of: pendingDrag.handle)
			let current = try service.snapshot(of: pendingDrag.handle)
			pendingDrag.currentSample = .init(
				mouseAppKitScreenLocation: location,
				windowAppKitScreenFrame: current.appKitScreenFrame
			)
			let dragSnapshot = ExternalWindowDragSnapshot(
				selection: pendingDrag.handle,
				initialSample: pendingDrag.initialSample,
				currentSample: pendingDrag.currentSample
			)
			if pendingDrag.isQualified {
				onEvent?(.changed(dragSnapshot))
			} else if qualifiesExternalWindowDrag(
				initial: pendingDrag.initialSample,
				current: pendingDrag.currentSample,
				configuration: qualificationConfiguration
			) {
				pendingDrag.isQualified = true
				ExternalWindowDiagnostics.logger.notice("drag-qualified pid=\(pendingDrag.handle.identity.processIdentifier, privacy: .public) window=\(pendingDrag.handle.identity.windowID, privacy: .public)")
				onEvent?(.began(dragSnapshot))
			}
			self.pendingDrag = pendingDrag
		} catch {
			ExternalWindowDiagnostics.logger.notice("drag-sample-rejected: \(error.localizedDescription, privacy: .public)")
			onDiagnostic?(error.localizedDescription)
			cancelPendingDrag(reason: .windowUnavailable)
		}
	}

	private func endPendingDrag(at location: CGPoint) {
		lastSampleTime = nil
		updatePendingDrag(at: location)
		guard let pendingDrag else { return }
		defer { self.pendingDrag = nil }
		guard pendingDrag.isQualified else { return }
		do {
			try service.validateCurrentSpace(of: pendingDrag.handle)
			let current = try service.snapshot(of: pendingDrag.handle)
			ExternalWindowDiagnostics.logger.notice("drag-ended pid=\(pendingDrag.handle.identity.processIdentifier, privacy: .public) window=\(pendingDrag.handle.identity.windowID, privacy: .public)")
			onEvent?(
				.ended(
					.init(
						selection: pendingDrag.handle,
						initialSample: pendingDrag.initialSample,
						currentSample: .init(
							mouseAppKitScreenLocation: location,
							windowAppKitScreenFrame: current.appKitScreenFrame
						)
					)
				)
			)
		} catch {
			ExternalWindowDiagnostics.logger.notice("drop-revalidation-rejected: \(error.localizedDescription, privacy: .public)")
			onDiagnostic?(error.localizedDescription)
			onEvent?(
				.cancelled(
					identity: pendingDrag.handle.identity,
					reason: .windowUnavailable
				)
			)
		}
	}

	private func cancelPendingDrag(reason: ExternalWindowDragCancellationReason) {
		guard let pendingDrag else { return }
		self.pendingDrag = nil
		guard pendingDrag.isQualified else { return }
		onEvent?(
			.cancelled(identity: pendingDrag.handle.identity, reason: reason)
		)
	}
}

private extension CGRect {
	var isValidManagedExternalWindowFrame: Bool {
		origin.x.isFinite
			&& origin.y.isFinite
			&& size.width.isFinite
			&& size.height.isFinite
			&& width > 0
			&& height > 0
	}
}
