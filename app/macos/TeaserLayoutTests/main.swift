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

private func expectApproximatelyEqual(
	_ actual: Double,
	_ expected: Double,
	tolerance: Double = 0.000_001,
	_ message: String
) throws {
	try expect(
		abs(actual - expected) <= tolerance,
		"\(message): expected \(expected), got \(actual)"
	)
}

private func assertNoOverlap<ID: Hashable>(
	_ frames: [ID: LayoutRect],
	_ message: String
) throws {
	let values: [(ID, LayoutRect)] = frames.map { ($0.key, $0.value) }
	for firstIndex: Int in values.indices {
		for secondIndex: Int in values.indices where secondIndex > firstIndex {
			try expect(
				!values[firstIndex].1.intersects(values[secondIndex].1),
				message
			)
		}
	}
}

private func panelDescriptor(
	_ panelID: PanelID,
	in presentation: WorkspacePresentation
) throws -> PanelDescriptor {
	guard let panel: PanelDescriptor = presentation.workspaces.values
		.lazy
		.compactMap({ $0.panels[panelID] })
		.first
	else {
		throw TestFailure.assertion("missing Panel descriptor \(panelID.rawValue)")
	}
	return panel
}

private func testShowcaseFillsWithoutOverlap() throws {
	let displayID: DisplayID = .init("display-1")
	let displayFrame: LayoutRect = .init(
		x: -160,
		y: 24,
		width: 2_560,
		height: 1_400
	)
	let presentation: WorkspacePresentation = ShowcasePreset.presentation(
		displayID: displayID
	)
	let layout: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation,
		displayFrames: [displayID: displayFrame]
	)

	try expect(layout.workspaceFrames.count == 6, "showcase must contain six Workspaces")
	try expect(layout.panelFrames.count == 9, "showcase must contain nine Panels")
	try expect(layout.dividers.count == 8, "all slicing-tree dividers must be exposed")
	try assertNoOverlap(layout.workspaceFrames, "Workspace frames must not overlap")

	let workspaceArea: Double = layout.workspaceFrames.values.reduce(0) {
		$0 + $1.size.area
	}
	let workspaceDividerArea: Double = layout.dividers
		.filter { $0.scope == .display(displayID) }
		.reduce(0) { $0 + $1.frame.size.area }
	try expectApproximatelyEqual(
		workspaceArea + workspaceDividerArea,
		displayFrame.size.area,
		"Workspaces and gutters must exactly fill the display"
	)

	for workspaceID: WorkspaceID in presentation.workspaces.keys {
		guard let workspace: WorkspaceDescriptor = presentation.workspaces[workspaceID],
			let workspaceFrame: LayoutRect = layout.workspaceFrames[workspaceID]
		else {
			throw TestFailure.assertion("missing solved Workspace")
		}
		let frames: [PanelID: LayoutRect] = layout.panelFrames.filter {
			workspace.panels[$0.key] != nil
		}
		try assertNoOverlap(frames, "Panels in one Workspace must not overlap")
		let panelArea: Double = frames.values.reduce(0) { $0 + $1.size.area }
		let dividerArea: Double = layout.dividers
			.filter { $0.scope == .workspace(workspaceID) }
			.reduce(0) { $0 + $1.frame.size.area }
		try expectApproximatelyEqual(
			panelArea + dividerArea,
			workspaceFrame.size.area,
			"Panels and gutters must exactly fill Workspace \(workspaceID.rawValue)"
		)
		for (panelID, frame): (PanelID, LayoutRect) in frames {
			let panel: PanelDescriptor = try panelDescriptor(panelID, in: presentation)
			let profile: LayoutProfile = panel.profileOverride
				?? presentation.panelKinds.definition(for: panel.kindID)!.defaultProfile
			try expect(
				frame.size.width + 0.000_001 >= profile.minimumSize.width,
				"Panel minimum width must be enforced"
			)
			try expect(
				frame.size.height + 0.000_001 >= profile.minimumSize.height,
				"Panel minimum height must be enforced"
			)
		}
	}

	let zedFrame: LayoutRect = layout.panelFrames[ShowcasePreset.zedPanelID]!
	let linearFrame: LayoutRect = layout.panelFrames[ShowcasePreset.linearPanelID]!
	try expect(
		zedFrame.size.width != linearFrame.size.width,
		"heterogeneous Panel profiles must not collapse to equal columns"
	)
	try expect(layout.quality.totalAspectRatioDeviation.isFinite, "quality must be finite")
}

