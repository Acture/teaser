import Foundation

/// A split, addressed by the canvas whose tree holds it. There is one tree per
/// canvas now, so the canvas plus the split ID is the whole address.
struct LayoutSplitReference: Codable, Equatable, Hashable, Sendable {
	let displayID: DisplayID
	let splitID: LayoutSplitID
}

struct LayoutDivider: Codable, Equatable, Hashable, Sendable {
	let displayID: DisplayID
	let splitID: LayoutSplitID
	let axis: LayoutAxis
	let containerFrame: LayoutRect
	let frame: LayoutRect
	/// Whether this divider separates Panels of different groups. It is the
	/// wider gutter, and the one a group contour is drawn in.
	let crossesGroups: Bool
}

struct LayoutQuality: Codable, Equatable, Sendable {
	let maximumAspectRatioDeviation: Double
	let totalAspectRatioDeviation: Double
	/// Panels the canvas could not give their minimum size, and the size each
	/// one actually needs. The solve still succeeds and still places every
	/// Panel — shrinking in proportion is better than refusing to lay out — but
	/// a Panel below its minimum is something the person should be told about
	/// rather than left to wonder at.
	let shortfalls: [PanelID: LayoutSize]
}

struct PresentationLayout: Codable, Equatable, Sendable {
	let panelFrames: [PanelID: LayoutRect]
	let dividers: [LayoutDivider]
	let effectiveRatios: [LayoutSplitReference: Double]
	let quality: LayoutQuality
}

enum ConstrainedLayoutError: Error, Equatable, LocalizedError, Sendable {
	case invalidDisplayFrame(DisplayID)
	case missingDisplayFrame(DisplayID)
	case missingPanel(PanelID)
	case missingPanelKind(PanelKindID)
	case duplicatePanelReference(PanelID)
	case duplicateSplitReference(LayoutSplitReference)

	var errorDescription: String? {
		switch self {
		case .invalidDisplayFrame(let displayID):
			return "Canvas \(displayID.rawValue) reported an unusable frame."
		case .missingDisplayFrame(let displayID):
			return "Canvas \(displayID.rawValue) has no frame in this layout."
		case .missingPanel(let panelID):
			return "Panel \(panelID.rawValue) is placed but has no descriptor."
		case .missingPanelKind(let panelKindID):
			return "Panel kind \(panelKindID.rawValue) is not registered."
		case .duplicatePanelReference(let panelID):
			return "Panel \(panelID.rawValue) is placed on more than one canvas."
		case .duplicateSplitReference(let reference):
			return """
				Split \(reference.splitID.rawValue) appears more than once on canvas \
				\(reference.displayID.rawValue).
				"""
		}
	}
}

extension LayoutSize {
	var layoutDescription: String {
		// A non-finite requirement would trap `Int(_:)`, as would one past its
		// range.
		guard width.isFinite, height.isFinite,
			width.magnitude < 1e9, height.magnitude < 1e9
		else { return "\(width)×\(height) pt" }
		return "\(Int(width.rounded()))×\(Int(height.rounded())) pt"
	}
}

/// Solves each canvas's flat Panel tree inside that canvas's rectangle. A
/// Workspace is not a layout container: it never gets a rectangle here, and the
/// contour pass derives its outline from the Panel frames afterwards.
struct ConstrainedLayoutSolver: Sendable {
	/// Between Panels of one group.
	let panelGap: Double
	/// Between Panels of different groups, and between the outermost Panels and
	/// the canvas edge. Wide enough that two facing contours stay visibly apart
	/// while same-group neighbours' contours meet and merge.
	let groupGap: Double

	init(panelGap: Double = 4, groupGap: Double = 16) {
		precondition(panelGap >= 0)
		// The contour pass inflates each Panel by panelGap / 2, so same-group
		// neighbours touch and merge. A group gutter must stay wider than two of
		// those inflations plus a stroke, or two groups' contours would merge
		// into one and the boundary would disappear.
		precondition(groupGap >= 3 * panelGap)
		self.panelGap = panelGap
		self.groupGap = groupGap
	}

