import Darwin
import Foundation

private enum TestFailure: Error, CustomStringConvertible {
	case assertion(String)

	var description: String {
		switch self {
		case .assertion(let message):
			return message
		}
	}
}

private func expect(
	_ condition: @autoclosure () -> Bool,
	_ message: String
) throws {
	guard condition() else {
		throw TestFailure.assertion(message)
	}
}

private func display(
	_ id: String,
	x: Double,
	width: Double = 6_000,
	height: Double = 2_400
) -> DesktopStageDisplay {
	.init(
		id: .init(id),
		frame: .init(x: x, y: 0, width: width, height: height)
	)
}

private func testCurrentTopologyIsNotRewritten() throws {
	let display: DesktopStageDisplay = display(
		ShowcasePreset.mainDisplayID.rawValue,
		x: 0
	)
	let original: WorkspacePresentation = ShowcasePreset.presentation(
		displayID: display.id
	)
	let result: (presentation: WorkspacePresentation, changed: Bool) =
		DesktopStageDisplayTopology.adapt(original, to: [display])

	try expect(!result.changed, "a current saved topology must remain untouched")
	try expect(
		result.presentation == original,
		"a no-op adaptation must preserve every saved ratio and split ID"
	)
}

private func testChangedTopologyIsBalancedWithoutStraddling() throws {
	let savedDisplay: DisplayID = .init("saved-display")
	let original: WorkspacePresentation = ShowcasePreset.presentation(
		displayID: savedDisplay
	)
	let expectedOrder: [WorkspaceID] = original.displayLayouts[
		savedDisplay
	]!.workspaceTree.leaves
	let displays: [DesktopStageDisplay] = [
		display("new-main", x: 0),
		display("new-secondary", x: 6_000),
	]
	let result: (presentation: WorkspacePresentation, changed: Bool) =
		DesktopStageDisplayTopology.adapt(original, to: displays)

	try expect(result.changed, "a disconnected saved display must trigger adaptation")
	try expect(
		Set(result.presentation.displayLayouts.keys) == Set(displays.map(\.id)),
		"only connected displays may own Workspace trees"
	)
	let firstIDs: [WorkspaceID] = result.presentation.displayLayouts[
		displays[0].id
	]!.workspaceTree.leaves
	let secondIDs: [WorkspaceID] = result.presentation.displayLayouts[
		displays[1].id
	]!.workspaceTree.leaves
	try expect(firstIDs.count == 3, "six Workspaces must split evenly across two displays")
	try expect(secondIDs.count == 3, "six Workspaces must split evenly across two displays")
	try expect(
		firstIDs + secondIDs == expectedOrder,
		"adaptation must preserve saved Workspace order"
	)

	let displayFrames: [DisplayID: LayoutRect] = Dictionary(
		uniqueKeysWithValues: displays.map { ($0.id, $0.frame) }
	)
	let layout: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: result.presentation,
		displayFrames: displayFrames
	)
	for display: DesktopStageDisplay in displays {
		let workspaceIDs: [WorkspaceID] = result.presentation.displayLayouts[
			display.id
		]!.workspaceTree.leaves
		for workspaceID: WorkspaceID in workspaceIDs {
			try expect(
				result.presentation.workspaces[workspaceID]?.displayAffinity
					== display.id,
				"Workspace affinity must follow its rebuilt display tree"
			)
			try expect(
				display.frame.contains(layout.workspaceFrames[workspaceID]!),
				"a Workspace must never straddle displays"
			)
		}
	}
}

private func testMissingWorkspacesAreAppendedDeterministically() throws {
	let display: DesktopStageDisplay = display(
		ShowcasePreset.mainDisplayID.rawValue,
		x: 0
	)
	var malformed: WorkspacePresentation = ShowcasePreset.presentation(
		displayID: display.id
	)
	try malformed.displayLayouts[display.id]!.workspaceTree.remove(
		ShowcasePreset.researchWorkspaceID
	)
	try malformed.displayLayouts[display.id]!.workspaceTree.remove(
		ShowcasePreset.paperWorkspaceID
	)
	let savedOrder: [WorkspaceID] = malformed.displayLayouts[
		display.id
	]!.workspaceTree.leaves
	let expectedMissing: [WorkspaceID] = [
		ShowcasePreset.paperWorkspaceID,
		ShowcasePreset.researchWorkspaceID,
	]

	let first: (presentation: WorkspacePresentation, changed: Bool) =
		DesktopStageDisplayTopology.adapt(malformed, to: [display])
	let second: (presentation: WorkspacePresentation, changed: Bool) =
		DesktopStageDisplayTopology.adapt(malformed, to: [display])
	try expect(first.changed, "an unplaced Workspace makes saved topology stale")
	try expect(
		first.presentation.displayLayouts[display.id]!.workspaceTree.leaves
			== savedOrder + expectedMissing,
		"unplaced Workspaces must follow saved order in stable ID order"
	)
	try expect(
		first.presentation == second.presentation,
		"the rebuilt balanced topology must be deterministic"
	)

	let stable: (presentation: WorkspacePresentation, changed: Bool) =
		DesktopStageDisplayTopology.adapt(first.presentation, to: [display])
	try expect(!stable.changed, "a rebuilt topology must be stable on the next launch")
	try expect(
		stable.presentation == first.presentation,
		"a stable second pass must not rebuild the balanced tree"
	)
}

do {
	try testCurrentTopologyIsNotRewritten()
	try testChangedTopologyIsBalancedWithoutStraddling()
	try testMissingWorkspacesAreAppendedDeterministically()
	print("Teaser desktop-stage topology tests passed")
} catch {
	fputs("Teaser desktop-stage topology tests failed: \(error)\n", stderr)
	exit(1)
}
