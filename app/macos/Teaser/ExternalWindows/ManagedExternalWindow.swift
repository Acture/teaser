import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

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
	case ambiguousWindowIdentity(processIdentifier: pid_t)
	case windowUnavailable(ExternalWindowIdentity?)
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
		case .ambiguousWindowIdentity(let processIdentifier):
			return "Accessibility and Core Graphics windows for process \(processIdentifier) cannot be correlated uniquely."
		case .windowUnavailable(let identity):
			guard let identity else { return "The managed external window is unavailable." }
			return "External window \(identity.windowID) from process \(identity.processIdentifier) is unavailable."
		case .windowNotOnCurrentSpace(let identity):
			return "External window \(identity.windowID) is not uniquely visible on the current Space."
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

struct ExternalWindowAccessibilityCandidate: Equatable, Sendable {
	let index: Int
	let processIdentifier: pid_t
	let role: String
	let subrole: String?
	let accessibilityFrame: CGRect?
	let isMinimized: Bool
	let isFullScreen: Bool
}

struct ExternalWindowCurrentSpaceWindow: Equatable, Sendable {
	let identity: ExternalWindowIdentity
	let layer: Int
	let isOnscreen: Bool
	let accessibilityFrame: CGRect
}

func externalWindowCurrentSpaceCorrelations(
	accessibilityCandidates: [ExternalWindowAccessibilityCandidate],
	currentSpaceWindows: [ExternalWindowCurrentSpaceWindow],
	tolerance: CGFloat = 2
) -> [Int: CGWindowID] {
	guard tolerance.isFinite, tolerance >= 0 else { return [:] }
	var byCandidate: [Int: [Int]] = [:]
	var byWindow: [Int: [Int]] = [:]
	for (candidateOffset, candidate) in accessibilityCandidates.enumerated() {
		guard let candidateFrame: CGRect = candidate.accessibilityFrame else { continue }
		for (windowOffset, window) in currentSpaceWindows.enumerated() {
			guard candidate.processIdentifier == window.identity.processIdentifier,
				window.layer == 0,
				window.isOnscreen,
				managedExternalWindowFramesAreApproximatelyEqual(
					candidateFrame,
					window.accessibilityFrame,
					tolerance: tolerance
				)
			else { continue }
			byCandidate[candidateOffset, default: []].append(windowOffset)
			byWindow[windowOffset, default: []].append(candidateOffset)
		}
	}
	var result: [Int: CGWindowID] = [:]
	for (candidateOffset, windowOffsets) in byCandidate {
		guard windowOffsets.count == 1,
			let windowOffset: Int = windowOffsets.first,
			byWindow[windowOffset]?.count == 1
		else { continue }
		result[accessibilityCandidates[candidateOffset].index] =
			currentSpaceWindows[windowOffset].identity.windowID
	}
	return result
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
final class ExternalWindowSelection {
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
	let selection: ExternalWindowSelection
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
		var hitElement: AXUIElement?
		let error: AXError = AXUIElementCopyElementAtPosition(
			AXUIElementCreateSystemWide(),
			Float(accessibilityPoint.x),
			Float(accessibilityPoint.y),
			&hitElement
		)
		guard error == .success, let hitElement else {
			throw ManagedExternalWindowError.windowAtPointUnavailable
		}
		let windowElement: AXUIElement = try enclosingWindow(of: hitElement)
		var processIdentifier: pid_t = 0
		guard AXUIElementGetPid(windowElement, &processIdentifier) == .success,
			processIdentifier > 0,
			!excludingProcessIdentifiers.contains(processIdentifier)
		else {
			throw ManagedExternalWindowError.windowAtPointUnavailable
		}
		let applicationElement: AXUIElement = AXUIElementCreateApplication(processIdentifier)
		AXUIElementSetMessagingTimeout(applicationElement, 0.75)
		let applicationWindows: [AXUIElement] = try windows(of: applicationElement)
		guard let selectedIndex: Int = applicationWindows.firstIndex(where: {
			CFEqual($0, windowElement)
		}) else {
			throw ManagedExternalWindowError.windowAtPointUnavailable
		}
		let cgWindows: [ExternalWindowCurrentSpaceWindow] = currentSpaceWindows(
			processIdentifier: processIdentifier
		)
		let correlations: [Int: CGWindowID] = correlate(
			windows: applicationWindows,
			processIdentifier: processIdentifier,
			currentSpaceWindows: cgWindows
		)
		guard let windowID: CGWindowID = correlations[selectedIndex] else {
			throw ManagedExternalWindowError.ambiguousWindowIdentity(
				processIdentifier: processIdentifier
			)
		}
		guard let frontmostAtPoint = cgWindows.first(where: {
			$0.layer == 0
				&& $0.isOnscreen
				&& $0.accessibilityFrame.contains(accessibilityPoint)
		}),
			frontmostAtPoint.identity.windowID == windowID
		else {
			throw ManagedExternalWindowError.windowAtPointUnavailable
		}
		return try makeSelection(
			applicationElement: applicationElement,
			windowElement: windowElement,
			identity: .init(
				processIdentifier: processIdentifier,
				windowID: windowID
			)
		)
	}

	static func selection(identity: ExternalWindowIdentity) throws -> ExternalWindowSelection {
		guard identity.processIdentifier > 0, identity.windowID != kCGNullWindowID else {
			throw ManagedExternalWindowError.invalidIdentity(identity)
		}
		let applicationElement = AXUIElementCreateApplication(identity.processIdentifier)
		AXUIElementSetMessagingTimeout(applicationElement, 0.75)
		let applicationWindows: [AXUIElement] = try windows(of: applicationElement)
		let correlations: [Int: CGWindowID] = correlate(
			windows: applicationWindows,
			processIdentifier: identity.processIdentifier,
			currentSpaceWindows: currentSpaceWindows(
				processIdentifier: identity.processIdentifier
			)
		)
		let matches: [Int] = correlations.compactMap { index, windowID in
			windowID == identity.windowID ? index : nil
		}
		guard matches.count == 1,
			let index = matches.first,
			applicationWindows.indices.contains(index)
		else {
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
		windowElement: AXUIElement,
		applicationElement: AXUIElement
	) throws {
		try validateElement(identity: identity, windowElement: windowElement)
		let applicationWindows: [AXUIElement] = try windows(of: applicationElement)
		guard let index = applicationWindows.firstIndex(where: {
			CFEqual($0, windowElement)
		}) else {
			throw ManagedExternalWindowError.windowUnavailable(identity)
		}
		let correlations: [Int: CGWindowID] = correlate(
			windows: applicationWindows,
			processIdentifier: identity.processIdentifier,
			currentSpaceWindows: currentSpaceWindows(
				processIdentifier: identity.processIdentifier
			)
		)
		guard correlations[index] == identity.windowID else {
			throw ManagedExternalWindowError.windowNotOnCurrentSpace(identity)
		}
	}

	static func validateRegardlessOfSpace(
		identity: ExternalWindowIdentity,
		windowElement: AXUIElement,
		applicationElement: AXUIElement
	) throws {
		try validateElement(identity: identity, windowElement: windowElement)
		let ids: [NSNumber] = [NSNumber(value: identity.windowID)]
		guard let descriptions = CGWindowListCreateDescriptionFromArray(ids as CFArray)
			as? [[String: Any]],
			descriptions.count == 1,
			let description = descriptions.first,
			let ownerPID = description[kCGWindowOwnerPID as String] as? NSNumber,
			ownerPID.int32Value == identity.processIdentifier,
			let layer = description[kCGWindowLayer as String] as? NSNumber,
			layer.intValue == 0,
			let bounds = description[kCGWindowBounds as String] as? NSDictionary,
			let cgFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
		else {
			throw ManagedExternalWindowError.windowUnavailable(identity)
		}
		let applicationWindows: [AXUIElement] = try windows(of: applicationElement)
		let matches: [AXUIElement] = applicationWindows.filter { element in
			guard let frame = try? accessibilityFrame(of: element) else { return false }
			return managedExternalWindowFramesAreApproximatelyEqual(
				frame,
				cgFrame,
				tolerance: 2
			)
		}
		guard matches.count == 1,
			let match = matches.first,
			CFEqual(match, windowElement)
		else {
			throw ManagedExternalWindowError.windowUnavailable(identity)
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

	private static func enclosingWindow(of hit: AXUIElement) throws -> AXUIElement {
		if stringAttribute(kAXRoleAttribute as CFString, of: hit) == kAXWindowRole {
			return hit
		}
		if let window = elementAttribute(kAXWindowAttribute as CFString, of: hit) {
			return window
		}
		var current: AXUIElement = hit
		for _ in 0 ..< 16 {
			guard let parent = elementAttribute(kAXParentAttribute as CFString, of: current)
			else { break }
			if stringAttribute(kAXRoleAttribute as CFString, of: parent) == kAXWindowRole {
				return parent
			}
			current = parent
		}
		throw ManagedExternalWindowError.windowAtPointUnavailable
	}

	private static func correlate(
		windows: [AXUIElement],
		processIdentifier: pid_t,
		currentSpaceWindows: [ExternalWindowCurrentSpaceWindow]
	) -> [Int: CGWindowID] {
		let candidates = windows.enumerated().map { index, window in
			ExternalWindowAccessibilityCandidate(
				index: index,
				processIdentifier: processIdentifier,
				role: stringAttribute(kAXRoleAttribute as CFString, of: window) ?? "",
				subrole: stringAttribute(kAXSubroleAttribute as CFString, of: window),
				accessibilityFrame: try? accessibilityFrame(of: window),
				isMinimized: (try? boolAttribute(
					kAXMinimizedAttribute as CFString,
					of: window
				)) ?? false,
				isFullScreen: (try? boolAttribute(
					"AXFullScreen" as CFString,
					of: window
				)) ?? false
			)
		}
		return externalWindowCurrentSpaceCorrelations(
			accessibilityCandidates: candidates,
			currentSpaceWindows: currentSpaceWindows
		)
	}

	private static func currentSpaceWindows(
		processIdentifier: pid_t
	) -> [ExternalWindowCurrentSpaceWindow] {
		guard let info = CGWindowListCopyWindowInfo(
			[.optionOnScreenOnly, .excludeDesktopElements],
			kCGNullWindowID
		) as? [[String: Any]] else { return [] }
		return info.compactMap { entry in
			guard let ownerPID = entry[kCGWindowOwnerPID as String] as? NSNumber,
				ownerPID.int32Value == processIdentifier,
				let windowID = entry[kCGWindowNumber as String] as? NSNumber,
				let layer = entry[kCGWindowLayer as String] as? NSNumber,
				let onscreen = entry[kCGWindowIsOnscreen as String] as? NSNumber,
				let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
				let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
			else { return nil }
			return .init(
				identity: .init(
					processIdentifier: processIdentifier,
					windowID: CGWindowID(windowID.uint32Value)
				),
				layer: layer.intValue,
				isOnscreen: onscreen.boolValue,
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
				== kAXWindowRole
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

	private static func elementAttribute(
		_ attribute: CFString,
		of element: AXUIElement
	) -> AXUIElement? {
		var raw: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
			let raw,
			CFGetTypeID(raw) == AXUIElementGetTypeID()
		else { return nil }
		return unsafeDowncast(raw, to: AXUIElement.self)
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

	@discardableResult
	func bind(selection: ExternalWindowSelection) throws -> ManagedExternalWindowSnapshot {
		guard Self.permissionStatus(prompt: false) == .authorized else {
			throw ManagedExternalWindowError.accessibilityPermissionRequired
		}
		guard binding == nil else { throw ManagedExternalWindowError.alreadyBound }
		try ExternalWindowSystem.validateCurrentSpace(
			identity: selection.identity,
			windowElement: selection.windowElement,
			applicationElement: selection.applicationElement
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
				windowElement: binding.selection.windowElement,
				applicationElement: binding.selection.applicationElement
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
				windowElement: binding.selection.windowElement,
				applicationElement: binding.selection.applicationElement
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
			windowElement: binding.selection.windowElement,
			applicationElement: binding.selection.applicationElement
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

	private func clearBinding() {
		applyTask?.cancel()
		applyTask = nil
		pendingApplyFrame = nil
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

@MainActor
final class WindowDragObserver {
	private enum MousePhase: Sendable {
		case down
		case dragged
		case up
	}

	private final class MonitorRelay: @unchecked Sendable {
		private weak var owner: WindowDragObserver?

		init(owner: WindowDragObserver) {
			self.owner = owner
		}

		func receive(phase: MousePhase, appKitScreenLocation: CGPoint) {
			Task { @MainActor [weak owner] in
				owner?.receive(phase: phase, appKitScreenLocation: appKitScreenLocation)
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

	private struct PendingDrag {
		let selection: ExternalWindowSelection
		let initialSample: ExternalWindowDragSample
		var currentSample: ExternalWindowDragSample
		var isQualified: Bool
	}

	var onEvent: ExternalWindowDragEventHandler?
	let qualificationConfiguration: ExternalWindowDragQualificationConfiguration
	let excludedProcessIdentifiers: Set<pid_t>
	private var monitor: MonitorToken?
	private var relay: MonitorRelay?
	private var pendingDrag: PendingDrag?

	init(
		qualificationConfiguration: ExternalWindowDragQualificationConfiguration = .init(),
		excludedProcessIdentifiers: Set<pid_t> = [getpid()],
		onEvent: ExternalWindowDragEventHandler? = nil
	) {
		self.qualificationConfiguration = qualificationConfiguration
		self.excludedProcessIdentifiers = excludedProcessIdentifiers
		self.onEvent = onEvent
	}

	func start(promptForAccessibility: Bool = false) throws {
		guard monitor == nil else { return }
		guard ManagedExternalWindow.permissionStatus(prompt: promptForAccessibility)
			== .authorized
		else {
			throw ManagedExternalWindowError.accessibilityPermissionRequired
		}
		let relay = MonitorRelay(owner: self)
		let mask: NSEvent.EventTypeMask = [
			.leftMouseDown,
			.leftMouseDragged,
			.leftMouseUp,
		]
		guard let monitor = NSEvent.addGlobalMonitorForEvents(
			matching: mask,
			handler: { event in
				let phase: MousePhase
				switch event.type {
				case .leftMouseDown: phase = .down
				case .leftMouseDragged: phase = .dragged
				case .leftMouseUp: phase = .up
				default: return
				}
				relay.receive(
					phase: phase,
					appKitScreenLocation: NSEvent.mouseLocation
				)
			}
		) else {
			throw ManagedExternalWindowError.globalMonitorUnavailable
		}
		self.relay = relay
		self.monitor = .init(value: monitor)
	}

	func stop() {
		if let pendingDrag, pendingDrag.isQualified {
			onEvent?(
				.cancelled(
					identity: pendingDrag.selection.identity,
					reason: .observerStopped
				)
			)
		}
		pendingDrag = nil
		monitor = nil
		relay = nil
	}

	private func receive(phase: MousePhase, appKitScreenLocation: CGPoint) {
		switch phase {
		case .down:
			beginPendingDrag(at: appKitScreenLocation)
		case .dragged:
			updatePendingDrag(at: appKitScreenLocation)
		case .up:
			endPendingDrag(at: appKitScreenLocation)
		}
	}

	private func beginPendingDrag(at location: CGPoint) {
		pendingDrag = nil
		guard let selection = try? ManagedExternalWindow.selectWindow(
			atAppKitScreenPoint: location,
			excludingProcessIdentifiers: excludedProcessIdentifiers
		) else { return }
		let sample = ExternalWindowDragSample(
			mouseAppKitScreenLocation: location,
			windowAppKitScreenFrame: selection.initialSnapshot.appKitScreenFrame
		)
		pendingDrag = .init(
			selection: selection,
			initialSample: sample,
			currentSample: sample,
			isQualified: false
		)
	}

	private func updatePendingDrag(at location: CGPoint) {
		guard var pendingDrag else { return }
		do {
			try ExternalWindowSystem.validateElement(
				identity: pendingDrag.selection.identity,
				windowElement: pendingDrag.selection.windowElement
			)
			let current = try snapshot(pendingDrag.selection)
			pendingDrag.currentSample = .init(
				mouseAppKitScreenLocation: location,
				windowAppKitScreenFrame: current.appKitScreenFrame
			)
			let dragSnapshot = ExternalWindowDragSnapshot(
				selection: pendingDrag.selection,
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
				onEvent?(.began(dragSnapshot))
			}
			self.pendingDrag = pendingDrag
		} catch {
			cancelPendingDrag(reason: .windowUnavailable)
		}
	}

	private func endPendingDrag(at location: CGPoint) {
		guard let pendingDrag else { return }
		defer { self.pendingDrag = nil }
		guard pendingDrag.isQualified else { return }
		do {
			try validate(pendingDrag.selection)
			let current = try snapshot(pendingDrag.selection)
			onEvent?(
				.ended(
					.init(
						selection: pendingDrag.selection,
						initialSample: pendingDrag.initialSample,
						currentSample: .init(
							mouseAppKitScreenLocation: location,
							windowAppKitScreenFrame: current.appKitScreenFrame
						)
					)
				)
			)
		} catch {
			onEvent?(
				.cancelled(
					identity: pendingDrag.selection.identity,
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
			.cancelled(identity: pendingDrag.selection.identity, reason: reason)
		)
	}

	private func validate(_ selection: ExternalWindowSelection) throws {
		try ExternalWindowSystem.validateCurrentSpace(
			identity: selection.identity,
			windowElement: selection.windowElement,
			applicationElement: selection.applicationElement
		)
	}

	private func snapshot(
		_ selection: ExternalWindowSelection
	) throws -> ManagedExternalWindowSnapshot {
		try ExternalWindowSystem.snapshot(
			identity: selection.identity,
			windowElement: selection.windowElement
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
