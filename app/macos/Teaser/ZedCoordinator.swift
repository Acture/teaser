import AppKit
import Combine
import Foundation

enum ZedConnectionState: Equatable, Sendable {
	case disconnected
	case permissionRequired
	case launching
	case locating
	case attached(ManagedExternalWindowSnapshot)
	case releasePending(String)
	case failed(String)
}

private enum ZedLayoutError: Error, LocalizedError {
	case hostWindowUnavailable
	case screenUnavailable
	case hostWindowCannotFit(requested: CGRect, actual: CGRect)

	var errorDescription: String? {
		switch self {
		case .hostWindowUnavailable:
			return "The Teaser window is unavailable for adjacent Zed tiling."
		case .screenUnavailable:
			return "macOS did not report a screen for adjacent Zed tiling."
		case .hostWindowCannotFit(let requested, let actual):
			return "Teaser cannot fit the adjacent layout \(requested); it applied \(actual)."
		}
	}
}

@MainActor
final class ZedCoordinator: ObservableObject {
	@Published private(set) var state: ZedConnectionState = .disconnected

	@Published private(set) var repositoryURL: URL?

	private static let zedBundleIdentifier: String = "dev.zed.Zed"
	private static let repositoryDefaultsKey: String = "zed.repository.path"
	private static let locateAttempts: Int = 50
	private static let locateInterval: Duration = .milliseconds(200)
	private static let geometryDebounce: Duration = .milliseconds(60)
	private static let minimumExternalWindowWidth: CGFloat = 480

	private let managedWindow: ManagedExternalWindow = .init()
	private var launchTask: Task<Void, Never>?
	private var geometryTask: Task<Void, Never>?
	private weak var hostWindow: NSWindow?
	private var originalHostFrame: CGRect?
	private var lastAppliedHostFrame: CGRect?
	private var isApplyingLayout: Bool = false
	private var connectionGeneration: UInt = 0

	init(repositoryURL: URL?) {
		let configuredURL: URL?
		if let repositoryURL {
			let standardizedURL: URL = repositoryURL.standardizedFileURL
			configuredURL = standardizedURL
			UserDefaults.standard.set(
				standardizedURL.path,
				forKey: Self.repositoryDefaultsKey
			)
		} else if let savedPath: String = UserDefaults.standard.string(
			forKey: Self.repositoryDefaultsKey
		) {
			configuredURL = URL(fileURLWithPath: savedPath).standardizedFileURL
		} else {
			configuredURL = nil
		}
		self.repositoryURL = configuredURL
		managedWindow.onEvent = { [weak self] event in
			self?.handleManagedWindowEvent(event)
		}
	}

	func connect() {
		guard let repositoryURL else {
			chooseRepository()
			return
		}

		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(
			atPath: repositoryURL.path,
			isDirectory: &isDirectory
		), isDirectory.boolValue else {
			self.repositoryURL = nil
			UserDefaults.standard.removeObject(forKey: Self.repositoryDefaultsKey)
			chooseRepository()
			return
		}

		guard ManagedExternalWindow.permissionStatus(prompt: false) == .authorized else {
			state = .permissionRequired
			_ = ManagedExternalWindow.permissionStatus(prompt: true)
			return
		}

		launch(repositoryURL: repositoryURL)
	}

	func retryPermission() {
		connect()
	}

	func applicationDidBecomeActive() {
		if case .releasePending = state {
			release()
			return
		}
		guard state == .permissionRequired,
			ManagedExternalWindow.permissionStatus(prompt: false) == .authorized
		else {
			return
		}
		connect()
	}