private func testLayoutIsDeterministic() throws {
	let displayID: DisplayID = .init("display")
	let presentation: WorkspacePresentation = ShowcasePreset.presentation(
		displayID: displayID
	)
	let frames: [DisplayID: LayoutRect] = [
		displayID: .init(x: 0, y: 0, width: 2_560, height: 1_400),
	]
	let first: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation,
		displayFrames: frames
	)
	let second: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation,
		displayFrames: frames
	)
	try expect(first == second, "identical inputs must produce identical layouts")
}

private func testEdgeInsertionAndLongAxisSplit() throws {
	var presentation: WorkspacePresentation = ShowcasePreset.presentation()
	let panel: PanelDescriptor = .init(
		id: .init("foch-shell"),
		title: "Shell",
		kindID: .generic,
		providerHint: .init(
			displayName: "Terminal",
			bundleIdentifier: "com.apple.Terminal",
			context: nil
		),
		profileOverride: nil,
		nativeContent: .none
	)
	try presentation.splitPanel(
		ShowcasePreset.claudePanelID,
		with: panel,
		in: ShowcasePreset.fochWorkspaceID,
		targetFrame: .init(x: 0, y: 0, width: 900, height: 400),
		splitID: .init("foch-shell-split")
	)
	let tree: LayoutTree<PanelID> = presentation.workspaces[
		ShowcasePreset.fochWorkspaceID
	]!.panelTree
	guard case .split(_, let axis, _, let first, let second) = tree else {
		throw TestFailure.assertion("splitPanel must replace the target leaf")
	}
	try expect(axis == .horizontal, "Ctrl+D defaults to the target's long axis")
	try expect(first.leaves == [ShowcasePreset.claudePanelID], "old Panel stays first")
	try expect(second.leaves == [panel.id], "new empty Panel is inserted second")

	var edgeTree: LayoutTree<String> = .leaf("target")
	try edgeTree.insert(
		"new",
		at: .top,
		of: "target",
		splitID: .init("top")
	)
	guard case .split(_, let edgeAxis, _, let edgeFirst, let edgeSecond) = edgeTree
	else {
		throw TestFailure.assertion("edge insertion must create a split")
	}
	try expect(edgeAxis == .vertical, "top insertion must use a vertical split")
	try expect(edgeFirst.leaves == ["new"], "top insertion places the new leaf first")
	try expect(edgeSecond.leaves == ["target"], "target follows a top insertion")
}

private func testVirtualFocusSurvivesPresentationRoundTrip() throws {
	var presentation: WorkspacePresentation = ShowcasePreset.presentation()
	let initialFocus: VirtualFocusState = presentation.virtualFocus
	try presentation.focusWorkspace(ShowcasePreset.researchWorkspaceID)
	let focused: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation,
		displayFrames: [
			ShowcasePreset.mainDisplayID: .init(
				x: 0,
				y: 0,
				width: 1_400,
				height: 900
			),
		]
	)
	try expect(focused.workspaceFrames.count == 1, "focus mode solves one Workspace")
	try expect(
		focused.workspaceFrames[ShowcasePreset.researchWorkspaceID]
			== .init(x: 0, y: 0, width: 1_400, height: 900),
		"focused Workspace must fill its display"
	)
	try expect(
		presentation.virtualFocus == initialFocus,
		"layout focus must not steal or rewrite virtual focus"
	)
	presentation.showTiled()
	try expect(presentation.mode == .tiled, "showTiled must restore tiled presentation")
	try expect(
		presentation.virtualFocus == initialFocus,
		"tiled round trip must retain virtual focus"
	)
}

