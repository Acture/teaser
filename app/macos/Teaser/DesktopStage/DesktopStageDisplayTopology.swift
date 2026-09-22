import AppKit
import CoreGraphics
import Foundation

struct DesktopStageDisplay: Equatable, Sendable {
	let id: DisplayID
	let frame: LayoutRect
}

enum DesktopStageDisplayTopology {
	@MainActor
	static func connectedDisplays() -> [DesktopStageDisplay] {
		let mainScreen: NSScreen? = NSScreen.main
		let displays: [(isMain: Bool, display: DesktopStageDisplay)] = NSScreen.screens
			.compactMap { screen in
				guard let display: DesktopStageDisplay = display(for: screen) else {
					return nil
				}
				return (screen === mainScreen, display)
			}
			.sorted { first, second in
				if first.isMain != second.isMain {
					return first.isMain
				}
				if first.display.frame.minX != second.display.frame.minX {
					return first.display.frame.minX < second.display.frame.minX
				}
				if first.display.frame.minY != second.display.frame.minY {
					return first.display.frame.minY < second.display.frame.minY
				}
				return first.display.id.rawValue < second.display.id.rawValue
			}

		var seen: Set<DisplayID> = []
		return displays.compactMap { entry in
			guard seen.insert(entry.display.id).inserted else {
				return nil
			}
			return entry.display
		}
	}

	/// Keeps the presentation addressing canvases that still exist. A canvas is
	/// a window, not a monitor, so there is nothing to rebalance across physical
	/// displays here: the only real case is a canvas whose ID is gone, whose
	/// Panels would otherwise be stranded in a tree nothing solves.
	static func adapt(
		_ presentation: WorkspacePresentation,
		to displays: [DesktopStageDisplay]
	) -> (presentation: WorkspacePresentation, changed: Bool) {
		let displays: [DesktopStageDisplay] = uniqueDisplays(displays)
		guard !displays.isEmpty else { return (presentation, false) }
		let connected: Set<DisplayID> = .init(displays.map(\.id))
		let dropped: [DisplayID] = presentation.canvases.keys
			.filter { !connected.contains($0) }
			.sorted { $0.rawValue < $1.rawValue }
		guard !dropped.isEmpty else { return (presentation, false) }

		// The lowest-sorting connected canvas takes them, so the result does not
		// depend on dictionary order.
		guard let hostID: DisplayID = connected.sorted(by: {
			$0.rawValue < $1.rawValue
		}).first else { return (presentation, false) }

		var adapted: WorkspacePresentation = presentation
		var host: CanvasLayout = adapted.canvases[hostID] ?? .init(displayID: hostID)
		for displayID: DisplayID in dropped {
			let orphans: [PanelID] = adapted.canvases[displayID]?.panelTree?.leaves ?? []
			adapted.canvases.removeValue(forKey: displayID)
			for panelID: PanelID in orphans {
				if let tree: LayoutTree<PanelID> = host.panelTree {
					host.panelTree = .split(
						id: .init("display-topology.\(hostID.rawValue).\(panelID.rawValue)"),
						axis: .horizontal,
						preference: .derived,
						first: tree,
						second: .leaf(panelID)
					)
				} else {
					host.panelTree = .leaf(panelID)
				}
			}
		}
		adapted.canvases[hostID] = host
		return (adapted, adapted != presentation)
	}

	@MainActor
	private static func display(for screen: NSScreen) -> DesktopStageDisplay? {
		let screenNumberKey: NSDeviceDescriptionKey = .init("NSScreenNumber")
		guard let screenNumber: NSNumber = screen.deviceDescription[screenNumberKey]
			as? NSNumber
		else {
			return nil
		}

		let directDisplayID: CGDirectDisplayID = .init(screenNumber.uint32Value)
		guard let unmanagedUUID: Unmanaged<CFUUID> =
			CGDisplayCreateUUIDFromDisplayID(directDisplayID)
		else {
			return nil
		}
		let displayUUID: CFUUID = unmanagedUUID.takeRetainedValue()
		let displayUUIDString: String = CFUUIDCreateString(nil, displayUUID) as String
		let frame: NSRect = screen.visibleFrame
		return .init(
			id: .init(displayUUIDString.lowercased()),
			frame: .init(
				x: Double(frame.origin.x),
				y: Double(frame.origin.y),
				width: Double(frame.size.width),
				height: Double(frame.size.height)
			)
		)
	}

	private static func uniqueDisplays(
		_ displays: [DesktopStageDisplay]
	) -> [DesktopStageDisplay] {
		var seen: Set<DisplayID> = []
		return displays.filter { seen.insert($0.id).inserted }
	}
}