	/// The rectangle Panels are actually laid out in: the canvas inset by one
	/// group gutter, so a contour around an outermost Panel has room to be drawn
	/// instead of being clipped at the canvas edge. A canvas too small for the
	/// inset keeps its whole rectangle rather than collapsing.
	func layoutFrame(inCanvas frame: LayoutRect) -> LayoutRect {
		guard frame.size.width > 2 * groupGap, frame.size.height > 2 * groupGap
		else { return frame }
		return frame.insetBy(dx: groupGap, dy: groupGap)
	}

	static func solve(
		presentation: WorkspacePresentation,
		displayFrames: [DisplayID: LayoutRect]
	) throws -> PresentationLayout {
		try Self().solve(presentation: presentation, displayFrames: displayFrames)
	}

	func solve(
		presentation: WorkspacePresentation,
		displayFrames: [DisplayID: LayoutRect]
	) throws -> PresentationLayout {
		try validate(presentation: presentation, displayFrames: displayFrames)

		var panelFrames: [PanelID: LayoutRect] = [:]
		var dividers: [LayoutDivider] = []
		var effectiveRatios: [LayoutSplitReference: Double] = [:]

		for displayID: DisplayID in presentation.canvases.keys.sorted(
			by: { $0.rawValue < $1.rawValue }
		) {
			// A blank canvas places nothing and is not an error: it is what every
			// canvas starts as.
			guard let tree: LayoutTree<PanelID> = presentation.canvases[displayID]?
				.panelTree
			else { continue }
			guard let displayFrame: LayoutRect = displayFrames[displayID] else {
				throw ConstrainedLayoutError.missingDisplayFrame(displayID)
			}
			let solution: TreeSolution = try solveTreeNode(
				tree,
				in: layoutFrame(inCanvas: displayFrame),
				displayID: displayID,
				presentation: presentation
			)
			panelFrames.merge(solution.leafFrames) { _, _ in
				preconditionFailure("Validated Panel IDs must be unique")
			}
			dividers.append(contentsOf: solution.dividers)
			for (reference, ratio): (LayoutSplitReference, Double)
				in solution.effectiveRatios
			{
				guard effectiveRatios[reference] == nil else {
					throw ConstrainedLayoutError.duplicateSplitReference(reference)
				}
				effectiveRatios[reference] = ratio
			}
		}

		return .init(
			panelFrames: panelFrames,
			dividers: dividers.sorted(by: dividerSort),
			effectiveRatios: effectiveRatios,
			quality: try layoutQuality(
				panelFrames: panelFrames,
				presentation: presentation
			)
		)
	}

	// MARK: - Validation

	private func validate(
		presentation: WorkspacePresentation,
		displayFrames: [DisplayID: LayoutRect]
	) throws {
		for (displayID, frame): (DisplayID, LayoutRect) in displayFrames {
			guard frame.origin.x.isFinite, frame.origin.y.isFinite,
				frame.size.width.isFinite, frame.size.height.isFinite,
				frame.size.width > 0, frame.size.height > 0
			else {
				throw ConstrainedLayoutError.invalidDisplayFrame(displayID)
			}
		}

		// A Panel the presentation knows but no open canvas places is normal: its
		// canvas is closed. Only a placed Panel has to be solvable, so there is
		// deliberately no "unplaced Panel" error here.
		var placed: Set<PanelID> = []
		for (displayID, canvas): (DisplayID, CanvasLayout) in presentation.canvases {
			guard let tree: LayoutTree<PanelID> = canvas.panelTree else { continue }
			guard displayFrames[displayID] != nil else {
				throw ConstrainedLayoutError.missingDisplayFrame(displayID)
			}
			var seenSplits: Set<LayoutSplitID> = []
			for splitID: LayoutSplitID in tree.splitIDs {
				guard seenSplits.insert(splitID).inserted else {
					throw ConstrainedLayoutError.duplicateSplitReference(
						.init(displayID: displayID, splitID: splitID)
					)
				}
			}
			for panelID: PanelID in tree.leaves {
				guard placed.insert(panelID).inserted else {
					throw ConstrainedLayoutError.duplicatePanelReference(panelID)
				}
				guard presentation.panels[panelID] != nil else {
					throw ConstrainedLayoutError.missingPanel(panelID)
				}
			}
		}
	}

