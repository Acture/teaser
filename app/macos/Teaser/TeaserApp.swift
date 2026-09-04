import AppKit
import Foundation
import SwiftUI

enum TeaserWindowMetrics {
	static let minimumSize: CGSize = .init(width: 620, height: 540)
}

@main
@MainActor
enum TeaserMain {
	static func main() {
		let application: NSApplication = .shared
		let delegate: TeaserApplicationDelegate = .init()
		application.delegate = delegate
		application.setActivationPolicy(.regular)
		application.run()
		withExtendedLifetime(delegate) {}
	}
}

@MainActor
private final class TeaserApplicationDelegate: NSObject, NSApplicationDelegate {
	private let state: DemoState = .init()
	private let zedCoordinator: ZedCoordinator
	private var window: NSWindow?

	override init() {
		let repositoryPath: String? = ProcessInfo.processInfo.environment[
			"TEASER_ZED_REPO"
		]
		let repositoryURL: URL? = repositoryPath.map {
			URL(fileURLWithPath: $0, isDirectory: true)
		}
		self.zedCoordinator = .init(repositoryURL: repositoryURL)
		super.init()
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
		installMainMenu()

		let fallbackFrame: NSRect = .init(
			x: 0,
			y: 0,
			width: 1_600,
			height: 900
		)
		let presentationFrame: NSRect = NSScreen.main?.visibleFrame.insetBy(
			dx: 8,
			dy: 8
		) ?? fallbackFrame
		let rootView: DemoView = .init(
			state: state,
			zedCoordinator: zedCoordinator
		)
		let hostingView: NSHostingView<DemoView> = .init(rootView: rootView)
		let window: NSWindow = .init(
			contentRect: presentationFrame,
			styleMask: [
				.titled,
				.closable,
				.miniaturizable,
				.resizable,
			],
			backing: .buffered,
			defer: false
		)
		window.title = "Teaser"
		window.minSize = TeaserWindowMetrics.minimumSize
		window.isOpaque = true
		window.backgroundColor = .init(
			calibratedRed: 0.095,
			green: 0.098,
			blue: 0.105,
			alpha: 1
		)
		window.contentView = hostingView
		window.setFrame(presentationFrame, display: false)
		window.makeKeyAndOrderFront(nil)
		self.window = window

		NSApplication.shared.activate(ignoringOtherApps: true)
	}

	func applicationDidBecomeActive(_ notification: Notification) {
		zedCoordinator.applicationDidBecomeActive()
	}

	func applicationWillTerminate(_ notification: Notification) {
		zedCoordinator.terminate()
	}

	func applicationShouldTerminateAfterLastWindowClosed(
		_ sender: NSApplication
	) -> Bool {
		true
	}

	private func installMainMenu() {
		let mainMenu: NSMenu = .init()
		let applicationMenuItem: NSMenuItem = .init()
		let applicationMenu: NSMenu = .init()
		let quitItem: NSMenuItem = .init(
			title: "Quit Teaser",
			action: #selector(NSApplication.terminate(_:)),
			keyEquivalent: "q"
		)
		applicationMenu.addItem(quitItem)
		applicationMenuItem.submenu = applicationMenu
		mainMenu.addItem(applicationMenuItem)
		NSApplication.shared.mainMenu = mainMenu
	}
}
