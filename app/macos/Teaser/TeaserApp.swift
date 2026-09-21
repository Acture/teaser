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
	///
	/// The canvas commands live here too, in the menu bar every Mac application
	/// has, rather than in a control window of their own.
	static func make() -> (menu: NSMenu, canvases: NSMenu) {
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

		let fileMenuItem: NSMenuItem = .init()
		let fileMenu: NSMenu = .init(title: "File")
		fileMenu.addItem(
			.init(
				title: "New Canvas",
				action: #selector(TeaserApplicationDelegate.newCanvas(_:)),
				keyEquivalent: "n"
			)
		)
		let newCanvasInSpace: NSMenuItem = .init(
			title: "New Canvas in New Space",
			action: #selector(TeaserApplicationDelegate.newCanvasInNewSpace(_:)),
			keyEquivalent: "N"
		)
		newCanvasInSpace.keyEquivalentModifierMask = [.command, .shift]
		fileMenu.addItem(newCanvasInSpace)
		let reopenCanvas: NSMenuItem = .init(
			title: "Reopen Closed Canvas",
			action: #selector(TeaserApplicationDelegate.reopenClosedCanvas(_:)),
			keyEquivalent: "T"
		)
		reopenCanvas.keyEquivalentModifierMask = [.command, .shift]
		fileMenu.addItem(reopenCanvas)
		fileMenu.addItem(.separator())
		fileMenu.addItem(
			.init(
				title: "Close Canvas",
				action: #selector(NSWindow.performClose(_:)),
				keyEquivalent: "w"
			)
		)
		fileMenuItem.submenu = fileMenu
		mainMenu.addItem(fileMenuItem)

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

		let viewMenuItem: NSMenuItem = .init()
		let viewMenu: NSMenu = .init(title: "View")
		// The canvas window routes this through Teaser's transition gate, so the
		// green button and this item cannot start two transitions at once.
		let enterFullScreen: NSMenuItem = .init(
			title: "Enter Full Screen",
			action: #selector(NSWindow.toggleFullScreen(_:)),
			keyEquivalent: "f"
		)
		enterFullScreen.keyEquivalentModifierMask = [.command, .control]
		viewMenu.addItem(enterFullScreen)
		// Filling the screen keeps the canvas on its Space, which is the only
		// state in which adopted windows can sit inside it.
		let fillScreen: NSMenuItem = .init(
			title: "Fill Screen",
			action: #selector(TeaserApplicationDelegate.toggleFillScreen(_:)),
			keyEquivalent: "\r"
		)
		fillScreen.keyEquivalentModifierMask = [.command, .control]
		viewMenu.addItem(fillScreen)
		viewMenuItem.submenu = viewMenu
		mainMenu.addItem(viewMenuItem)

		let canvasesMenuItem: NSMenuItem = .init()
		// Going to a canvas orders its window front, and macOS switches to the
		// Space that holds it. Teaser never moves a Space itself.
		let canvasesMenu: NSMenu = .init(title: "Window")
		canvasesMenuItem.submenu = canvasesMenu
		mainMenu.addItem(canvasesMenuItem)

		return (mainMenu, canvasesMenu)
	}

	/// Rebuilt whenever canvases open or close, so the list is the canvases that
	/// exist rather than a fixed set of slots.
	static func fill(_ menu: NSMenu, with canvases: [(id: CanvasID, title: String)]) {
		menu.removeAllItems()
		for (index, canvas): (Int, (id: CanvasID, title: String)) in canvases.enumerated() {
			let item: NSMenuItem = .init(
				title: canvas.title,
				action: #selector(TeaserApplicationDelegate.goToCanvas(_:)),
				keyEquivalent: index < 9 ? String(index + 1) : ""
			)
			item.tag = index
			menu.addItem(item)
		}
	}
}

@MainActor
private final class TeaserApplicationDelegate: NSObject, NSApplicationDelegate {
	private var desktopStage: DesktopStageController?

	func applicationDidFinishLaunching(_ notification: Notification) {
		let menus: (menu: NSMenu, canvases: NSMenu) = TeaserMainMenu.make()
		NSApplication.shared.mainMenu = menus.menu
		let desktopStage: DesktopStageController = .init(canvasesMenu: menus.canvases)
		self.desktopStage = desktopStage
		desktopStage.start()
	}

	func applicationDidBecomeActive(_ notification: Notification) {
		desktopStage?.applicationDidBecomeActive()
	}

	/// With every canvas closed the app stays running, so reopening from the
	/// Dock opens a canvas again rather than resurrecting a window that is gone.
	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		desktopStage?.reopenFromDock()
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

	@objc
	fileprivate func newCanvas(_ sender: Any?) {
		desktopStage?.openCanvas(inNewSpace: false)
	}

	@objc
	fileprivate func newCanvasInNewSpace(_ sender: Any?) {
		desktopStage?.openCanvas(inNewSpace: true)
	}

	@objc
	fileprivate func reopenClosedCanvas(_ sender: Any?) {
		desktopStage?.reopenMostRecentlyClosedCanvas()
	}

	@objc
	fileprivate func toggleFillScreen(_ sender: Any?) {
		desktopStage?.toggleFillScreenOnKeyCanvas()
	}

	@objc
	fileprivate func goToCanvas(_ sender: Any?) {
		guard let item: NSMenuItem = sender as? NSMenuItem else { return }
		desktopStage?.goToCanvas(at: item.tag)
	}
}