	// MARK: - Metrics

	private func panelMetrics(
		_ panelID: PanelID,
		presentation: WorkspacePresentation
	) throws -> LeafLayoutMetrics {
		guard let panel: PanelDescriptor = presentation.panels[panelID] else {
			throw ConstrainedLayoutError.missingPanel(panelID)
		}
		if let profile: LayoutProfile = panel.profileOverride {
			return .init(
				minimumSize: profile.minimumSize,
				growthWeight: profile.growthWeight
			)
		}
		guard let definition: PanelKindDefinition = presentation.panelKinds
			.definition(for: panel.kindID)
		else {
			throw ConstrainedLayoutError.missingPanelKind(panel.kindID)
		}
		return .init(
			minimumSize: definition.defaultProfile.minimumSize,
			growthWeight: definition.defaultProfile.growthWeight
		)
	}

	/// The one group every leaf of this subtree belongs to, or nil when it holds
	/// more than one. This is what decides a split's gutter, so the spacing
	/// reads as hierarchy: tight inside a group, open between groups.
	private func commonWorkspace(
		_ tree: LayoutTree<PanelID>,
		presentation: WorkspacePresentation
	) -> WorkspaceID? {
		var common: WorkspaceID?
		for panelID: PanelID in tree.leaves {
			guard let workspaceID: WorkspaceID = presentation.workspaceID(of: panelID)
			else { return nil }
			if let common {
				guard common == workspaceID else { return nil }
			} else {
				common = workspaceID
			}
		}
		return common
	}

	/// A split is inside one group only when both sides are that same group. A
	/// subtree mixing groups always takes the wide gutter.
	private func gap(
		between first: LayoutTree<PanelID>,
		and second: LayoutTree<PanelID>,
		presentation: WorkspacePresentation
	) -> Double {
		let left: WorkspaceID? = commonWorkspace(first, presentation: presentation)
		guard let left, left == commonWorkspace(second, presentation: presentation)
		else { return groupGap }
		return panelGap
	}

	private func treeMetrics(
		_ tree: LayoutTree<PanelID>,
		presentation: WorkspacePresentation
	) throws -> LeafLayoutMetrics {
		switch tree {
		case .leaf(let panelID):
			return try panelMetrics(panelID, presentation: presentation)
		case .split(_, let axis, _, let first, let second):
			let firstMetrics: LeafLayoutMetrics = try treeMetrics(
				first,
				presentation: presentation
			)
			let secondMetrics: LeafLayoutMetrics = try treeMetrics(
				second,
				presentation: presentation
			)
			// The same gutter the placing pass will use, or a minimum computed
			// here would not be the minimum actually honoured there.
			let nodeGap: Double = gap(
				between: first,
				and: second,
				presentation: presentation
			)
			let size: LayoutSize
			switch axis {
			case .horizontal:
				size = .init(
					width: firstMetrics.minimumSize.width + nodeGap
						+ secondMetrics.minimumSize.width,
					height: max(
						firstMetrics.minimumSize.height,
						secondMetrics.minimumSize.height
					)
				)
			case .vertical:
				size = .init(
					width: max(
						firstMetrics.minimumSize.width,
						secondMetrics.minimumSize.width
					),
					height: firstMetrics.minimumSize.height + nodeGap
						+ secondMetrics.minimumSize.height
				)
			}
			return .init(
				minimumSize: size,
				growthWeight: firstMetrics.growthWeight + secondMetrics.growthWeight
			)
		}
	}

	// MARK: - Placement

