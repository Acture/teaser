import AppKit
import Foundation

/// Read-only diagnostics run inside the real signed bundle, with its own AX
/// permission. They never instantiate the stage, prompt, focus, or move windows.
@MainActor
enum ExternalWindowInspection {
	private struct WindowResult: Encodable {
		let windowID: UInt32
		let selectable: Bool
		let layer: Int
		let isOnscreen: Bool
		let frame: CGRect?
		let reason: String?
	}

	private struct Report: Encodable {
		let bundlePath: String
		let accessibilityAuthorized: Bool
		let processIdentifier: Int32
		let ownerBundleIdentifier: String?
		/// False for accessory and prohibited processes — Stage Manager's
		/// `WindowManager`, the Dock, menu-bar agents. Teaser lists no window for
		/// them, so this says why the list is empty.
		let ownerIsRegularApplication: Bool
		let windows: [WindowResult]
	}

	static func run(arguments: [String]) -> Int32? {
		if arguments.first == "--observe-window-drag" {
			guard arguments.count == 3, let pid: Int32 = Int32(arguments[1]), pid > 0,
				let windowID: UInt32 = UInt32(arguments[2]), windowID > 0
			else {
				fputs("usage: Teaser --observe-window-drag PID WINDOW_ID\n", stderr)
				return 2
			}
			return observeDrag(identity: .init(processIdentifier: pid, windowID: windowID))
		}
		guard arguments.first == "--inspect-windows" else { return nil }
		// `front` exists because a terminal-run check cannot keep another
		// application in front: while Stage Manager is on, macOS hides every
		// off-stage application from both Core Graphics and Accessibility, so the
		// frontmost application is the only one a command can ever observe.
		let pid: Int32
		if arguments.count == 2, arguments[1] == "front" {
			guard let frontmost: NSRunningApplication = NSWorkspace.shared.frontmostApplication else {
				fputs("error: macOS reported no frontmost application\n", stderr)
				return 2
			}
			pid = frontmost.processIdentifier
		} else if arguments.count == 2, let parsed: Int32 = Int32(arguments[1]), parsed > 0 {
			pid = parsed
		} else {
			fputs("usage: Teaser --inspect-windows PID|front\n", stderr)
			return 2
		}
		let authorized: Bool = ManagedExternalWindow.permissionStatus(prompt: false) == .authorized
		ExternalWindowDiagnostics.logger.notice("inspection-authorized=\(authorized, privacy: .public) pid=\(pid, privacy: .public)")
		// Unusable windows are listed with their reason rather than omitted: an
		// empty report cannot distinguish "wrong process" from "every window is
		// off-stage", which is exactly what a person needs to know here.
		let windows: [WindowResult] = ManagedExternalWindow.inspectableWindows(processIdentifier: pid)
			.map { window in
				let identity: ExternalWindowIdentity = window.identity
				func rejected(_ reason: String) -> WindowResult {
					.init(windowID: identity.windowID, selectable: false, layer: window.layer,
						isOnscreen: window.isOnscreen, frame: nil, reason: reason)
				}
				guard authorized else {
					return rejected(ManagedExternalWindowError.accessibilityPermissionRequired.localizedDescription)
				}
				guard window.ownerIsRegularApplication else {
					return rejected("""
						Process \(pid) is not an ordinary application: its activation policy is \
						accessory or prohibited, so Teaser never selects its windows.
						""")
				}
				guard window.layer == 0 else {
					return rejected("Window layer \(window.layer) is not the normal application window layer.")
				}
				guard window.isOnscreen else {
					return rejected("""
						macOS reports this window off-screen. It is on another Space, minimized, or \
						held off-stage by Stage Manager; bring it to the current Space and retry.
						""")
				}
				do {
					let selection: ExternalWindowSelection = try ManagedExternalWindow.selectWindow(identity: identity)
					return .init(windowID: identity.windowID, selectable: true, layer: window.layer,
						isOnscreen: window.isOnscreen,
						frame: selection.initialSnapshot.appKitScreenFrame, reason: nil)
				} catch {
					return rejected(error.localizedDescription)
				}
			}
		let report: Report = .init(bundlePath: Bundle.main.bundlePath,
			accessibilityAuthorized: authorized, processIdentifier: pid,
			ownerBundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
			ownerIsRegularApplication: ManagedExternalWindow.isRegularApplication(processIdentifier: pid),
			windows: windows)
		do {
			let encoder: JSONEncoder = .init()
			encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
			print(String(decoding: try encoder.encode(report), as: UTF8.self))
			return windows.contains(where: \.selectable) ? 0 : 1
		} catch {
			fputs("Window inspection could not encode its result: \(error)\n", stderr)
			return 2
		}
	}

	private static func observeDrag(identity: ExternalWindowIdentity) -> Int32 {
		let application: NSApplication = .shared
		application.setActivationPolicy(.prohibited)
		let observer: WindowDragObserver = .init()
		var began: Bool = false
		observer.onDiagnostic = { message in
			print("DIAGNOSTIC \(message)")
			fflush(stdout)
		}
		observer.onEvent = { event in
			switch event {
			case .began(let snapshot) where snapshot.selection.identity == identity:
				began = true
				print("BEGAN window=\(identity.windowID)")
				fflush(stdout)
			case .ended(let snapshot) where snapshot.selection.identity == identity:
				print("ENDED window=\(identity.windowID) began=\(began) frame=\(snapshot.currentSample.windowAppKitScreenFrame)")
				fflush(stdout)
				Darwin.exit(began ? 0 : 1)
			default: break
			}
		}
		do { try observer.start() }
		catch { fputs("OBSERVER FAILED: \(error)\n", stderr); return 1 }
		let timeout: Timer = .init(timeInterval: 20, repeats: false) { _ in
			MainActor.assumeIsolated {
				print("FAIL: no complete drag for window=\(identity.windowID); began=\(began)")
				fflush(stdout)
				Darwin.exit(1)
			}
		}
		RunLoop.main.add(timeout, forMode: .common)
		print("READY: observing window=\(identity.windowID) for 20 seconds; no UI, no adoption")
		fflush(stdout)
		application.run()
		withExtendedLifetime(observer) {}
		return 1
	}
}
