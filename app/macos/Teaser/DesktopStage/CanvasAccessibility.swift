import Foundation

// What the canvas says about itself when something reads it instead of looking
// at it. Every value here is derived from the same `DesktopOverlaySnapshot` the
// canvas draws, so the spoken tree and the pixels cannot disagree and there is
// no second store to keep in step.
//
// This half is pure and knows nothing about AppKit; `CanvasAccessibilityTree`
// turns it into elements.

/// One Panel's element. The attribute each field lands in is named, because the
/// mapping is the contract a screen reader and an automated read both rely on.
struct PanelAccessibility: Equatable, Sendable {
	let panelID: PanelID
	/// `AXTitle`. The same string the canvas draws on the Panel, provider prefix
	/// included: what is shown and what is spoken should be one string.
	let title: String
	/// `AXDescription`. The group, the fragment when the group has more than
	/// one, and what the Panel is bound to. This is the channel that stops group
	/// identity from being a colour and nothing else: a contour hue is invisible
	/// to a person who cannot separate the hues, and inaudible to everyone.
	let description: String
	/// `AXHelp`. How far below its minimum the canvas had to squeeze this Panel,
	/// or nil when it fits. The solve never fails for a Panel it cannot satisfy,
	/// so the shortfall has to be said somewhere.
	let shortfall: String?
	/// `AXPosition` and `AXSize`, in the canvas's own coordinates with the
	/// origin at its bottom-left corner. Canvas-relative rather than global, so
	/// a window move cannot leave a stale screen rectangle behind, and so a
	/// harness can assert a frame without a window to convert through.
	let frame: LayoutRect
	/// `AXFocused`, from Virtual Focus. Virtual Focus is the Panel layout
	/// commands aim at; it never redirects native Input Focus (REQ-014), and
	/// reporting it here must not start doing so.
	let isFocused: Bool
}

/// The canvas element the Panels hang under.
struct CanvasAccessibility: Equatable, Sendable {
	/// `AXDescription` for the canvas: how many Panels, how many groups, and
	/// whether one group is focused and at which stage.
	let description: String
	/// In tree order, the order the canvas lays them out in.
	let panels: [PanelAccessibility]
}

extension DesktopOverlaySnapshot {
	/// The accessibility projection of this canvas.
	var accessibility: CanvasAccessibility {
		.init(
			description: canvasAccessibilityDescription,
			panels: panels.map { panel in
				.init(
					panelID: panel.id,
					title: panel.title,
					description: panelAccessibilityDescription(panel),
					shortfall: panel.minimumSize.map {
						CanvasAccessibilityWording.shortfall(
							minimum: $0,
							actual: panel.frame.size
						)
					},
					frame: .init(
						x: panel.frame.minX - screenFrame.minX,
						y: panel.frame.minY - screenFrame.minY,
						width: panel.frame.size.width,
						height: panel.frame.size.height
					),
					isFocused: virtualFocus.panelID == panel.id
				)
			}
		)
	}

	/// The Workspaces with a Panel published on this canvas. Counted from the
	/// published Panels rather than from the presentation, so it describes what
	/// the tree actually holds: an exclusive focus prunes the others out of the
	/// solve, and a canvas that says "2 Workspaces" while showing one would be
	/// reporting a group nothing can be read about.
	private var publishedWorkspaceCount: Int {
		Set(panels.map(\.workspaceID)).count
	}

	private var canvasAccessibilityDescription: String {
		var sentences: [String] = []
		if panels.isEmpty {
			sentences.append("No Panels placed")
		} else {
			// "Workspace", not "group": the menu bar says Focus Workspace and
			// Next Workspace, and a person hearing both surfaces must not have
			// to work out that they are the same thing.
			sentences.append(
				"\(CanvasAccessibilityWording.count(panels.count, "Panel")) in "
					+ CanvasAccessibilityWording.count(
						publishedWorkspaceCount, "Workspace"
					)
			)
		}
		if let focus: DesktopOverlayCanvasFocus = focus {
			sentences.append(
				focus.isExclusive
					? "\(focus.title) has the canvas to itself, and the other "
						+ "Workspaces' adopted windows are minimized"
					: "\(focus.title) is emphasised"
			)
		}
		return CanvasAccessibilityWording.sentences(sentences)
	}

	private func panelAccessibilityDescription(
		_ panel: DesktopOverlayPanel
	) -> String {
		var group: String = panel.workspaceTitle
		if let fragment: WorkspaceFragmentPosition = panel.fragment {
			group += ", fragment \(fragment.ordinal) of \(fragment.total)"
		}
		return CanvasAccessibilityWording.sentences([
			group,
			CanvasAccessibilityWording.binding(panel.binding),
		])
	}
}

/// The user-visible strings, in one place so the harness pins the wording once
/// and the canvas cannot grow a second phrasing for the same fact.
enum CanvasAccessibilityWording {
	static let canvasRoleDescription: String = "Teaser canvas"
	static let panelRoleDescription: String = "Teaser Panel"

	static func binding(_ binding: PanelBindingState) -> String {
		switch binding {
		case .empty: return "No binding yet"
		case .adoptedWindow: return "Adopted window"
		case .teaserNotes: return "Teaser Notes"
		}
	}

	/// `LayoutQuality` records a shortfall when *either* axis is short, so a
	/// Panel can be narrow and taller than it needs at the same time. Naming
	/// only the short axis keeps the sentence from claiming a deficit of zero,
	/// and the tolerance is the solver's own: a Panel given exactly its minimum
	/// can land a fraction of a point under it through the split arithmetic.
	static func shortfall(minimum: LayoutSize, actual: LayoutSize) -> String {
		var short: [String] = []
		let width: Double = minimum.width - actual.width
		let height: Double = minimum.height - actual.height
		if width > shortfallTolerance {
			short.append("\(points(width)) short of width")
		}
		if height > shortfallTolerance {
			short.append("\(points(height)) short of height")
		}
		// "This Panel needs", not "this Panel kind": a Panel carries its own
		// override whenever a projection or an adopted window that refused to
		// shrink gave it one, and that is the number `shortfalls` records.
		let needs: String = "This Panel needs \(minimum.layoutDescription)."
		guard !short.isEmpty else {
			return "Below its minimum size. \(needs)"
		}
		return "Below its minimum size: \(short.joined(separator: " and ")). \(needs)"
	}

	private static let shortfallTolerance: Double = 0.001

	/// Joined with a full stop so a screen reader pauses between facts rather
	/// than running the group into the binding.
	static func sentences(_ parts: [String]) -> String {
		parts.filter { !$0.isEmpty }.map { "\($0)." }.joined(separator: " ")
	}

	static func count(_ value: Int, _ noun: String) -> String {
		"\(value) \(noun)\(value == 1 ? "" : "s")"
	}

	/// A non-finite or enormous deficit would trap `Int(_:)`, the same way
	/// `LayoutSize.layoutDescription` guards against one. A deficit is the one
	/// measurement here that can round to nothing, and "0 pt short of width"
	/// reads as a contradiction of the sentence it sits in, so a sub-point
	/// deficit says so instead of naming a magnitude it does not have.
	private static func points(_ value: Double) -> String {
		guard value.isFinite, value.magnitude < 1e9 else { return "\(value) pt" }
		let whole: Double = value.rounded()
		guard whole >= 1 else { return "less than 1 pt" }
		return "\(Int(whole)) pt"
	}
}