	func updateHostWindow(_ window: NSWindow?) {
		geometryTask?.cancel()

		guard let window else {
			if case .attached = state {
				release()
			} else if case .releasePending = state {
				release()
			}
			if case .releasePending = state {
				return
			}
			hostWindow = nil
			return
		}
		hostWindow = window
		if case .releasePending = state {
			release()
			return
		}

		guard case .attached = state, !isApplyingLayout else { return }
		geometryTask = Task { @MainActor [weak self] in
			do {
				try await Task.sleep(for: Self.geometryDebounce)
				guard !Task.isCancelled, let self else { return }
				let snapshot: ManagedExternalWindowSnapshot = try self.applyAdjacentLayout(
					hostWindow: window
				)
				self.state = .attached(snapshot)
			} catch is CancellationError {
				return
			} catch {
				self?.failConnection(error.localizedDescription)
			}
		}
	}

	func focus() {
		do {
			try managedWindow.focusAndRaise()
		} catch {
			failConnection(error.localizedDescription)
		}
	}

	func release() {
		connectionGeneration &+= 1
		launchTask?.cancel()
		launchTask = nil
		geometryTask?.cancel()
		geometryTask = nil
		guard managedWindow.release(restoringOriginalFrame: true) else {
			state = .releasePending(
				"Teaser could not safely verify and restore Zed. Return it to this Space, then retry."
			)
			return
		}
		restoreHostWindow()
		state = .disconnected
	}

	func terminate() {
		release()
	}

	private func launch(repositoryURL: URL) {
		connectionGeneration &+= 1
		let generation: UInt = connectionGeneration
		launchTask?.cancel()
		guard managedWindow.release(restoringOriginalFrame: true) else {
			state = .releasePending(
				"Teaser must safely restore the existing Zed window before reconnecting."
			)
			return
		}
		restoreHostWindow()
		state = .launching

		guard let applicationURL: URL = NSWorkspace.shared.urlForApplication(
			withBundleIdentifier: Self.zedBundleIdentifier
		) else {
			state = .failed("Zed.app is not installed")
			return
		}

		let configuration: NSWorkspace.OpenConfiguration = .init()
		configuration.activates = false
		configuration.createsNewApplicationInstance = false
		configuration.promptsUserIfNeeded = true

		NSWorkspace.shared.open(
			[repositoryURL],
			withApplicationAt: applicationURL,
			configuration: configuration
		) { [weak self] application, error in
			let processIdentifier: pid_t? = application?.processIdentifier
			let errorDescription: String? = error?.localizedDescription
			Task { @MainActor [weak self] in
				self?.didOpenRepository(
					processIdentifier: processIdentifier,
					errorDescription: errorDescription,
					generation: generation
				)
			}
		}
	}

	private func chooseRepository() {
		let panel: NSOpenPanel = .init()
		panel.title = "Connect Zed"
		panel.message = "Choose the project folder Zed should open. Teaser remembers this binding."
		panel.prompt = "Connect"
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.allowsMultipleSelection = false
		panel.canCreateDirectories = false

		guard panel.runModal() == .OK, let selectedURL: URL = panel.url else {
			return
		}
		let standardizedURL: URL = selectedURL.standardizedFileURL
		repositoryURL = standardizedURL
		UserDefaults.standard.set(
			standardizedURL.path,
			forKey: Self.repositoryDefaultsKey
		)
		connect()
	}