private func testMultiDisplayAffinity() throws {
	let main: DisplayID = .init("main-display")
	let secondary: DisplayID = .init("secondary-display")
	var presentation: WorkspacePresentation = ShowcasePreset.presentation(
		displayID: main
	)
	try presentation.displayLayouts[main]!.workspaceTree.remove(
		ShowcasePreset.sortAndPourWorkspaceID
	)
	presentation.displayLayouts[secondary] = .init(
		displayID: secondary,
		workspaceTree: .leaf(ShowcasePreset.sortAndPourWorkspaceID)
	)
	presentation.workspaces[
		ShowcasePreset.sortAndPourWorkspaceID
	]!.displayAffinity = secondary

	let mainFrame: LayoutRect = .init(x: 0, y: 0, width: 2_560, height: 1_400)
	let secondaryFrame: LayoutRect = .init(
		x: -1_440,
		y: 100,
		width: 1_440,
		height: 900
	)
	let layout: PresentationLayout = try ConstrainedLayoutSolver.solve(
		presentation: presentation,
		displayFrames: [main: mainFrame, secondary: secondaryFrame]
	)
	let sortFrame: LayoutRect = layout.workspaceFrames[
		ShowcasePreset.sortAndPourWorkspaceID
	]!
	try expect(
		secondaryFrame.contains(sortFrame),
		"Workspace must remain on its affine display"
	)
	for workspaceID: WorkspaceID in presentation.workspaces.keys
		where workspaceID != ShowcasePreset.sortAndPourWorkspaceID
	{
		try expect(
			mainFrame.contains(layout.workspaceFrames[workspaceID]!),
			"other Workspaces must stay on the primary display"
		)
	}
}

private func testCodableRoundTripsPresentationAndCustomKinds() throws {
	let customKind: PanelKindDefinition = .init(
		id: .init("custom.timeline"),
		displayName: "Timeline",
		defaultProfile: .init(
			minimumSize: .init(width: 500, height: 180),
			preferredAspectRatio: .init(2.0, 4.0),
			growthWeight: 1.4
		)
	)
	var presentation: WorkspacePresentation = ShowcasePreset.presentation()
	try presentation.panelKinds.register(customKind)
	let data: Data = try JSONEncoder().encode(presentation)
	let decoded: WorkspacePresentation = try JSONDecoder().decode(
		WorkspacePresentation.self,
		from: data
	)
	try expect(decoded == presentation, "presentation must survive a Codable round trip")
	try expect(
		decoded.panelKinds.definition(for: customKind.id) == customKind,
		"custom Panel definitions must be persisted"
	)
}

private func testInfeasibleLayoutFailsAtomically() throws {
	let presentation: WorkspacePresentation = ShowcasePreset.presentation()
	do {
		_ = try ConstrainedLayoutSolver.solve(
			presentation: presentation,
			displayFrames: [
				ShowcasePreset.mainDisplayID: .init(
					x: 0,
					y: 0,
					width: 1_000,
					height: 700
				),
			]
		)
		throw TestFailure.assertion("undersized displays must fail")
	} catch is ConstrainedLayoutError {
		return
	}
}

private func run() throws {
	try testShowcaseFillsWithoutOverlap()
	try testLayoutIsDeterministic()
	try testEdgeInsertionAndLongAxisSplit()
	try testVirtualFocusSurvivesPresentationRoundTrip()
	try testMultiDisplayAffinity()
	try testCodableRoundTripsPresentationAndCustomKinds()
	try testInfeasibleLayoutFailsAtomically()
}

do {
	try run()
	print("Teaser layout tests passed")
} catch {
	fputs("Teaser layout tests failed: \(error)\n", stderr)
	exit(1)
}
