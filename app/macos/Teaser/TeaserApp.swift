import AppKit
import KeyboardShortcuts

@MainActor
public enum TeaserMain {
	public static func main() {
		if Array(CommandLine.arguments.dropFirst()) == ["--check-bundle-resources"] {
			// Exercises the upstream localization accessor without NSApplication,
			// global shortcuts, Accessibility, or desktop-window observation. A
			// missing strings table silently yields the capitalized key instead.
			let description: String = KeyboardShortcuts.Shortcut(.space).description
			print("KeyboardShortcuts resources: \(description)")
			if description == "space_key".capitalized {
				fputs("error: the KeyboardShortcuts strings table is missing from the bundle\n", stderr)
				Darwin.exit(1)
			}
			return
		}
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
enum TeaserMainMenu {
	/// macOS delivers Command-C by matching a menu item's key equivalent, so
	/// without an Edit menu selectable text can be highlighted and never copied.
	/// Every failure Teaser reports is text a person needs to be able to copy.
	static func make() -> NSMenu {
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

		let editMenuItem: NSMenuItem = .init()
		let editMenu: NSMenu = .init(title: "Edit")
		editMenu.addItem(
			.init(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
		)
		editMenu.addItem(
			.init(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
		)
		editMenu.addItem(
			.init(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
		)
		editMenu.addItem(
			.init(
				title: "Select All",
				action: #selector(NSText.selectAll(_:)),
				keyEquivalent: "a"
			)
		)
		editMenuItem.submenu = editMenu
		mainMenu.addItem(editMenuItem)

		return mainMenu
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
		NSApplication.shared.mainMenu = TeaserMainMenu.make()
	}
}
