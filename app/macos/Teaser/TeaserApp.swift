import AppKit

@main
@MainActor
enum TeaserMain {
	static func main() {
		if let exitCode: Int32 = ExternalWindowInspection.run(arguments: Array(CommandLine.arguments.dropFirst())) {
			Darwin.exit(exitCode)
		}
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
	private var desktopStage: DesktopStageController?

	func applicationDidFinishLaunching(_ notification: Notification) {
		installMainMenu()
		let desktopStage: DesktopStageController = .init()
		self.desktopStage = desktopStage
		desktopStage.start()
	}

	func applicationDidBecomeActive(_ notification: Notification) {
		desktopStage?.applicationDidBecomeActive()
	}

	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		desktopStage?.showControls()
		return true
	}

	func applicationWillTerminate(_ notification: Notification) {
		desktopStage?.stop()
		desktopStage = nil
	}

	func applicationShouldTerminateAfterLastWindowClosed(
		_ sender: NSApplication
	) -> Bool {
		false
	}

	private func installMainMenu() {
		let mainMenu: NSMenu = .init()
		let applicationMenuItem: NSMenuItem = .init()
		let applicationMenu: NSMenu = .init(title: "Teaser")
		applicationMenu.addItem(
			.init(
				title: "Quit Teaser",
				action: #selector(NSApplication.terminate(_:)),
				keyEquivalent: "q"
			)
		)
		applicationMenuItem.submenu = applicationMenu
		mainMenu.addItem(applicationMenuItem)
		NSApplication.shared.mainMenu = mainMenu
	}
}
