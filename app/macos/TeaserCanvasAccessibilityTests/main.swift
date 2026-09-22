import AppKit
import Darwin
@testable import TeaserKit

// The canvas's published accessibility tree. Publishing elements is the server
// half of accessibility and needs no permission, so none of this prompts,
// reads another process, or shows a window: the cases build a
// `DesktopOverlayView` with a bare frame and read the elements back.

private enum TestFailure: Error, CustomStringConvertible {
	case assertion(String)

	var description: String {
		switch self {
		case .assertion(let message):
			message
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

private func expectEqual(
	_ actual: String?,
	_ expected: String,
	_ message: String
) throws {
	try expect(
		actual == expected,
		"\(message): expected \"\(expected)\", got \"\(actual ?? "nil")\""
	)
}

private func unwrap<Value>(_ value: Value?, _ message: String) throws -> Value {
	guard let value else { throw TestFailure.assertion(message) }
	return value
}

// MARK: - Fixtures

private let canvasA: DisplayID = .init("canvas-a")
private let canvasB: DisplayID = .init("canvas-b")
private let canvasFrame: LayoutRect = .init(x: 100, y: 200, width: 1_200, height: 800)

/// Panels large enough that nothing is below its minimum unless a case makes it
/// so, and wide aspect ranges so the solver has no reason to complain.
private let roomyProfile: LayoutProfile = .init(
	minimumSize: .init(width: 10, height: 10),
	preferredAspectRatio: .init(0.05, 20),
	growthWeight: 1
)

private func panel(
	_ id: String,
	workspace: String,
	title: String? = nil,
	kind: PanelKindID = .generic,
	providerHint: PanelProviderHint? = nil,
	nativeContent: NativePanelContent = .none,
	profile: LayoutProfile? = roomyProfile
) -> PanelDescriptor {
	.init(
		id: .init(id),
		title: title ?? id,
		workspaceID: .init(workspace),
		kindID: kind,
		providerHint: providerHint,
		profileOverride: profile,
		nativeContent: nativeContent
	)
}

/// Two groups on one canvas: Alpha left, Beta right.
private func twoGroupPresentation() throws -> WorkspacePresentation {
	var presentation: WorkspacePresentation = .init(panelKinds: try .init())
	presentation.workspaces[.init("alpha")] = .init(
		id: .init("alpha"), title: "Alpha", detail: ""
	)
	presentation.workspaces[.init("beta")] = .init(
		id: .init("beta"), title: "Beta", detail: ""
	)
	presentation.canvases[canvasA] = .init(displayID: canvasA)
	try presentation.seedPanel(panel("a1", workspace: "alpha"), onCanvas: canvasA)
	try presentation.insertPanel(
		panel("b1", workspace: "beta"),
		onCanvas: canvasA,
		at: .trailing,
		of: .init("a1"),
		splitID: .init("split-1")
	)
	return presentation
}

private func solve(
	_ presentation: WorkspacePresentation,
	frames: [DisplayID: LayoutRect] = [canvasA: canvasFrame]
) throws -> PresentationLayout {
	try ConstrainedLayoutSolver.solve(
		presentation: presentation,
		displayFrames: frames
	)
}

private func snapshot(
	_ presentation: WorkspacePresentation,
	on displayID: DisplayID = canvasA,
	frame: LayoutRect = canvasFrame,
	frames: [DisplayID: LayoutRect] = [canvasA: canvasFrame],
	adopted: Set<PanelID> = [],
	canvases: [DisplayID: CanvasPlacement] = [:]
) throws -> DesktopOverlaySnapshot {
	.init(
		displayID: displayID,
		screenFrame: frame,
		presentation: presentation,
		layout: try solve(presentation, frames: frames),
		adoptedPanelIDs: adopted,
		canvases: canvases,
		arrangeMode: false
	)
}

private func placement(
	_ displayID: DisplayID,
	_ title: String,
	onActiveSpace: Bool = true,
	space: String? = nil
) -> CanvasPlacement {
	.init(
		displayID: displayID,
		title: title,
		isOnActiveSpace: onActiveSpace,
		spaceName: space
	)
}

private func accessiblePanel(
	_ id: String,
	in tree: CanvasAccessibility
) throws -> PanelAccessibility {
	try unwrap(
		tree.panels.first { $0.panelID == .init(id) },
		"the tree must publish an element for Panel \(id)"
	)
}

// MARK: - Group identity

/// The debt P-561 left: a contour tells two groups apart with a hue, and ten
/// hues chosen for normal colour vision tell nobody apart who cannot separate
/// them. The element names the group, so the membership survives without the
/// colour.
private func testEachPanelNamesItsGroup() throws {
	let tree: CanvasAccessibility = try snapshot(twoGroupPresentation())
		.accessibility
	try expect(tree.panels.count == 2, "both placed Panels must be published")
	try expectEqual(
		try accessiblePanel("a1", in: tree).description,
		"Alpha. No binding yet.",
		"a Panel says which group it belongs to"
	)
	try expectEqual(
		try accessiblePanel("b1", in: tree).description,
		"Beta. No binding yet.",
		"the other group is named, not merely a different colour"
	)
}

/// A group with members nobody ever labelled still has to be nameable, so the
/// element falls back to the identity rather than to an empty string.
private func testAnUnlabelledGroupFallsBackToItsIdentifier() throws {
	var presentation: WorkspacePresentation = try twoGroupPresentation()
	presentation.workspaces.removeValue(forKey: .init("alpha"))
	let tree: CanvasAccessibility = try snapshot(presentation).accessibility
	try expectEqual(
		try accessiblePanel("a1", in: tree).description,
		"alpha. No binding yet.",
		"a group with no descriptor is named by its ID, never left blank"
	)
}

/// A split group is one group in two places. The ordinal is what says so, and
/// it is group-wide, so the fragment on the other canvas is counted here.
private func testASplitGroupNumbersItsFragments() throws {
	var presentation: WorkspacePresentation = try twoGroupPresentation()
	presentation.canvases[canvasB] = .init(displayID: canvasB)
	try presentation.seedPanel(
		panel("a2", workspace: "alpha"), onCanvas: canvasB
	)
	let frames: [DisplayID: LayoutRect] = [
		canvasA: canvasFrame,
		canvasB: .init(x: 2_000, y: 200, width: 900, height: 600),
	]
	let first: CanvasAccessibility = try snapshot(
		presentation, frames: frames
	).accessibility
	let second: CanvasAccessibility = try snapshot(
		presentation,
		on: canvasB,
		frame: try unwrap(frames[canvasB], "canvas B must have a frame"),
		frames: frames
	).accessibility
	try expectEqual(
		try accessiblePanel("a1", in: first).description,
		"Alpha, fragment 1 of 2. No binding yet.",
		"a group split across canvases numbers its fragments"
	)
	try expectEqual(
		try accessiblePanel("a2", in: second).description,
		"Alpha, fragment 2 of 2. No binding yet.",
		"the fragment on the other canvas continues the same numbering"
	)
	try expectEqual(
		try accessiblePanel("b1", in: first).description,
		"Beta. No binding yet.",
		"a group that is in one piece is not numbered 1 of 1"
	)
}

/// A Workspace's title is a label the person chose, and nothing in the core
/// stops two of them carrying one. When that happens the spoken name alone
/// puts telling the two apart back on the contour colour — the debt this
/// ticket exists to close — so the identity that cannot collide is said too.
private func testTwoWorkspacesSharingATitleAreStillToldApart() throws {
	var presentation: WorkspacePresentation = try twoGroupPresentation()
	presentation.workspaces[.init("beta")] = .init(
		id: .init("beta"), title: "Alpha", detail: ""
	)
	let tree: CanvasAccessibility = try snapshot(presentation).accessibility
	try expectEqual(
		try accessiblePanel("a1", in: tree).description,
		"Alpha (alpha). No binding yet.",
		"a colliding title is qualified by the identity that cannot collide"
	)
	try expectEqual(
		try accessiblePanel("b1", in: tree).description,
		"Alpha (beta). No binding yet.",
		"the other group reads differently despite the identical label"
	)
	let first: String = try accessiblePanel("a1", in: tree).description
	let second: String = try accessiblePanel("b1", in: tree).description
	try expect(
		first != second,
		"two groups must never say the same thing about themselves"
	)
}

/// The identity is published unconditionally, whether or not the label is
/// ambiguous: an automated read partitions Panels into groups on this, not on
/// a display string a person is free to edit.
private func testEveryPanelPublishesItsWorkspaceIdentity() throws {
	let tree: CanvasAccessibility = try snapshot(twoGroupPresentation())
		.accessibility
	try expectEqual(
		try accessiblePanel("a1", in: tree).workspaceID,
		"alpha",
		"a Panel carries its group's identity, not only its label"
	)
	try expectEqual(
		try accessiblePanel("b1", in: tree).workspaceID,
		"beta",
		"the second group's identity is its own"
	)
	let unambiguous: String = try accessiblePanel("a1", in: tree).description
	try expect(
		!unambiguous.contains("(alpha)"),
		"an unambiguous label is not cluttered with the identity"
	)
}

/// "Fragment 1 of 2" is a dangling reference unless the tree says where the
/// other one is. A canvas not on the active Space publishes no window at all,
/// so it cannot say so about itself — the canvas that can see it must.
private func testASplitGroupSaysWhereItContinues() throws {
	var presentation: WorkspacePresentation = try twoGroupPresentation()
	presentation.canvases[canvasB] = .init(displayID: canvasB)
	try presentation.seedPanel(
		panel("a2", workspace: "alpha"), onCanvas: canvasB
	)
	let frames: [DisplayID: LayoutRect] = [
		canvasA: canvasFrame,
		canvasB: .init(x: 2_000, y: 200, width: 900, height: 600),
	]
	let elsewhere: [DisplayID: CanvasPlacement] = [
		canvasA: placement(canvasA, "Teaser — Canvas 1"),
		canvasB: placement(
			canvasB, "Teaser — Canvas 2", onActiveSpace: false, space: "Desktop 2"
		),
	]
	let here: CanvasAccessibility = try snapshot(
		presentation, frames: frames, canvases: elsewhere
	).accessibility
	try expectEqual(
		try accessiblePanel("a1", in: here).description,
		"Alpha, fragment 1 of 2, continued on Teaser — Canvas 2 (Desktop 2). "
			+ "No binding yet.",
		"a group continuing elsewhere names both the canvas and its Space"
	)
	try expectEqual(
		try accessiblePanel("b1", in: here).description,
		"Beta. No binding yet.",
		"a group that is all here says nothing about other canvases"
	)

	// Seen from the other end, the continuation points back — and Canvas 1 is
	// the canvas doing the reading, so no Space clause.
	let there: CanvasAccessibility = try snapshot(
		presentation,
		on: canvasB,
		frame: try unwrap(frames[canvasB], "canvas B must have a frame"),
		frames: frames,
		canvases: elsewhere
	).accessibility
	try expectEqual(
		try accessiblePanel("a2", in: there).description,
		"Alpha, fragment 2 of 2, continued on Teaser — Canvas 1. No binding yet.",
		"the far fragment names the canvas it came from, without a Space clause"
	)
}

/// A canvas on another Space whose Space nothing could name still has to say
/// that reaching it means leaving this one. Vague beats silent; it is naming a
/// Space wrongly that would send someone to the wrong place.
private func testAnUnnameableSpaceStillSaysItIsAnotherOne() throws {
	var presentation: WorkspacePresentation = try twoGroupPresentation()
	presentation.canvases[canvasB] = .init(displayID: canvasB)
	try presentation.seedPanel(
		panel("a2", workspace: "alpha"), onCanvas: canvasB
	)
	let frames: [DisplayID: LayoutRect] = [
		canvasA: canvasFrame,
		canvasB: .init(x: 2_000, y: 200, width: 900, height: 600),
	]
	let tree: CanvasAccessibility = try snapshot(
		presentation,
		frames: frames,
		canvases: [
			canvasA: placement(canvasA, "Teaser — Canvas 1"),
			canvasB: placement(canvasB, "Teaser — Canvas 2", onActiveSpace: false),
		]
	).accessibility
	try expectEqual(
		try accessiblePanel("a1", in: tree).description,
		"Alpha, fragment 1 of 2, continued on Teaser — Canvas 2 (another "
			+ "Space). No binding yet.",
		"an unnameable Space is still reported as another Space"
	)
}

/// A canvas nothing knows the placement of is said by omission. Inventing a
/// destination would send someone looking for a canvas that may not be open.
private func testAnUnknownCanvasIsLeftUnsaidRatherThanGuessed() throws {
	var presentation: WorkspacePresentation = try twoGroupPresentation()
	presentation.canvases[canvasB] = .init(displayID: canvasB)
	try presentation.seedPanel(
		panel("a2", workspace: "alpha"), onCanvas: canvasB
	)
	let frames: [DisplayID: LayoutRect] = [
		canvasA: canvasFrame,
		canvasB: .init(x: 2_000, y: 200, width: 900, height: 600),
	]
	try expectEqual(
		try accessiblePanel(
			"a1",
			in: try snapshot(presentation, frames: frames).accessibility
		).description,
		"Alpha, fragment 1 of 2. No binding yet.",
		"the fragment is still numbered; only the destination goes unsaid"
	)
}

/// A group interrupted by another group's Panel is two fragments on one
/// canvas. Both are already here, so there is nowhere to send anyone.
private func testAFragmentOnThisCanvasIsNotSomewhereElse() throws {
	var presentation: WorkspacePresentation = try twoGroupPresentation()
	try presentation.insertPanel(
		panel("a3", workspace: "alpha"),
		onCanvas: canvasA,
		at: .trailing,
		of: .init("b1"),
		splitID: .init("split-2")
	)
	let tree: CanvasAccessibility = try snapshot(
		presentation,
		canvases: [canvasA: placement(canvasA, "Teaser — Canvas 1")]
	).accessibility
	try expectEqual(
		try accessiblePanel("a1", in: tree).description,
		"Alpha, fragment 1 of 2. No binding yet.",
		"a locally split group is numbered but sends nobody to another canvas"
	)
}

/// A canvas showing one group draws no contour, because there is nothing to
/// tell apart. That is a drawing rule, not a naming rule: the group is still
/// named, and a fragment on another canvas is still counted.
private func testASingleGroupCanvasStillNamesItsGroup() throws {
	var presentation: WorkspacePresentation = .init(panelKinds: try .init())
	presentation.workspaces[.init("alpha")] = .init(
		id: .init("alpha"), title: "Alpha", detail: ""
	)
	presentation.canvases[canvasA] = .init(displayID: canvasA)
	try presentation.seedPanel(panel("a1", workspace: "alpha"), onCanvas: canvasA)
	let canvas: DesktopOverlaySnapshot = try snapshot(presentation)
	try expect(
		canvas.contours.isEmpty,
		"a canvas showing one group must still draw no contour"
	)
	try expectEqual(
		try accessiblePanel("a1", in: canvas.accessibility).description,
		"Alpha. No binding yet.",
		"suppressing the contour must not suppress the group's name"
	)
}

// MARK: - Binding, focus and frames

/// Empty, adopted window, and Teaser's own Notes are three different things to
/// land on, and none of them is visible in an outline.
private func testBindingStateIsReadable() throws {
	var presentation: WorkspacePresentation = try twoGroupPresentation()
	presentation.panels[.init("b1")]?.nativeContent = .notes
	presentation.panels[.init("a1")]?.providerHint = .init(
		displayName: "Finder", bundleIdentifier: "com.apple.finder", context: nil
	)
	let tree: CanvasAccessibility = try snapshot(
		presentation, adopted: [.init("a1")]
	).accessibility
	let adopted: PanelAccessibility = try accessiblePanel("a1", in: tree)
	try expectEqual(
		adopted.description,
		"Alpha. Adopted window.",
		"a Panel holding a window lease says so"
	)
	try expectEqual(
		adopted.title,
		"Finder · a1",
		"the spoken title is the one the canvas draws, provider included"
	)
	try expectEqual(
		try accessiblePanel("b1", in: tree).description,
		"Beta. Teaser Notes.",
		"Teaser-owned content is not an adopted window"
	)
}

/// Adoption is read from the lease, never guessed. A provider hint is a label
/// the server may hold for a Panel that has adopted nothing.
private func testAProviderHintAloneIsNotAnAdoptedWindow() throws {
	var presentation: WorkspacePresentation = try twoGroupPresentation()
	presentation.panels[.init("a1")]?.providerHint = .init(
		displayName: "Finder", bundleIdentifier: "com.apple.finder", context: nil
	)
	try expectEqual(
		try accessiblePanel("a1", in: try snapshot(presentation).accessibility)
			.description,
		"Alpha. No binding yet.",
		"a hint is not a lease, and the tree must not claim a window"
	)
}

/// Virtual Focus is one Panel for the whole presentation, so at most one
/// element in the whole tree reports focus — and reporting it must stay a
/// statement about the layout selection, never a redirect of native input.
private func testVirtualFocusMarksExactlyOneElement() throws {
	var presentation: WorkspacePresentation = try twoGroupPresentation()
	try presentation.setVirtualFocus(.init("b1"))
	let tree: CanvasAccessibility = try snapshot(presentation).accessibility
	try expect(
		tree.panels.filter(\.isFocused).map(\.panelID) == [.init("b1")],
		"exactly the Panel holding Virtual Focus reports AXFocused"
	)
}

/// A frame is published in the canvas's own coordinates. A screen rectangle
/// would go stale the moment the window moved, and could not be asserted
/// without a window to convert through.
private func testFramesAreCanvasRelativeAndCoverTheCanvas() throws {
	let tree: CanvasAccessibility = try snapshot(twoGroupPresentation())
		.accessibility
	let layout: PresentationLayout = try solve(try twoGroupPresentation())
	for published: PanelAccessibility in tree.panels {
		let solved: LayoutRect = try unwrap(
			layout.panelFrames[published.panelID],
			"every published Panel has a solved frame"
		)
		try expect(
			published.frame.minX == solved.minX - canvasFrame.minX
				&& published.frame.minY == solved.minY - canvasFrame.minY
				&& published.frame.size == solved.size,
			"a published frame is the solved frame, moved into canvas coordinates"
		)
		try expect(
			published.frame.minX >= 0 && published.frame.minY >= 0
				&& published.frame.maxX <= canvasFrame.size.width
				&& published.frame.maxY <= canvasFrame.size.height,
			"no Panel is published outside the canvas it is drawn in"
		)
	}
}

// MARK: - The canvas element

private func testCanvasCountsItsPanelsAndGroups() throws {
	try expectEqual(
		try snapshot(twoGroupPresentation()).accessibility.description,
		"2 Panels in 2 Workspaces.",
		"the canvas reports how much it holds and how many groups that is"
	)
}

private func testABlankCanvasSaysSo() throws {
	var presentation: WorkspacePresentation = .init(panelKinds: try .init())
	presentation.canvases[canvasA] = .init(displayID: canvasA)
	try expectEqual(
		try snapshot(presentation).accessibility.description,
		"No Panels placed.",
		"a blank canvas answers rather than going silent"
	)
}

/// Both focus stages are named, because they are different situations: the
/// first leaves every other Panel usable, the second minimizes their windows.
private func testCanvasNamesItsFocusStage() throws {
	var presentation: WorkspacePresentation = try twoGroupPresentation()
	presentation.focusWorkspace(.init("alpha"), onCanvas: canvasA)
	try expectEqual(
		try snapshot(presentation).accessibility.description,
		"2 Panels in 2 Workspaces. Alpha is emphasised.",
		"the first focus stage is named with the group it emphasises"
	)

	presentation.focusWorkspace(.init("alpha"), onCanvas: canvasA, exclusive: true)
	let exclusive: CanvasAccessibility = try snapshot(presentation).accessibility
	try expectEqual(
		exclusive.description,
		"1 Panel in 1 Workspace. Alpha has the canvas to itself, and the other "
			+ "Workspaces' adopted windows are minimized.",
		"the exclusive stage says what happened to the other Workspaces' windows"
	)
	// The count describes the published tree, not the stored one. An exclusive
	// focus prunes the solve, so claiming two groups would name a group nothing
	// in the tree can be read about.
	try expect(
		exclusive.panels.map(\.panelID) == [.init("a1")],
		"an exclusive focus publishes only the group that has the canvas"
	)
}

// MARK: - Shortfalls

/// A Panel the canvas cannot give its minimum is still placed, and the solve
/// still succeeds. Saying nothing would leave the person to wonder why a Panel
/// looks wrong, so the element carries how far short it is.
private func testAShortPanelSaysHowFarShort() throws {
	var presentation: WorkspacePresentation = try twoGroupPresentation()
	// Bigger than the canvas on both axes, so both halves of the sentence are
	// exercised; the one-short-axis half is pinned separately below.
	presentation.panels[.init("a1")]?.profileOverride = .init(
		minimumSize: .init(width: 2_000, height: 1_000),
		preferredAspectRatio: .init(0.05, 20),
		growthWeight: 1
	)
	let layout: PresentationLayout = try solve(presentation)
	let tree: CanvasAccessibility = try snapshot(presentation).accessibility
	let short: PanelAccessibility = try accessiblePanel("a1", in: tree)
	let frame: LayoutRect = try unwrap(
		layout.panelFrames[.init("a1")],
		"a Panel below its minimum is still placed"
	)
	try expect(
		layout.quality.shortfalls[.init("a1")] != nil,
		"the fixture must actually produce a shortfall"
	)
	// Derived from the solve rather than pinned to a literal, so the case keeps
	// meaning something if the gutters or the canvas size change.
	let missingWidth: Int = Int((2_000 - frame.size.width).rounded())
	let missingHeight: Int = Int((1_000 - frame.size.height).rounded())
	try expect(
		missingWidth > 0 && missingHeight > 0,
		"the fixture must be short on both axes for this case to mean anything"
	)
	try expectEqual(
		short.shortfall,
		"Below its minimum size: \(missingWidth) pt short of width and "
			+ "\(missingHeight) pt short of height. This Panel needs "
			+ "2000×1000 pt.",
		"a Panel below its minimum names the deficit on each short axis"
	)
	let fitting: PanelAccessibility = try accessiblePanel("b1", in: tree)
	try expect(
		fitting.shortfall == nil,
		"a Panel that fits carries no shortfall"
	)
}

/// A deficit the solver records can be a fraction of a point — the split
/// arithmetic produces fractional frames routinely — and rounding one to
/// "0 pt short of width" contradicts the sentence it sits in. Name the axis
/// without inventing a magnitude.
private func testASubPointDeficitDoesNotRoundToZero() throws {
	try expectEqual(
		CanvasAccessibilityWording.shortfall(
			minimum: .init(width: 600, height: 400),
			actual: .init(width: 599.7, height: 900)
		),
		"Below its minimum size: less than 1 pt short of width. This Panel "
			+ "needs 600×400 pt.",
		"a deficit under a point says so rather than reporting zero"
	)
}

/// `LayoutQuality` records a shortfall when either axis is short, so the
/// wording must not claim a deficit of zero on the axis that is fine.
private func testOnlyTheShortAxisIsNamed() throws {
	try expectEqual(
		CanvasAccessibilityWording.shortfall(
			minimum: .init(width: 600, height: 400),
			actual: .init(width: 300, height: 900)
		),
		"Below its minimum size: 300 pt short of width. This Panel needs "
			+ "600×400 pt.",
		"an axis with room to spare is not reported as short"
	)
}

// MARK: - Published elements

/// The elements themselves, built against a real `NSView` with no window: the
/// tree has to exist before anything is drawn and before the canvas is shown.
@MainActor
private func testTheViewPublishesOneGroupPerPanel() throws {
	var presentation: WorkspacePresentation = try twoGroupPresentation()
	presentation.panels[.init("a1")]?.providerHint = .init(
		displayName: "Finder", bundleIdentifier: "com.apple.finder", context: nil
	)
	// Virtual Focus on one Panel and a minimum the canvas cannot grant on the
	// other, so AXTitle, AXFocused and AXHelp are each read off a real element
	// rather than only off the projection that feeds it.
	try presentation.setVirtualFocus(.init("a1"))
	presentation.panels[.init("b1")]?.profileOverride = .init(
		minimumSize: .init(width: 2_000, height: 1_000),
		preferredAspectRatio: .init(0.05, 20),
		growthWeight: 1
	)
	let canvas: DesktopOverlaySnapshot = try snapshot(
		presentation, adopted: [.init("a1")]
	)
	let view: DesktopOverlayView = .init(
		frame: .init(x: 0, y: 0, width: 1_200, height: 800),
		snapshot: canvas,
		callbacks: .init(
			onVirtualFocusChange: { _ in },
			onDividerRatioChange: { _, _, _ in }
		)
	)
	try expect(view.isAccessibilityElement(), "the canvas is an element itself")
	try expect(
		view.accessibilityRole() == .group,
		"the canvas is a group its Panels hang under"
	)
	try expectEqual(
		view.accessibilityLabel(),
		"2 Panels in 2 Workspaces.",
		"the canvas element carries the canvas summary"
	)

	let children: [NSAccessibilityElement] = try unwrap(
		view.accessibilityChildren() as? [NSAccessibilityElement],
		"the canvas publishes accessibility elements"
	)
	try expect(
		children.count == canvas.panels.count,
		"one element per placed Panel, in the order the canvas lays them out"
	)
	let first: NSAccessibilityElement = try unwrap(
		children.first, "the canvas has a first Panel"
	)
	try expect(
		first.accessibilityRole() == .group,
		"a Panel is published as an AXGroup"
	)
	try expectEqual(
		first.accessibilityIdentifier(),
		"a1",
		"an element is addressable by its Panel's own identity"
	)
	try expectEqual(
		first.accessibilityLabel(),
		"Alpha. Adopted window.",
		"the element carries the group and the binding"
	)
	try expectEqual(
		first.accessibilityTitle(),
		"Finder · a1",
		"the element's AXTitle is the title the canvas draws"
	)
	try expectEqual(
		first.accessibilityValue() as? String,
		"alpha",
		"the element carries its group's identity, not only its label"
	)
	try expect(
		first.accessibilityHelp() == nil,
		"a Panel that fits publishes no shortfall help"
	)
	try expect(
		first.isAccessibilityFocused(),
		"the Panel holding Virtual Focus reports AXFocused"
	)
	try expect(
		first.accessibilityParent() as? NSView === view,
		"a Panel element hangs under the canvas"
	)

	let second: NSAccessibilityElement = try unwrap(
		children.last, "the canvas has a second Panel"
	)
	try expect(
		!second.isAccessibilityFocused(),
		"exactly one element reports focus, because Virtual Focus is one Panel"
	)
	try expectEqual(
		second.accessibilityHelp(),
		try unwrap(
			accessiblePanel("b1", in: canvas.accessibility).shortfall,
			"the squeezed Panel has a shortfall to publish"
		),
		"a squeezed Panel publishes its shortfall as AXHelp"
	)
	let published: NSRect = first.accessibilityFrameInParentSpace()
	let solved: LayoutRect = try unwrap(
		canvas.panels.first?.frame, "the first Panel has a frame"
	)
	try expect(
		published.minX == CGFloat(solved.minX - canvasFrame.minX)
			&& published.minY == CGFloat(solved.minY - canvasFrame.minY)
			&& published.width == CGFloat(solved.size.width)
			&& published.height == CGFloat(solved.size.height),
		"an element's frame is its Panel's, in the canvas's own coordinates"
	)
	try expect(
		!NSApplication.shared.windows.contains(where: \.isVisible),
		"building the tree must not show a window"
	)
}

/// A reader holds on to the element it is reading. Handing it a new object on
/// every solve would drop its cursor out of the canvas whenever a divider
/// moved, so an element that survives is mutated rather than replaced.
@MainActor
private func testElementsSurviveASolveAndLeaveWithTheirPanel() throws {
	var presentation: WorkspacePresentation = try twoGroupPresentation()
	let view: DesktopOverlayView = .init(
		frame: .init(x: 0, y: 0, width: 1_200, height: 800),
		snapshot: try snapshot(presentation),
		callbacks: .init(
			onVirtualFocusChange: { _ in },
			onDividerRatioChange: { _, _, _ in }
		)
	)
	let before: [NSAccessibilityElement] = try unwrap(
		view.accessibilityChildren() as? [NSAccessibilityElement],
		"the canvas publishes elements"
	)
	let firstBefore: NSAccessibilityElement = try unwrap(
		before.first, "the canvas has a first Panel"
	)
	// Read before the update, because the element is meant to be the same
	// object afterwards and would otherwise be compared against itself.
	let frameBefore: NSRect = firstBefore.accessibilityFrameInParentSpace()

	// A different proportion: the same Panels, new rectangles.
	try presentation.setUserRatio(0.8, for: .init("split-1"), onCanvas: canvasA)
	view.update(try snapshot(presentation))
	let after: [NSAccessibilityElement] = try unwrap(
		view.accessibilityChildren() as? [NSAccessibilityElement],
		"the canvas still publishes elements"
	)
	try expect(
		after.first === firstBefore,
		"a Panel that stayed keeps the element a reader is holding"
	)
	try expect(
		firstBefore.accessibilityFrameInParentSpace() != frameBefore,
		"the surviving element reports the new rectangle"
	)

	try presentation.removePanel(.init("b1"))
	view.update(try snapshot(presentation))
	let remaining: [NSAccessibilityElement] = try unwrap(
		view.accessibilityChildren() as? [NSAccessibilityElement],
		"the canvas publishes what is left"
	)
	try expect(
		remaining.count == 1 && remaining.first === firstBefore,
		"a Panel that left takes its element with it and leaves no stale group"
	)
	try expect(
		!NSApplication.shared.windows.contains(where: \.isVisible),
		"updating the tree must not show a window"
	)
}

/// The canvas re-derives a snapshot on every orchestrator tick, several times
/// per drag frame. Most of those say nothing new about the tree, and a reader
/// that is told the layout changed re-reads the whole canvas.
@MainActor
private func testAnUnchangedSnapshotIsNotRepublished() throws {
	let canvas: DesktopOverlaySnapshot = try snapshot(twoGroupPresentation())
	// Bound to a local: the tree holds its parent `unowned`, and an inline
	// temporary would be gone before the next Panel needed an element.
	let parent: NSView = .init(frame: .init(x: 0, y: 0, width: 1_200, height: 800))
	let tree: CanvasAccessibilityTree = .init(
		parent: parent,
		value: canvas.accessibility
	)
	try expect(
		!tree.update(canvas.accessibility),
		"re-deriving the same canvas must not republish the tree"
	)
	var moved: WorkspacePresentation = try twoGroupPresentation()
	try moved.setUserRatio(0.8, for: .init("split-1"), onCanvas: canvasA)
	let republished: Bool = tree.update(try snapshot(moved).accessibility)
	try expect(
		republished,
		"a solve that moved a Panel does republish it"
	)
}

// MARK: - Runner

@MainActor
private func run() throws {
	try testEachPanelNamesItsGroup()
	try testAnUnlabelledGroupFallsBackToItsIdentifier()
	try testASplitGroupNumbersItsFragments()
	try testASingleGroupCanvasStillNamesItsGroup()
	try testTwoWorkspacesSharingATitleAreStillToldApart()
	try testEveryPanelPublishesItsWorkspaceIdentity()
	try testASplitGroupSaysWhereItContinues()
	try testAnUnnameableSpaceStillSaysItIsAnotherOne()
	try testAnUnknownCanvasIsLeftUnsaidRatherThanGuessed()
	try testAFragmentOnThisCanvasIsNotSomewhereElse()
	try testBindingStateIsReadable()
	try testAProviderHintAloneIsNotAnAdoptedWindow()
	try testVirtualFocusMarksExactlyOneElement()
	try testFramesAreCanvasRelativeAndCoverTheCanvas()
	try testCanvasCountsItsPanelsAndGroups()
	try testABlankCanvasSaysSo()
	try testCanvasNamesItsFocusStage()
	try testAShortPanelSaysHowFarShort()
	try testOnlyTheShortAxisIsNamed()
	try testASubPointDeficitDoesNotRoundToZero()
	try testTheViewPublishesOneGroupPerPanel()
	try testElementsSurviveASolveAndLeaveWithTheirPanel()
	try testAnUnchangedSnapshotIsNotRepublished()
}

do {
	NSApplication.shared.setActivationPolicy(.prohibited)
	try run()
	print(
		"Teaser canvas accessibility tests passed "
			+ "(no window, no monitors, no Accessibility request)"
	)
} catch {
	fputs("Teaser canvas accessibility tests failed: \(error)\n", stderr)
	exit(1)
}