	private func didOpenRepository(
		processIdentifier: pid_t?,
		errorDescription: String?,
		generation: UInt
	) {
		guard generation == connectionGeneration else { return }
		if let errorDescription {
			state = .failed(errorDescription)
			return
		}
		guard let processIdentifier, let repositoryURL else {
			state = .failed("Zed did not return a running application")
			return
		}

		state = .locating
		launchTask = Task { @MainActor [weak self] in
			guard let self else { return }
			var lastError: String = "No matching Zed window appeared"

			for _ in 0 ..< Self.locateAttempts {
				guard !Task.isCancelled,
					generation == self.connectionGeneration
				else {
					return
				}
				do {
					var snapshot: ManagedExternalWindowSnapshot = try self.managedWindow.bind(
						applicationPID: processIdentifier,
						repositoryURL: repositoryURL
					)
					guard let hostWindow: NSWindow = self.hostWindow else {
						self.managedWindow.release(restoringOriginalFrame: true)
						throw ZedLayoutError.hostWindowUnavailable
					}
					snapshot = try self.applyAdjacentLayout(hostWindow: hostWindow)
					self.state = .attached(snapshot)
					return
				} catch {
					lastError = error.localizedDescription
					guard self.managedWindow.release(restoringOriginalFrame: true) else {
						self.state = .releasePending(
							"Teaser could not safely restore Zed after a failed layout attempt."
						)
						return
					}
					self.restoreHostWindow()
				}

				do {
					try await Task.sleep(for: Self.locateInterval)
				} catch {
					return
				}
			}

			guard self.managedWindow.release(restoringOriginalFrame: true) else {
				self.state = .releasePending(
					"Teaser could not safely restore Zed after window discovery timed out."
				)
				return
			}
			self.restoreHostWindow()
			self.state = .failed(lastError)
		}
	}

	private func handleManagedWindowEvent(_ event: ManagedExternalWindowEvent) {
		switch event {
		case .moved, .resized:
			guard case .attached = state, let hostWindow else { return }
			updateHostWindow(hostWindow)
		case .destroyed:
			failConnection("The connected Zed window was closed")
		}
	}

	private func applyAdjacentLayout(
		hostWindow: NSWindow
	) throws -> ManagedExternalWindowSnapshot {
		guard let screen: NSScreen = hostWindow.screen ?? NSScreen.main else {
			throw ZedLayoutError.screenUnavailable
		}
		let availableFrame: CGRect = screen.visibleFrame.insetBy(dx: 8, dy: 8)
		guard let layout: ManagedExternalWindowAdjacentLayout =
			managedExternalWindowAdjacentLayout(
				in: availableFrame,
				minimumHostWidth: hostWindow.minSize.width,
				minimumExternalWidth: Self.minimumExternalWindowWidth
			)
		else {
			throw ZedLayoutError.screenUnavailable
		}

		if originalHostFrame == nil {
			originalHostFrame = hostWindow.frame
		}
		isApplyingLayout = true
		defer { isApplyingLayout = false }
		hostWindow.setFrame(layout.hostFrame, display: true, animate: false)
		let appliedHostFrame: CGRect = hostWindow.frame
		lastAppliedHostFrame = appliedHostFrame
		guard managedExternalWindowFramesAreApproximatelyEqual(
			appliedHostFrame,
			layout.hostFrame,
			tolerance: 2
		) else {
			restoreHostWindow()
			throw ZedLayoutError.hostWindowCannotFit(
				requested: layout.hostFrame,
				actual: appliedHostFrame
			)
		}

		do {
			return try managedWindow.apply(
				appKitScreenFrame: layout.externalFrame
			)
		} catch {
			restoreHostWindow()
			throw error
		}
	}

	private func restoreHostWindow() {
		defer {
			originalHostFrame = nil
			lastAppliedHostFrame = nil
		}
		guard let hostWindow,
			let originalHostFrame,
			let lastAppliedHostFrame,
			managedExternalWindowFramesAreApproximatelyEqual(
				hostWindow.frame,
				lastAppliedHostFrame,
				tolerance: 2
			)
		else {
			return
		}
		let wasApplyingLayout: Bool = isApplyingLayout
		isApplyingLayout = true
		hostWindow.setFrame(originalHostFrame, display: true, animate: false)
		isApplyingLayout = wasApplyingLayout
	}

	private func failConnection(_ message: String) {
		launchTask?.cancel()
		launchTask = nil
		geometryTask?.cancel()
		geometryTask = nil
		guard managedWindow.release(restoringOriginalFrame: true) else {
			state = .releasePending(
				"\(message) Teaser is waiting to safely restore the same Zed window."
			)
			return
		}
		restoreHostWindow()
		state = .failed(message)
	}
}
