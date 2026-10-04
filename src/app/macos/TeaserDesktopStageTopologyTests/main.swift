import Darwin
import Foundation
@testable import TeaserKit

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

/// A canvas is a window, not a monitor, so a presentation already addressing
/// canvases that exist has nothing to adapt.
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

/// The one case that is real: a canvas whose ID is gone. Its Panels would
/// otherwise sit in a tree no canvas rectangle is ever solved for, so they are
/// adopted by a canvas that still exists rather than disappearing.
private func testPanelsOfAVanishedCanvasAreAdopted() throws {
	let saved: DisplayID = .init("saved-display")
	let original: WorkspacePresentation = ShowcasePreset.presentation(
		displayID: saved
	)
	let placed: [PanelID] = original.panelIDs(onCanvas: saved)
	try expect(placed.count == 9, "the fixture places nine Panels")

	let live: DesktopStageDisplay = display("live-display", x: 0)
	let result: (presentation: WorkspacePresentation, changed: Bool) =
		DesktopStageDisplayTopology.adapt(original, to: [live])

	try expect(result.changed, "a vanished canvas must be adapted away")
	try expect(
		result.presentation.canvases[saved] == nil,
		"the vanished canvas must not remain addressable"
	)
	try expect(
		Set(result.presentation.panelIDs(onCanvas: live.id)) == Set(placed),
		"every Panel must land on a canvas that still exists"
	)
	// Membership is not placement: adopting a canvas's Panels must not regroup
	// any of them.
	for panelID: PanelID in placed {
		try expect(
			result.presentation.workspaceID(of: panelID)
				== original.workspaceID(of: panelID),
			"adoption must not change \(panelID.rawValue)'s group"
		)
	}

	let again: (presentation: WorkspacePresentation, changed: Bool) =
		DesktopStageDisplayTopology.adapt(result.presentation, to: [live])
	try expect(!again.changed, "a second pass must be stable")
	try expect(
		again.presentation == result.presentation,
		"a stable second pass must not rebuild the tree"
	)
}

/// With several canvases alive, the orphans go to one of them by a rule that
/// does not depend on dictionary order.
private func testAdoptionIsDeterministic() throws {
	let saved: DisplayID = .init("zz-vanished")
	let original: WorkspacePresentation = ShowcasePreset.presentation(
		displayID: saved
	)
	let displays: [DesktopStageDisplay] = [
		display("bbb", x: 0),
		display("aaa", x: 6_000),
	]
	let first: (presentation: WorkspacePresentation, changed: Bool) =
		DesktopStageDisplayTopology.adapt(original, to: displays)
	let second: (presentation: WorkspacePresentation, changed: Bool) =
		DesktopStageDisplayTopology.adapt(original, to: displays.reversed())
	try expect(
		first.presentation == second.presentation,
		"adoption must not depend on the order displays are reported in"
	)
	try expect(
		!first.presentation.panelIDs(onCanvas: .init("aaa")).isEmpty,
		"the lowest-sorting canvas takes the orphans"
	)
}

do {
	try testCurrentTopologyIsNotRewritten()
	try testPanelsOfAVanishedCanvasAreAdopted()
	try testAdoptionIsDeterministic()
	print("Teaser desktop-stage topology tests passed")
} catch {
	fputs("Teaser desktop-stage topology tests failed: \(error)\n", stderr)
	exit(1)
}