	private func solveTreeNode(
		_ tree: LayoutTree<PanelID>,
		in frame: LayoutRect,
		displayID: DisplayID,
		presentation: WorkspacePresentation
	) throws -> TreeSolution {
		switch tree {
		case .leaf(let panelID):
			return .init(
				leafFrames: [panelID: frame],
				dividers: [],
				effectiveRatios: [:]
			)
		case .split(let splitID, let axis, let preference, let first, let second):
			let firstMetrics: LeafLayoutMetrics = try treeMetrics(
				first,
				presentation: presentation
			)
			let secondMetrics: LeafLayoutMetrics = try treeMetrics(
				second,
				presentation: presentation
			)
			let nodeGap: Double = gap(
				between: first,
				and: second,
				presentation: presentation
			)
			let available: Double = axis == .horizontal
				? frame.size.width - nodeGap
				: frame.size.height - nodeGap
			let firstMinimum: Double = axis == .horizontal
				? firstMetrics.minimumSize.width
				: firstMetrics.minimumSize.height
			let secondMinimum: Double = axis == .horizontal
				? secondMetrics.minimumSize.width
				: secondMetrics.minimumSize.height
			// A region too narrow for its gap drops the gap rather than failing.
			let splitGap: Double = available > 0 ? nodeGap : 0
			let usable: Double = available > 0
				? available
				: (axis == .horizontal ? frame.size.width : frame.size.height)

			// A divider the person has dragged keeps their proportion. One they
			// have not follows the Panels inside it: a subtree holding more
			// Panels, or Panels whose kind asks to grow, takes proportionally
			// more of the axis. Halving every split regardless is what collapses
			// a canvas into equal columns.
			let totalWeight: Double = firstMetrics.growthWeight
				+ secondMetrics.growthWeight
			let derived: Double = totalWeight.isFinite && totalWeight > 0
				? (firstMetrics.growthWeight / totalWeight).clamped(to: 0.05 ... 0.95)
				: 0.5
			let desired: Double = preference.userRatio.flatMap {
				$0.isFinite ? $0 : nil
			} ?? derived

			let ratio: Double
			if usable > 0, firstMinimum + secondMinimum <= usable {
				// Room for both minimums: honour the requested ratio within them.
				// When the two sides fit exactly, `firstMinimum / usable` and
				// `1 - secondMinimum / usable` are the same number in exact
				// arithmetic but can land one ULP apart in the wrong order, which
				// would trap forming the range. Splitting the difference is the
				// same answer without the trap.
				let lower: Double = firstMinimum / usable
				let upper: Double = 1 - secondMinimum / usable
				ratio = upper >= lower
					? desired.clamped(to: lower ... upper)
					: (lower + upper) / 2
			} else if firstMinimum + secondMinimum > 0 {
				// Not enough room: both sides shrink in proportion to what they
				// need, so the layout adapts to the space it has rather than
				// refusing it.
				ratio = (firstMinimum / (firstMinimum + secondMinimum))
					.clamped(to: 0.01 ... 0.99)
			} else {
				ratio = desired
			}

			let frames: SplitFrames = split(
				frame,
				axis: axis,
				ratio: ratio,
				gap: splitGap
			)
			let firstSolution: TreeSolution = try solveTreeNode(
				first,
				in: frames.first,
				displayID: displayID,
				presentation: presentation
			)
			let secondSolution: TreeSolution = try solveTreeNode(
				second,
				in: frames.second,
				displayID: displayID,
				presentation: presentation
			)
			var leafFrames: [PanelID: LayoutRect] = firstSolution.leafFrames
			leafFrames.merge(secondSolution.leafFrames) { _, _ in
				preconditionFailure("Validated tree leaves must be unique")
			}
			var ratios: [LayoutSplitReference: Double] = firstSolution.effectiveRatios
			ratios.merge(secondSolution.effectiveRatios) { _, _ in
				preconditionFailure("Validated split IDs must be unique")
			}
			let reference: LayoutSplitReference = .init(
				displayID: displayID,
				splitID: splitID
			)
			ratios[reference] = ratio
			return .init(
				leafFrames: leafFrames,
				dividers: [
					.init(
						displayID: displayID,
						splitID: splitID,
						axis: axis,
						containerFrame: frame,
						frame: frames.divider,
						crossesGroups: nodeGap != panelGap
					),
				] + firstSolution.dividers + secondSolution.dividers,
				effectiveRatios: ratios
			)
		}
	}

