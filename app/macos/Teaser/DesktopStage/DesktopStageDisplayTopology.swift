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

	static func adapt(
		_ presentation: WorkspacePresentation,
		to displays: [DesktopStageDisplay]
	) -> (presentation: WorkspacePresentation, changed: Bool) {
		let displays: [DesktopStageDisplay] = uniqueDisplays(displays)
		guard !displays.isEmpty else {
			return (presentation, false)
		}
		guard !isCurrent(presentation, for: displays) else {
			return (presentation, false)
		}

		let workspaceIDs: [WorkspaceID] = orderedWorkspaceIDs(
			in: presentation,
			connectedDisplayIDs: displays.map(\.id)
		)
		var adapted: WorkspacePresentation = presentation
		adapted.displayLayouts = [:]

		guard !workspaceIDs.isEmpty else {
			return (adapted, adapted != presentation)
		}

		let usedDisplayCount: Int = min(displays.count, workspaceIDs.count)
		let minimumCount: Int = workspaceIDs.count / usedDisplayCount
		let remainder: Int = workspaceIDs.count % usedDisplayCount
		var workspaceOffset: Int = 0

		for index: Int in 0..<usedDisplayCount {
			let display: DesktopStageDisplay = displays[index]
			let count: Int = minimumCount + (index < remainder ? 1 : 0)
			let nextOffset: Int = workspaceOffset + count
			let assignedIDs: [WorkspaceID] = Array(
				workspaceIDs[workspaceOffset..<nextOffset]
			)
			let tree: LayoutTree<WorkspaceID> = balancedTree(
				assignedIDs,
				display: display,
				path: "root",
				depth: 0
			)
			adapted.displayLayouts[display.id] = .init(
				displayID: display.id,
				workspaceTree: tree
			)
			for workspaceID: WorkspaceID in assignedIDs {
				adapted.workspaces[workspaceID]?.displayAffinity = display.id
			}
			workspaceOffset = nextOffset
		}

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

	private static func isCurrent(
		_ presentation: WorkspacePresentation,
		for displays: [DesktopStageDisplay]
	) -> Bool {
		let usedDisplayCount: Int = min(
			displays.count,
			presentation.workspaces.count
		)
		let expectedDisplayIDs: Set<DisplayID> = .init(
			displays.prefix(usedDisplayCount).map(\.id)
		)
		guard Set(presentation.displayLayouts.keys) == expectedDisplayIDs else {
			return false
		}

		var placedWorkspaceIDs: Set<WorkspaceID> = []
		for displayID: DisplayID in expectedDisplayIDs {
			guard let layout: DisplayWorkspaceLayout =
				presentation.displayLayouts[displayID],
				layout.displayID == displayID,
				Set(layout.workspaceTree.splitIDs).count
					== layout.workspaceTree.splitIDs.count
			else {
				return false
			}
			for workspaceID: WorkspaceID in layout.workspaceTree.leaves {
				guard let workspace: WorkspaceDescriptor =
					presentation.workspaces[workspaceID],
					workspace.displayAffinity == displayID,
					placedWorkspaceIDs.insert(workspaceID).inserted
				else {
					return false
				}
			}
		}

		return placedWorkspaceIDs == Set(presentation.workspaces.keys)
	}

	private static func orderedWorkspaceIDs(
		in presentation: WorkspacePresentation,
		connectedDisplayIDs: [DisplayID]
	) -> [WorkspaceID] {
		let connectedDisplayIDSet: Set<DisplayID> = .init(connectedDisplayIDs)
		let disconnectedDisplayIDs: [DisplayID] = presentation.displayLayouts.keys
			.filter { !connectedDisplayIDSet.contains($0) }
			.sorted { $0.rawValue < $1.rawValue }
		let savedDisplayOrder: [DisplayID] = connectedDisplayIDs.filter {
			presentation.displayLayouts[$0] != nil
		} + disconnectedDisplayIDs

		var seen: Set<WorkspaceID> = []
		var ordered: [WorkspaceID] = []
		for displayID: DisplayID in savedDisplayOrder {
			guard let tree: LayoutTree<WorkspaceID> = presentation
				.displayLayouts[displayID]?.workspaceTree
			else {
				continue
			}
			for workspaceID: WorkspaceID in tree.leaves
				where presentation.workspaces[workspaceID] != nil
					&& seen.insert(workspaceID).inserted
			{
				ordered.append(workspaceID)
			}
		}

		let missing: [WorkspaceID] = presentation.workspaces.keys
			.filter { !seen.contains($0) }
			.sorted { $0.rawValue < $1.rawValue }
		return ordered + missing
	}

	private static func balancedTree(
		_ workspaceIDs: [WorkspaceID],
		display: DesktopStageDisplay,
		path: String,
		depth: Int
	) -> LayoutTree<WorkspaceID> {
		precondition(!workspaceIDs.isEmpty)
		guard workspaceIDs.count > 1 else {
			return .leaf(workspaceIDs[0])
		}

		let midpoint: Int = workspaceIDs.count / 2
		let firstIDs: [WorkspaceID] = Array(workspaceIDs[..<midpoint])
		let secondIDs: [WorkspaceID] = Array(workspaceIDs[midpoint...])
		let primaryAxis: LayoutAxis = display.frame.size.width
			>= display.frame.size.height ? .horizontal : .vertical
		let axis: LayoutAxis = depth.isMultiple(of: 2)
			? primaryAxis
			: opposite(primaryAxis)
		return .split(
			id: .init("display-topology.\(display.id.rawValue).\(path)"),
			axis: axis,
			preference: .init(
				desiredRatio: Double(firstIDs.count) / Double(workspaceIDs.count)
			),
			first: balancedTree(
				firstIDs,
				display: display,
				path: "\(path).0",
				depth: depth + 1
			),
			second: balancedTree(
				secondIDs,
				display: display,
				path: "\(path).1",
				depth: depth + 1
			)
		)
	}

	private static func opposite(_ axis: LayoutAxis) -> LayoutAxis {
		switch axis {
		case .horizontal:
			return .vertical
		case .vertical:
			return .horizontal
		}
	}
}
