import AppKit
import SwiftUI

@MainActor
struct ScreenFrameReporter: NSViewRepresentable {
	let onWindowChange: @MainActor (NSWindow?) -> Void

	init(_ onWindowChange: @escaping @MainActor (NSWindow?) -> Void) {
		self.onWindowChange = onWindowChange
	}

	func makeNSView(context: Context) -> ScreenFrameReportingView {
		.init(onWindowChange: onWindowChange)
	}

	func updateNSView(_ nsView: ScreenFrameReportingView, context: Context) {
		nsView.update(onWindowChange: onWindowChange)
	}

	static func dismantleNSView(
		_ nsView: ScreenFrameReportingView,
		coordinator: Void
	) {
		nsView.invalidate()
	}
}

@MainActor
final class ScreenFrameReportingView: NSView {
	private var onWindowChange: @MainActor (NSWindow?) -> Void
	private weak var observedWindow: NSWindow?
	private var lastReportedFrame: CGRect?
	private var lastReportedWindowIdentifier: ObjectIdentifier?
	private var hasReportedWindow: Bool = false

	init(onWindowChange: @escaping @MainActor (NSWindow?) -> Void) {
		self.onWindowChange = onWindowChange
		super.init(frame: .zero)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) is unavailable")
	}

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		observeCurrentWindow()
		reportWindow()
	}

	func update(onWindowChange: @escaping @MainActor (NSWindow?) -> Void) {
		self.onWindowChange = onWindowChange
		reportWindow()
	}

	func invalidate() {
		stopObservingWindow()
		publish(window: nil)
	}

	@objc
	private func windowGeometryDidChange(_ notification: Notification) {
		reportWindow()
	}

	private func observeCurrentWindow() {
		guard observedWindow !== window else { return }
		stopObservingWindow()

		guard let window else {
			publish(window: nil)
			return
		}

		observedWindow = window
		let center: NotificationCenter = .default
		center.addObserver(
			self,
			selector: #selector(windowGeometryDidChange(_:)),
			name: NSWindow.didMoveNotification,
			object: window
		)
		center.addObserver(
			self,
			selector: #selector(windowGeometryDidChange(_:)),
			name: NSWindow.didResizeNotification,
			object: window
		)
		center.addObserver(
			self,
			selector: #selector(windowGeometryDidChange(_:)),
			name: NSWindow.didChangeScreenNotification,
			object: window
		)
		center.addObserver(
			self,
			selector: #selector(windowGeometryDidChange(_:)),
			name: NSWindow.didMiniaturizeNotification,
			object: window
		)
		center.addObserver(
			self,
			selector: #selector(windowGeometryDidChange(_:)),
			name: NSWindow.didDeminiaturizeNotification,
			object: window
		)
		center.addObserver(
			self,
			selector: #selector(windowGeometryDidChange(_:)),
			name: NSWindow.didChangeOcclusionStateNotification,
			object: window
		)
		center.addObserver(
			self,
			selector: #selector(windowGeometryDidChange(_:)),
			name: NSApplication.didHideNotification,
			object: NSApplication.shared
		)
		center.addObserver(
			self,
			selector: #selector(windowGeometryDidChange(_:)),
			name: NSApplication.didUnhideNotification,
			object: NSApplication.shared
		)
	}

	private func stopObservingWindow() {
		NotificationCenter.default.removeObserver(self)
		observedWindow = nil
	}

	private func reportWindow() {
		guard let window else {
			publish(window: nil)
			return
		}
		guard !window.isMiniaturized,
			!NSApplication.shared.isHidden,
			window.occlusionState.contains(.visible)
		else {
			return
		}
		publish(window: window)
	}

	private func publish(window: NSWindow?) {
		let identifier: ObjectIdentifier? = window.map(ObjectIdentifier.init)
		let frame: CGRect? = window?.frame
		guard !hasReportedWindow
			|| lastReportedWindowIdentifier != identifier
			|| lastReportedFrame != frame
		else {
			return
		}
		hasReportedWindow = true
		lastReportedWindowIdentifier = identifier
		lastReportedFrame = frame
		onWindowChange(window)
	}
}