	private func split(
		_ frame: LayoutRect,
		axis: LayoutAxis,
		ratio: Double,
		gap: Double
	) -> SplitFrames {
		switch axis {
		case .horizontal:
			let firstWidth: Double = (frame.size.width - gap) * ratio
			return .init(
				first: .init(
					x: frame.minX,
					y: frame.minY,
					width: firstWidth,
					height: frame.size.height
				),
				divider: .init(
					x: frame.minX + firstWidth,
					y: frame.minY,
					width: gap,
					height: frame.size.height
				),
				second: .init(
					x: frame.minX + firstWidth + gap,
					y: frame.minY,
					width: frame.size.width - gap - firstWidth,
					height: frame.size.height
				)
			)
		case .vertical:
			let firstHeight: Double = (frame.size.height - gap) * ratio
			return .init(
				first: .init(
					x: frame.minX,
					y: frame.minY,
					width: frame.size.width,
					height: firstHeight
				),
				divider: .init(
					x: frame.minX,
					y: frame.minY + firstHeight,
					width: frame.size.width,
					height: gap
				),
				second: .init(
					x: frame.minX,
					y: frame.minY + firstHeight + gap,
					width: frame.size.width,
					height: frame.size.height - gap - firstHeight
				)
			)
		}
	}

	// MARK: - Quality

	private func layoutQuality(
		panelFrames: [PanelID: LayoutRect],
		presentation: WorkspacePresentation
	) throws -> LayoutQuality {
		var maximumDeviation: Double = 0
		var totalDeviation: Double = 0
		var shortfalls: [PanelID: LayoutSize] = [:]
		for (panelID, frame): (PanelID, LayoutRect) in panelFrames {
			guard let panel: PanelDescriptor = presentation.panels[panelID] else {
				throw ConstrainedLayoutError.missingPanel(panelID)
			}
			let profile: LayoutProfile
			if let override: LayoutProfile = panel.profileOverride {
				profile = override
			} else if let definition: PanelKindDefinition = presentation.panelKinds
				.definition(for: panel.kindID)
			{
				profile = definition.defaultProfile
			} else {
				throw ConstrainedLayoutError.missingPanelKind(panel.kindID)
			}
			let deviation: Double = profile.preferredAspectRatio.distance(
				to: frame.size.width / frame.size.height
			)
			maximumDeviation = max(maximumDeviation, deviation)
			totalDeviation += deviation
			// A tolerance, because a Panel given exactly its minimum can land a
			// fraction of a point under it through the split arithmetic.
			if frame.size.width < profile.minimumSize.width - 0.001
				|| frame.size.height < profile.minimumSize.height - 0.001
			{
				shortfalls[panelID] = profile.minimumSize
			}
		}
		return .init(
			maximumAspectRatioDeviation: maximumDeviation,
			totalAspectRatioDeviation: totalDeviation,
			shortfalls: shortfalls
		)
	}

	private func dividerSort(_ lhs: LayoutDivider, _ rhs: LayoutDivider) -> Bool {
		if lhs.displayID.rawValue != rhs.displayID.rawValue {
			return lhs.displayID.rawValue < rhs.displayID.rawValue
		}
		return lhs.splitID.rawValue < rhs.splitID.rawValue
	}
}

private struct LeafLayoutMetrics {
	let minimumSize: LayoutSize
	let growthWeight: Double
}

private struct TreeSolution {
	let leafFrames: [PanelID: LayoutRect]
	let dividers: [LayoutDivider]
	let effectiveRatios: [LayoutSplitReference: Double]
}

private struct SplitFrames {
	let first: LayoutRect
	let divider: LayoutRect
	let second: LayoutRect
}
