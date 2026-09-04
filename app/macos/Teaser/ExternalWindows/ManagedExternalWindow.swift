import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum ExternalWindowPermissionStatus: Equatable, Sendable {
	case authorized
	case notAuthorized
}

struct ManagedExternalWindowSnapshot: Equatable, Sendable {
	let applicationName: String
	let title: String
	let processIdentifier: pid_t
	let repositoryName: String
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

enum ManagedExternalWindowError: Error, LocalizedError {
	case accessibilityPermissionRequired
	case alreadyBound
	case invalidProcessIdentifier(pid_t)
	case invalidRepositoryName
	case invalidFrame(CGRect)
	case noScreens
	case noMatchingWindow(repositoryName: String)
	case ambiguousMatchingWindows(repositoryName: String, count: Int)
	case windowUnavailable
	case windowNotOnCurrentSpace
	case windowCannotMove
	case windowCannotResize
	case windowCannotFit(requested: CGRect, actual: CGRect)
	case windowCannotMinimize
	case accessibilityOperationFailed(operation: String, code: AXError)

	var errorDescription: String? {
		switch self {
		case .accessibilityPermissionRequired:
			return "Teaser needs Accessibility permission to manage external windows."
		case .alreadyBound:
			return "A managed external window is already bound."
		case .invalidProcessIdentifier(let processIdentifier):
			return "The external application process identifier is invalid: \(processIdentifier)."
		case .invalidRepositoryName:
			return "The repository name must not be empty."
		case .invalidFrame(let frame):
			return "The requested AppKit screen frame is invalid: \(frame)."
		case .noScreens:
			return "macOS did not report a menu-bar screen."
		case .noMatchingWindow(let repositoryName):
			return "No standard external window uniquely matches repository \(repositoryName)."
		case .ambiguousMatchingWindows(let repositoryName, let count):
			return "Found \(count) external windows matching repository \(repositoryName)."
		case .windowUnavailable:
			return "The managed external window is no longer available."
		case .windowNotOnCurrentSpace:
			return "The managed external window is not uniquely visible on the current Space."
		case .windowCannotMove:
			return "The external window does not allow its position to be changed."
		case .windowCannotResize:
			return "The external window does not allow its size to be changed."
		case .windowCannotFit(let requested, let actual):
			return "The external window cannot fit the requested frame \(requested); it applied \(actual)."
		case .windowCannotMinimize:
			return "The external window does not allow its minimized state to be changed."
		case .accessibilityOperationFailed(let operation, let code):
			return "Accessibility operation \(operation) failed with \(code)."
		}
	}
}

struct ManagedExternalWindowCandidate: Equatable, Sendable {
	let index: Int
	let role: String
	let subrole: String?
	let title: String
	let document: String?
	let accessibilityFrame: CGRect?
	let isMinimized: Bool
	let isOnCurrentSpace: Bool
}

struct ManagedExternalWindowCurrentSpaceWindow: Equatable, Sendable {
	let windowID: CGWindowID
	let title: String?
	let accessibilityFrame: CGRect
}

struct ManagedExternalWindowAdjacentLayout: Equatable, Sendable {
	let hostFrame: CGRect
	let externalFrame: CGRect
}

enum ManagedExternalWindowCandidateSelectionError: Error, Equatable {
	case noMatch(repositoryName: String)
	case ambiguous(repositoryName: String, count: Int)
}

func selectUniqueManagedExternalWindowCandidate(
	from candidates: [ManagedExternalWindowCandidate],
	repositoryURL: URL
) throws -> Int {
	let standardizedRepositoryURL: URL = repositoryURL.standardizedFileURL
		.resolvingSymlinksInPath()
	let repositoryName: String = standardizedRepositoryURL.lastPathComponent
	guard !repositoryName.isEmpty else {
		throw ManagedExternalWindowCandidateSelectionError.noMatch(
			repositoryName: repositoryName
		)
	}

	let eligibleCandidates: [ManagedExternalWindowCandidate] = candidates.filter { candidate in
		candidate.role == kAXWindowRole
			&& candidate.subrole == kAXStandardWindowSubrole
			&& !candidate.isMinimized
			&& candidate.isOnCurrentSpace
	}
	let documentMatches: [ManagedExternalWindowCandidate] = eligibleCandidates.filter { candidate in
		guard let document: String = candidate.document else {
			return false
		}
		return externalWindowDocument(
			document,
			isInside: standardizedRepositoryURL
		)
	}

	if documentMatches.count == 1, let match: ManagedExternalWindowCandidate = documentMatches.first {
		return match.index
	}
	if documentMatches.count > 1 {
		throw ManagedExternalWindowCandidateSelectionError.ambiguous(
			repositoryName: repositoryName,
			count: documentMatches.count
		)
	}

	throw ManagedExternalWindowCandidateSelectionError.noMatch(
		repositoryName: repositoryName
	)
}

func managedExternalWindowCurrentSpaceCorrelations(
	candidates: [ManagedExternalWindowCandidate],
	currentSpaceWindows: [ManagedExternalWindowCurrentSpaceWindow]
) -> [Int: CGWindowID] {
	struct Correlation {
		let candidateOffset: Int
		let currentSpaceWindowOffset: Int
	}

	var correlations: [Correlation] = []
	for (
		currentSpaceWindowOffset,
		currentSpaceWindow
	) in currentSpaceWindows.enumerated() {
		let frameMatches: [(offset: Int, element: ManagedExternalWindowCandidate)] =
			candidates.enumerated().filter { _, candidate in
				guard let candidateFrame: CGRect = candidate.accessibilityFrame else {
					return false
				}
				return managedExternalWindowFramesAreApproximatelyEqual(
					candidateFrame,
					currentSpaceWindow.accessibilityFrame,
					tolerance: 2
				)
			}
		if frameMatches.count == 1, let frameMatch = frameMatches.first {
			correlations.append(
				.init(
					candidateOffset: frameMatch.offset,
					currentSpaceWindowOffset: currentSpaceWindowOffset
				)
			)
			continue
		}

		guard let currentSpaceTitle: String = currentSpaceWindow.title,
			!currentSpaceTitle.isEmpty
		else {
			continue
		}
		let normalizedCurrentSpaceTitle: String = normalizedExternalWindowMatchText(
			currentSpaceTitle
		)
		let titleMatches = frameMatches.filter { _, candidate in
			normalizedExternalWindowMatchText(candidate.title)
				== normalizedCurrentSpaceTitle
		}
		guard titleMatches.count == 1, let titleMatch = titleMatches.first else {
			continue
		}
		correlations.append(
			.init(
				candidateOffset: titleMatch.offset,
				currentSpaceWindowOffset: currentSpaceWindowOffset
			)
		)
	}

	let uniqueCorrelations: [(Int, CGWindowID)] = correlations.compactMap { correlation in
		let candidateMatchCount: Int = correlations.count {
			$0.candidateOffset == correlation.candidateOffset
		}
		let currentSpaceWindowMatchCount: Int = correlations.count {
			$0.currentSpaceWindowOffset == correlation.currentSpaceWindowOffset
		}
		guard candidateMatchCount == 1, currentSpaceWindowMatchCount == 1 else {
			return nil
		}
		return (
			candidates[correlation.candidateOffset].index,
			currentSpaceWindows[correlation.currentSpaceWindowOffset].windowID
		)
	}
	return Dictionary(uniqueKeysWithValues: uniqueCorrelations)
}

func managedExternalWindowAccessibilityFrame(
	fromAppKitScreenFrame appKitScreenFrame: CGRect,
	menuBarScreenFrame: CGRect
) -> CGRect {
	.init(
		x: appKitScreenFrame.minX,
		y: menuBarScreenFrame.maxY - appKitScreenFrame.maxY,
		width: appKitScreenFrame.width,
		height: appKitScreenFrame.height
	)
}

func managedExternalWindowAdjacentLayout(
	in visibleFrame: CGRect,
	gap: CGFloat = 8,
	hostFraction: CGFloat = 0.45,
	minimumHostWidth: CGFloat = 0,
	minimumExternalWidth: CGFloat = 0
) -> ManagedExternalWindowAdjacentLayout? {
	guard visibleFrame.isValidManagedExternalWindowFrame,
		gap.isFinite,
		gap >= 0,
		hostFraction.isFinite,
		hostFraction > 0,
		hostFraction < 1,
		minimumHostWidth.isFinite,
		minimumHostWidth >= 0,
		minimumExternalWidth.isFinite,
		minimumExternalWidth >= 0,
		visibleFrame.width > gap
	else {
		return nil
	}
	let availableWidth: CGFloat = visibleFrame.width - gap
	guard availableWidth >= minimumHostWidth + minimumExternalWidth else {
		return nil
	}
	let preferredHostWidth: CGFloat = floor(availableWidth * hostFraction)
	let hostWidth: CGFloat = min(
		max(preferredHostWidth, minimumHostWidth),
		availableWidth - minimumExternalWidth
	)
	let externalWidth: CGFloat = availableWidth - hostWidth
	guard hostWidth > 0, externalWidth > 0 else {
		return nil
	}
	return .init(
		hostFrame: .init(
			x: visibleFrame.minX,
			y: visibleFrame.minY,
			width: hostWidth,
			height: visibleFrame.height
		),
		externalFrame: .init(
			x: visibleFrame.minX + hostWidth + gap,
			y: visibleFrame.minY,
			width: externalWidth,
			height: visibleFrame.height
		)
	)
}

func managedExternalWindowAppKitScreenFrame(
	fromAccessibilityFrame accessibilityFrame: CGRect,
	menuBarScreenFrame: CGRect
) -> CGRect {
	.init(
		x: accessibilityFrame.minX,
		y: menuBarScreenFrame.maxY - accessibilityFrame.maxY,
		width: accessibilityFrame.width,
		height: accessibilityFrame.height
	)
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
	case kAXMovedNotification:
		return .moved
	case kAXResizedNotification:
		return .resized
	case kAXUIElementDestroyedNotification:
		return .destroyed
	default:
		return nil
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

	private final class Observation {
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

		deinit {
			invalidate()
		}
	}

	private struct Binding {
		let applicationElement: AXUIElement
		let windowElement: AXUIElement
		let windowID: CGWindowID
		let processIdentifier: pid_t
		let applicationName: String
		let title: String
		let repositoryName: String
		let repositoryURL: URL
		let originalAccessibilityFrame: CGRect
		let originalMinimizedState: Bool
		var lastAppliedAccessibilityFrame: CGRect?
	}

	var onEvent: ManagedExternalWindowEventHandler?

	private var binding: Binding?
	private var observation: Observation?
	private var observationGeneration: UInt = 0
	private var activeObservationGeneration: UInt?

	init(onEvent: ManagedExternalWindowEventHandler? = nil) {
		self.onEvent = onEvent
	}

	static func permissionStatus(prompt: Bool) -> ExternalWindowPermissionStatus {
		let isTrusted: Bool
		if prompt {
			let options: [String: Bool] = [
				"AXTrustedCheckOptionPrompt": true,
			]
			isTrusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
		} else {
			isTrusted = AXIsProcessTrusted()
		}
		return isTrusted ? .authorized : .notAuthorized
	}

	@discardableResult
	func bind(
		applicationPID: pid_t,
		repositoryURL: URL
	) throws -> ManagedExternalWindowSnapshot {
		guard Self.permissionStatus(prompt: false) == .authorized else {
			throw ManagedExternalWindowError.accessibilityPermissionRequired
		}
		guard binding == nil else {
			throw ManagedExternalWindowError.alreadyBound
		}
		guard applicationPID > 0 else {
			throw ManagedExternalWindowError.invalidProcessIdentifier(applicationPID)
		}

		let standardizedRepositoryURL: URL = repositoryURL.standardizedFileURL
			.resolvingSymlinksInPath()
		let trimmedRepositoryName: String = standardizedRepositoryURL.lastPathComponent
			.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedRepositoryName.isEmpty else {
			throw ManagedExternalWindowError.invalidRepositoryName
		}

		let applicationElement: AXUIElement = AXUIElementCreateApplication(applicationPID)
		AXUIElementSetMessagingTimeout(applicationElement, 0.75)
		let windows: [AXUIElement] = try windows(of: applicationElement)
		let currentSpaceCorrelations: [Int: CGWindowID] = correlateCurrentSpaceWindows(
			windows: windows,
			applicationPID: applicationPID
		)
		let candidates: [ManagedExternalWindowCandidate] = windows.enumerated().map { index, window in
			candidate(
				index: index,
				window: window,
				isOnCurrentSpace: currentSpaceCorrelations[index] != nil
			)
		}

		let selectedIndex: Int
		do {
			selectedIndex = try selectUniqueManagedExternalWindowCandidate(
				from: candidates,
				repositoryURL: standardizedRepositoryURL
			)
		} catch let error as ManagedExternalWindowCandidateSelectionError {
			switch error {
			case .noMatch:
				throw ManagedExternalWindowError.noMatchingWindow(
					repositoryName: trimmedRepositoryName
				)
			case .ambiguous(_, let count):
				throw ManagedExternalWindowError.ambiguousMatchingWindows(
					repositoryName: trimmedRepositoryName,
					count: count
				)
			}
		}

		guard windows.indices.contains(selectedIndex) else {
			throw ManagedExternalWindowError.windowUnavailable
		}
		guard let windowID: CGWindowID = currentSpaceCorrelations[selectedIndex] else {
			throw ManagedExternalWindowError.windowNotOnCurrentSpace
		}
		let windowElement: AXUIElement = windows[selectedIndex]
		try requireSettable(
			kAXPositionAttribute as CFString,
			on: windowElement,
			error: .windowCannotMove
		)
		try requireSettable(
			kAXSizeAttribute as CFString,
			on: windowElement,
			error: .windowCannotResize
		)

		let originalAccessibilityFrame: CGRect = try accessibilityFrame(of: windowElement)
		let originalMinimizedState: Bool = try boolAttribute(
			kAXMinimizedAttribute as CFString,
			of: windowElement
		)
		let applicationName: String = NSRunningApplication(
			processIdentifier: applicationPID
		)?.localizedName ?? "Application"
		let title: String = stringAttribute(
			kAXTitleAttribute as CFString,
			of: windowElement
		) ?? trimmedRepositoryName

		let newBinding: Binding = .init(
			applicationElement: applicationElement,
			windowElement: windowElement,
			windowID: windowID,
			processIdentifier: applicationPID,
			applicationName: applicationName,
			title: title,
			repositoryName: trimmedRepositoryName,
			repositoryURL: standardizedRepositoryURL,
			originalAccessibilityFrame: originalAccessibilityFrame,
			originalMinimizedState: originalMinimizedState,
			lastAppliedAccessibilityFrame: nil
		)
		let initialSnapshot: ManagedExternalWindowSnapshot = .init(
			applicationName: applicationName,
			title: title,
			processIdentifier: applicationPID,
			repositoryName: trimmedRepositoryName,
			appKitScreenFrame: try appKitScreenFrame(
				fromAccessibilityFrame: originalAccessibilityFrame
			),
			isMinimized: false
		)
		let newObservation: Observation = try makeObservation(
			applicationPID: applicationPID,
			windowElement: windowElement
		)
		if originalMinimizedState {
			try requireSettable(
				kAXMinimizedAttribute as CFString,
				on: windowElement,
				error: .windowCannotMinimize
			)
			try setBoolAttribute(
				kAXMinimizedAttribute as CFString,
				value: false,
				on: windowElement,
				operation: "restore external window"
			)
		}
		binding = newBinding
		observation = newObservation
		activeObservationGeneration = observationGeneration
		return initialSnapshot
	}

	@discardableResult
	func apply(
		appKitScreenFrame requestedFrame: CGRect
	) throws -> ManagedExternalWindowSnapshot {
		guard requestedFrame.isValidManagedExternalWindowFrame else {
			throw ManagedExternalWindowError.invalidFrame(requestedFrame)
		}
		guard var binding else {
			throw ManagedExternalWindowError.windowUnavailable
		}
		try requireValid(binding)
		try requireOnCurrentSpace(binding)

		let targetAccessibilityFrame: CGRect = try accessibilityFrame(
			fromAppKitScreenFrame: requestedFrame
		)
		let currentAccessibilityFrame: CGRect = try accessibilityFrame(
			of: binding.windowElement
		)
		if managedExternalWindowFramesAreApproximatelyEqual(
			currentAccessibilityFrame,
			targetAccessibilityFrame
		) {
			binding.lastAppliedAccessibilityFrame = currentAccessibilityFrame
			self.binding = binding
			return try snapshot()
		}

		do {
			try writeAccessibilityFrame(
				targetAccessibilityFrame,
				to: binding.windowElement
			)
			let appliedAccessibilityFrame: CGRect = try accessibilityFrame(
				of: binding.windowElement
			)
			guard managedExternalWindowFramesAreApproximatelyEqual(
				appliedAccessibilityFrame,
				targetAccessibilityFrame
			) else {
				let actualAppKitScreenFrame: CGRect = try appKitScreenFrame(
					fromAccessibilityFrame: appliedAccessibilityFrame
				)
				throw ManagedExternalWindowError.windowCannotFit(
					requested: requestedFrame,
					actual: actualAppKitScreenFrame
				)
			}
			binding.lastAppliedAccessibilityFrame = appliedAccessibilityFrame
		} catch {
			try? writeAccessibilityFrame(
				currentAccessibilityFrame,
				to: binding.windowElement
			)
			throw error
		}

		self.binding = binding
		return try snapshot()
	}

	func focusAndRaise() throws {
		guard let binding else {
			throw ManagedExternalWindowError.windowUnavailable
		}
		try requireValid(binding)
		try requireOnCurrentSpace(binding)
		try setMinimized(false)

		_ = NSRunningApplication(processIdentifier: binding.processIdentifier)?.activate(options: [])
		try setAttribute(
			kAXFocusedWindowAttribute as CFString,
			value: binding.windowElement,
			on: binding.applicationElement,
			operation: "focus external window"
		)
		let raiseError: AXError = AXUIElementPerformAction(
			binding.windowElement,
			kAXRaiseAction as CFString
		)
		guard raiseError == .success else {
			throw ManagedExternalWindowError.accessibilityOperationFailed(
				operation: "raise external window",
				code: raiseError
			)
		}
	}

	func setMinimized(_ minimized: Bool) throws {
		guard let binding else {
			throw ManagedExternalWindowError.windowUnavailable
		}
		try requireValid(binding)
		try requireOnCurrentSpace(binding)
		let currentState: Bool = try boolAttribute(
			kAXMinimizedAttribute as CFString,
			of: binding.windowElement
		)
		guard currentState != minimized else {
			return
		}
		try requireSettable(
			kAXMinimizedAttribute as CFString,
			on: binding.windowElement,
			error: .windowCannotMinimize
		)
		try setBoolAttribute(
			kAXMinimizedAttribute as CFString,
			value: minimized,
			on: binding.windowElement,
			operation: minimized ? "minimize external window" : "restore external window"
		)
	}

	@discardableResult
	func release(restoringOriginalFrame: Bool) -> Bool {
		guard let binding else {
			stopObserving()
			return true
		}
		guard restoringOriginalFrame else {
			stopObserving()
			self.binding = nil
			return true
		}
		guard isValid(binding) else {
			return false
		}

		do {
			try requireSameWindowRegardlessOfSpace(binding)
			if let lastAppliedAccessibilityFrame = binding.lastAppliedAccessibilityFrame {
				let currentAccessibilityFrame: CGRect = try accessibilityFrame(
					of: binding.windowElement
				)
				if managedExternalWindowFramesAreApproximatelyEqual(
					currentAccessibilityFrame,
					lastAppliedAccessibilityFrame
				) {
					try writeAccessibilityFrame(
						binding.originalAccessibilityFrame,
						to: binding.windowElement
					)
				}
			}

			let currentMinimizedState: Bool = try boolAttribute(
				kAXMinimizedAttribute as CFString,
				of: binding.windowElement
			)
			if currentMinimizedState != binding.originalMinimizedState {
				try setBoolAttribute(
					kAXMinimizedAttribute as CFString,
					value: binding.originalMinimizedState,
					on: binding.windowElement,
					operation: "restore external window minimized state"
				)
			}
			stopObserving()
			self.binding = nil
			return true
		} catch {
			return false
		}
	}

	private func makeObservation(
		applicationPID: pid_t,
		windowElement: AXUIElement
	) throws -> Observation {
		observationGeneration &+= 1
		let relay: ObserverRelay = .init(
			owner: self,
			generation: observationGeneration
		)
		var createdObserver: AXObserver?
		let createError: AXError = AXObserverCreate(
			applicationPID,
			{ _, _, notification, refcon in
				guard let refcon,
					let event: ManagedExternalWindowEvent = managedExternalWindowEvent(
						forAccessibilityNotification: notification as String
					)
				else {
					return
				}
				let relay: ObserverRelay = Unmanaged<ObserverRelay>
					.fromOpaque(refcon)
					.takeUnretainedValue()
				relay.receive(event)
			},
			&createdObserver
		)
		guard createError == .success, let observer: AXObserver = createdObserver else {
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
		var installedNotifications: [CFString] = []
		for notification: CFString in notifications {
			let addError: AXError = AXObserverAddNotification(
				observer,
				windowElement,
				notification,
				Unmanaged.passUnretained(relay).toOpaque()
			)
			guard addError == .success else {
				for installedNotification: CFString in installedNotifications {
					AXObserverRemoveNotification(
						observer,
						windowElement,
						installedNotification
					)
				}
				throw ManagedExternalWindowError.accessibilityOperationFailed(
					operation: "observe external window notification \(notification)",
					code: addError
				)
			}
			installedNotifications.append(notification)
		}

		let runLoop: CFRunLoop = CFRunLoopGetMain()
		CFRunLoopAddSource(
			runLoop,
			AXObserverGetRunLoopSource(observer),
			.commonModes
		)
		return .init(
			observer: observer,
			windowElement: windowElement,
			notifications: notifications,
			runLoop: runLoop,
			relay: relay
		)
	}

	private func stopObserving() {
		activeObservationGeneration = nil
		observation?.invalidate()
		observation = nil
	}

	private func receiveObservedEvent(
		_ event: ManagedExternalWindowEvent,
		generation: UInt
	) {
		guard activeObservationGeneration == generation else { return }
		if event == .destroyed {
			stopObserving()
			binding = nil
		}
		onEvent?(event)
	}

	private func snapshot() throws -> ManagedExternalWindowSnapshot {
		guard let binding else {
			throw ManagedExternalWindowError.windowUnavailable
		}
		try requireValid(binding)
		let accessibilityFrame: CGRect = try accessibilityFrame(of: binding.windowElement)
		return .init(
			applicationName: binding.applicationName,
			title: binding.title,
			processIdentifier: binding.processIdentifier,
			repositoryName: binding.repositoryName,
			appKitScreenFrame: try appKitScreenFrame(
				fromAccessibilityFrame: accessibilityFrame
			),
			isMinimized: try boolAttribute(
				kAXMinimizedAttribute as CFString,
				of: binding.windowElement
			)
		)
	}

	private func windows(of applicationElement: AXUIElement) throws -> [AXUIElement] {
		var rawValue: CFTypeRef?
		let error: AXError = AXUIElementCopyAttributeValue(
			applicationElement,
			kAXWindowsAttribute as CFString,
			&rawValue
		)
		guard error == .success else {
			throw ManagedExternalWindowError.accessibilityOperationFailed(
				operation: "enumerate external windows",
				code: error
			)
		}
		return rawValue as? [AXUIElement] ?? []
	}

	private func candidate(
		index: Int,
		window: AXUIElement,
		isOnCurrentSpace: Bool
	) -> ManagedExternalWindowCandidate {
		let windowFrame: CGRect? = try? accessibilityFrame(of: window)
		return .init(
			index: index,
			role: stringAttribute(kAXRoleAttribute as CFString, of: window) ?? "",
			subrole: stringAttribute(kAXSubroleAttribute as CFString, of: window),
			title: stringAttribute(kAXTitleAttribute as CFString, of: window) ?? "",
			document: stringAttribute(kAXDocumentAttribute as CFString, of: window),
			accessibilityFrame: windowFrame,
			isMinimized: (try? boolAttribute(kAXMinimizedAttribute as CFString, of: window))
				?? false,
			isOnCurrentSpace: isOnCurrentSpace
		)
	}

	private func currentSpaceWindows(
		applicationPID: pid_t
	) -> [ManagedExternalWindowCurrentSpaceWindow] {
		let options: CGWindowListOption = [
			.optionOnScreenOnly,
			.excludeDesktopElements,
		]
		guard let windowInfo: [[String: Any]] = CGWindowListCopyWindowInfo(
			options,
			kCGNullWindowID
		) as? [[String: Any]] else {
			return []
		}

		return windowInfo.compactMap { entry in
			guard let ownerPID: NSNumber = entry[kCGWindowOwnerPID as String] as? NSNumber,
				ownerPID.int32Value == applicationPID,
				let windowID: NSNumber = entry[kCGWindowNumber as String] as? NSNumber,
				let layer: NSNumber = entry[kCGWindowLayer as String] as? NSNumber,
				layer.intValue == 0,
				let isOnscreen: NSNumber = entry[kCGWindowIsOnscreen as String] as? NSNumber,
				isOnscreen.boolValue,
				let boundsDictionary: NSDictionary = entry[kCGWindowBounds as String]
					as? NSDictionary
			else {
				return nil
			}
			let bounds: CFDictionary = boundsDictionary as CFDictionary
			guard let frame: CGRect = CGRect(dictionaryRepresentation: bounds) else {
				return nil
			}
			return .init(
				windowID: CGWindowID(windowID.uint32Value),
				title: entry[kCGWindowName as String] as? String,
				accessibilityFrame: frame
			)
		}
	}

	private func correlateCurrentSpaceWindows(
		windows: [AXUIElement],
		applicationPID: pid_t
	) -> [Int: CGWindowID] {
		let candidates: [ManagedExternalWindowCandidate] = windows.enumerated().map {
			index,
			window in
			candidate(index: index, window: window, isOnCurrentSpace: false)
		}
		return managedExternalWindowCurrentSpaceCorrelations(
			candidates: candidates,
			currentSpaceWindows: currentSpaceWindows(
				applicationPID: applicationPID
			)
		)
	}

	private func requireOnCurrentSpace(_ binding: Binding) throws {
		let applicationWindows: [AXUIElement] = try windows(
			of: binding.applicationElement
		)
		guard let boundWindowIndex: Int = applicationWindows.firstIndex(where: {
			CFEqual($0, binding.windowElement)
		}) else {
			throw ManagedExternalWindowError.windowUnavailable
		}
		let currentSpaceCorrelations: [Int: CGWindowID] = correlateCurrentSpaceWindows(
			windows: applicationWindows,
			applicationPID: binding.processIdentifier
		)
		guard currentSpaceCorrelations[boundWindowIndex] == binding.windowID else {
			throw ManagedExternalWindowError.windowNotOnCurrentSpace
		}
	}

	private func requireSameWindowRegardlessOfSpace(_ binding: Binding) throws {
		let windowIDs: [NSNumber] = [NSNumber(value: binding.windowID)]
		guard let windowInfo: [[String: Any]] = CGWindowListCreateDescriptionFromArray(
			windowIDs as CFArray
		) as? [[String: Any]] else {
			throw ManagedExternalWindowError.windowUnavailable
		}
		let matchingEntries: [[String: Any]] = windowInfo.filter { entry in
			guard let windowID: NSNumber = entry[kCGWindowNumber as String] as? NSNumber,
				CGWindowID(windowID.uint32Value) == binding.windowID,
				let ownerPID: NSNumber = entry[kCGWindowOwnerPID as String] as? NSNumber,
				ownerPID.int32Value == binding.processIdentifier,
				let layer: NSNumber = entry[kCGWindowLayer as String] as? NSNumber,
				layer.intValue == 0
			else {
				return false
			}
			return true
		}
		guard matchingEntries.count == 1,
			let matchingEntry: [String: Any] = matchingEntries.first,
			let boundsDictionary: NSDictionary = matchingEntry[kCGWindowBounds as String]
				as? NSDictionary,
			let windowFrame: CGRect = CGRect(
				dictionaryRepresentation: boundsDictionary as CFDictionary
			),
			managedExternalWindowFramesAreApproximatelyEqual(
				try accessibilityFrame(of: binding.windowElement),
				windowFrame,
				tolerance: 2
			),
			let document: String = stringAttribute(
				kAXDocumentAttribute as CFString,
				of: binding.windowElement
			),
			externalWindowDocument(document, isInside: binding.repositoryURL)
		else {
			throw ManagedExternalWindowError.windowUnavailable
		}
	}

	private func requireValid(_ binding: Binding) throws {
		guard isValid(binding) else {
			throw ManagedExternalWindowError.windowUnavailable
		}
	}

	private func isValid(_ binding: Binding) -> Bool {
		var currentProcessIdentifier: pid_t = 0
		guard AXUIElementGetPid(
			binding.windowElement,
			&currentProcessIdentifier
		) == .success,
			currentProcessIdentifier == binding.processIdentifier,
			stringAttribute(kAXRoleAttribute as CFString, of: binding.windowElement)
				== kAXWindowRole
		else {
			return false
		}
		return true
	}

	private func requireSettable(
		_ attribute: CFString,
		on element: AXUIElement,
		error unavailableError: ManagedExternalWindowError
	) throws {
		var settable: DarwinBoolean = false
		let result: AXError = AXUIElementIsAttributeSettable(
			element,
			attribute,
			&settable
		)
		guard result == .success else {
			throw ManagedExternalWindowError.accessibilityOperationFailed(
				operation: "test \(attribute) writability",
				code: result
			)
		}
		guard settable.boolValue else {
			throw unavailableError
		}
	}

	private func accessibilityFrame(
		fromAppKitScreenFrame frame: CGRect
	) throws -> CGRect {
		guard let menuBarScreenFrame: CGRect = NSScreen.screens.first?.frame else {
			throw ManagedExternalWindowError.noScreens
		}
		return managedExternalWindowAccessibilityFrame(
			fromAppKitScreenFrame: frame,
			menuBarScreenFrame: menuBarScreenFrame
		)
	}

	private func appKitScreenFrame(
		fromAccessibilityFrame frame: CGRect
	) throws -> CGRect {
		guard let menuBarScreenFrame: CGRect = NSScreen.screens.first?.frame else {
			throw ManagedExternalWindowError.noScreens
		}
		return managedExternalWindowAppKitScreenFrame(
			fromAccessibilityFrame: frame,
			menuBarScreenFrame: menuBarScreenFrame
		)
	}

	private func accessibilityFrame(of window: AXUIElement) throws -> CGRect {
		let position: CGPoint = try pointAttribute(
			kAXPositionAttribute as CFString,
			of: window
		)
		let size: CGSize = try sizeAttribute(
			kAXSizeAttribute as CFString,
			of: window
		)
		return .init(origin: position, size: size)
	}

	private func writeAccessibilityFrame(
		_ frame: CGRect,
		to window: AXUIElement
	) throws {
		var size: CGSize = frame.size
		guard let sizeValue: AXValue = AXValueCreate(.cgSize, &size) else {
			throw ManagedExternalWindowError.invalidFrame(frame)
		}
		try setAttribute(
			kAXSizeAttribute as CFString,
			value: sizeValue,
			on: window,
			operation: "resize external window"
		)

		var position: CGPoint = frame.origin
		guard let positionValue: AXValue = AXValueCreate(.cgPoint, &position) else {
			throw ManagedExternalWindowError.invalidFrame(frame)
		}
		try setAttribute(
			kAXPositionAttribute as CFString,
			value: positionValue,
			on: window,
			operation: "move external window"
		)
	}

	private func stringAttribute(
		_ attribute: CFString,
		of element: AXUIElement
	) -> String? {
		var rawValue: CFTypeRef?
		let error: AXError = AXUIElementCopyAttributeValue(element, attribute, &rawValue)
		guard error == .success else {
			return nil
		}
		return rawValue as? String
	}

	private func boolAttribute(
		_ attribute: CFString,
		of element: AXUIElement
	) throws -> Bool {
		var rawValue: CFTypeRef?
		let error: AXError = AXUIElementCopyAttributeValue(element, attribute, &rawValue)
		guard error == .success else {
			throw ManagedExternalWindowError.accessibilityOperationFailed(
				operation: "read \(attribute)",
				code: error
			)
		}
		guard let value: Bool = rawValue as? Bool else {
			throw ManagedExternalWindowError.accessibilityOperationFailed(
				operation: "decode \(attribute)",
				code: .failure
			)
		}
		return value
	}

	private func pointAttribute(
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

	private func sizeAttribute(
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

	private func axValueAttribute(
		_ attribute: CFString,
		of element: AXUIElement
	) throws -> AXValue {
		var rawValue: CFTypeRef?
		let error: AXError = AXUIElementCopyAttributeValue(element, attribute, &rawValue)
		guard error == .success else {
			throw ManagedExternalWindowError.accessibilityOperationFailed(
				operation: "read \(attribute)",
				code: error
			)
		}
		guard let rawValue,
			CFGetTypeID(rawValue) == AXValueGetTypeID()
		else {
			throw ManagedExternalWindowError.accessibilityOperationFailed(
				operation: "decode \(attribute)",
				code: .failure
			)
		}
		let value: AXValue = rawValue as! AXValue
		return value
	}

	private func setAttribute(
		_ attribute: CFString,
		value: CFTypeRef,
		on element: AXUIElement,
		operation: String
	) throws {
		let error: AXError = AXUIElementSetAttributeValue(element, attribute, value)
		guard error == .success else {
			throw ManagedExternalWindowError.accessibilityOperationFailed(
				operation: operation,
				code: error
			)
		}
	}

	private func setBoolAttribute(
		_ attribute: CFString,
		value: Bool,
		on element: AXUIElement,
		operation: String
	) throws {
		let booleanValue: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
		try setAttribute(
			attribute,
			value: booleanValue,
			on: element,
			operation: operation
		)
	}
}

private func normalizedExternalWindowMatchText(_ value: String) -> String {
	value
		.trimmingCharacters(in: .whitespacesAndNewlines)
		.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
}

private func externalWindowDocument(
	_ value: String,
	isInside repositoryURL: URL
) -> Bool {
	guard let documentURL: URL = externalWindowFileURL(value) else {
		return false
	}
	let documentPath: String = documentURL.standardizedFileURL
		.resolvingSymlinksInPath()
		.path
	let repositoryPath: String = repositoryURL.standardizedFileURL
		.resolvingSymlinksInPath()
		.path
	guard documentPath != repositoryPath else {
		return true
	}
	let repositoryPrefix: String = repositoryPath.hasSuffix("/")
		? repositoryPath
		: repositoryPath + "/"
	return documentPath.hasPrefix(repositoryPrefix)
}

private func externalWindowFileURL(_ value: String?) -> URL? {
	guard let value else { return nil }
	let trimmedValue: String = value.trimmingCharacters(in: .whitespacesAndNewlines)
	guard !trimmedValue.isEmpty else { return nil }
	if trimmedValue.hasPrefix("/") {
		guard !trimmedValue.hasPrefix("//") else { return nil }
		return URL(fileURLWithPath: trimmedValue)
	}
	guard let url: URL = URL(string: trimmedValue),
		url.isFileURL,
		url.user == nil,
		url.password == nil,
		url.port == nil,
		url.path.hasPrefix("/"),
		!url.path.hasPrefix("//")
	else {
		return nil
	}
	if let host: String = url.host,
		!host.isEmpty,
		host.caseInsensitiveCompare("localhost") != .orderedSame
	{
		return nil
	}
	return url
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
