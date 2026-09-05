import Foundation

struct LayoutSplitReference: Codable, Equatable, Hashable, Sendable {
	let scope: LayoutScope
	let splitID: LayoutSplitID
}

struct LayoutDivider: Codable, Equatable, Hashable, Sendable {
	let scope: LayoutScope
	let splitID: LayoutSplitID
	let axis: LayoutAxis
	let containerFrame: LayoutRect
	let frame: LayoutRect
}

struct LayoutQuality: Codable, Equatable, Sendable {
	let maximumAspectRatioDeviation: Double
	let totalAspectRatioDeviation: Double
}

struct PresentationLayout: Codable, Equatable, Sendable {
	let workspaceFrames: [WorkspaceID: LayoutRect]
	let panelFrames: [PanelID: LayoutRect]
	let dividers: [LayoutDivider]
	let effectiveRatios: [LayoutSplitReference: Double]
	let quality: LayoutQuality
}

enum ConstrainedLayoutError: Error, Equatable, Sendable {
	case invalidDisplayFrame(DisplayID)
	case missingDisplayFrame(DisplayID)
	case missingWorkspace(WorkspaceID)
	case missingPanel(PanelID)
	case missingPanelKind(PanelKindID)
	case duplicateWorkspaceReference(WorkspaceID)
	case duplicatePanelReference(PanelID)
	case duplicateSplitReference(LayoutSplitReference)
	case unplacedWorkspace(WorkspaceID)
	case unplacedPanel(PanelID)
	case displayAffinityMismatch(WorkspaceID)
	case infeasible(LayoutScope, LayoutSplitID?, LayoutSize, LayoutSize)
}

struct ConstrainedLayoutSolver: Sendable {
	let workspaceGap: Double
	let panelGap: Double

	init(workspaceGap: Double = 8, panelGap: Double = 4) {
		precondition(workspaceGap >= 0 && panelGap >= 0)
		self.workspaceGap = workspaceGap
		self.panelGap = panelGap
	}

	static func solve(
		presentation: WorkspacePresentation,
		displayFrames: [DisplayID: LayoutRect]
	) throws -> PresentationLayout {
		try Self().solve(
			presentation: presentation,
			displayFrames: displayFrames
		)
	}

	func solve(
		presentation: WorkspacePresentation,
		displayFrames: [DisplayID: LayoutRect]
	) throws -> PresentationLayout {
		try validate(presentation: presentation, displayFrames: displayFrames)

		var workspaceFrames: [WorkspaceID: LayoutRect] = [:]
		var panelFrames: [PanelID: LayoutRect] = [:]
		var dividers: [LayoutDivider] = []
		var effectiveRatios: [LayoutSplitReference: Double] = [:]

		switch presentation.mode {
		case .tiled:
			for displayID: DisplayID in presentation.displayLayouts.keys.sorted(
				by: { $0.rawValue < $1.rawValue }
			) {
				guard let displayLayout: DisplayWorkspaceLayout =
					presentation.displayLayouts[displayID],
					let displayFrame: LayoutRect = displayFrames[displayID]
				else {
					throw ConstrainedLayoutError.missingDisplayFrame(displayID)
				}
				let scope: LayoutScope = .display(displayID)
				let solution: TreeSolution<WorkspaceID> = try solveTree(
					displayLayout.workspaceTree,
					in: displayFrame,
					gap: workspaceGap,
					scope: scope
				) { workspaceID in
					try workspaceMetrics(
						workspaceID,
						presentation: presentation
					)
				}
				workspaceFrames.merge(solution.leafFrames) { _, _ in
					preconditionFailure("Validated workspace IDs must be unique")
				}
				try merge(
					solution: solution,
					intoDividers: &dividers,
					effectiveRatios: &effectiveRatios
				)
			}
		case .focused(let workspaceID):
			guard let workspace: WorkspaceDescriptor = presentation.workspaces[workspaceID]
			else {
				throw ConstrainedLayoutError.missingWorkspace(workspaceID)
			}
			guard let displayFrame: LayoutRect = displayFrames[workspace.displayAffinity]
			else {
				throw ConstrainedLayoutError.missingDisplayFrame(workspace.displayAffinity)
			}
			workspaceFrames[workspaceID] = displayFrame
		}

		for workspaceID: WorkspaceID in workspaceFrames.keys.sorted(
			by: { $0.rawValue < $1.rawValue }
		) {
			guard let workspaceFrame: LayoutRect = workspaceFrames[workspaceID],
				let workspace: WorkspaceDescriptor = presentation.workspaces[workspaceID]
			else {
				throw ConstrainedLayoutError.missingWorkspace(workspaceID)
			}
			let scope: LayoutScope = .workspace(workspaceID)
			let solution: TreeSolution<PanelID> = try solveTree(
				workspace.panelTree,
				in: workspaceFrame,
				gap: panelGap,
				scope: scope
			) { panelID in
				try panelMetrics(
					panelID,
					workspace: workspace,
					registry: presentation.panelKinds
				)
			}
			panelFrames.merge(solution.leafFrames) { _, _ in
				preconditionFailure("Validated panel IDs must be unique")
			}
			try merge(
				solution: solution,
				intoDividers: &dividers,
				effectiveRatios: &effectiveRatios
			)
		}

		let quality: LayoutQuality = try layoutQuality(
			panelFrames: panelFrames,
			presentation: presentation
		)
		return .init(
			workspaceFrames: workspaceFrames,
			panelFrames: panelFrames,
			dividers: dividers.sorted(by: dividerSort),
			effectiveRatios: effectiveRatios,
			quality: quality
		)
	}

	private func validate(
		presentation: WorkspacePresentation,
		displayFrames: [DisplayID: LayoutRect]
	) throws {
		for (displayID, frame): (DisplayID, LayoutRect) in displayFrames {
			guard frame.origin.x.isFinite,
				frame.origin.y.isFinite,
				frame.size.width.isFinite,
				frame.size.height.isFinite,
				frame.size.width > 0,
				frame.size.height > 0
			else {
				throw ConstrainedLayoutError.invalidDisplayFrame(displayID)
			}
		}

		var placedWorkspaces: Set<WorkspaceID> = []
		var placedPanels: Set<PanelID> = []
		for (displayID, layout): (DisplayID, DisplayWorkspaceLayout) in presentation.displayLayouts {
			guard displayFrames[displayID] != nil else {
				throw ConstrainedLayoutError.missingDisplayFrame(displayID)
			}
			try validateUniqueSplits(
				layout.workspaceTree.splitIDs,
				scope: .display(displayID)
			)
			for workspaceID: WorkspaceID in layout.workspaceTree.leaves {
				guard placedWorkspaces.insert(workspaceID).inserted else {
					throw ConstrainedLayoutError.duplicateWorkspaceReference(workspaceID)
				}
				guard let workspace: WorkspaceDescriptor = presentation.workspaces[workspaceID]
				else {
					throw ConstrainedLayoutError.missingWorkspace(workspaceID)
				}
				guard workspace.displayAffinity == displayID else {
					throw ConstrainedLayoutError.displayAffinityMismatch(workspaceID)
				}
				try validateUniqueSplits(
					workspace.panelTree.splitIDs,
					scope: .workspace(workspaceID)
				)
				var localPanels: Set<PanelID> = []
				for panelID: PanelID in workspace.panelTree.leaves {
					guard localPanels.insert(panelID).inserted,
						placedPanels.insert(panelID).inserted
					else {
						throw ConstrainedLayoutError.duplicatePanelReference(panelID)
					}
					guard workspace.panels[panelID] != nil else {
						throw ConstrainedLayoutError.missingPanel(panelID)
					}
				}
				if let unplacedPanelID: PanelID = workspace.panels.keys.first(
					where: { !localPanels.contains($0) }
				) {
					throw ConstrainedLayoutError.unplacedPanel(unplacedPanelID)
				}
			}
		}
		if let unplacedWorkspaceID: WorkspaceID = presentation.workspaces.keys.first(
			where: { !placedWorkspaces.contains($0) }
		) {
			throw ConstrainedLayoutError.unplacedWorkspace(unplacedWorkspaceID)
		}
	}

	private func validateUniqueSplits(
		_ splitIDs: [LayoutSplitID],
		scope: LayoutScope
	) throws {
		var seen: Set<LayoutSplitID> = []
		for splitID: LayoutSplitID in splitIDs {
			guard seen.insert(splitID).inserted else {
				throw ConstrainedLayoutError.duplicateSplitReference(
					.init(scope: scope, splitID: splitID)
				)
			}
		}
	}

	private func workspaceMetrics(
		_ workspaceID: WorkspaceID,
		presentation: WorkspacePresentation
	) throws -> LeafLayoutMetrics {
		guard let workspace: WorkspaceDescriptor = presentation.workspaces[workspaceID]
		else {
			throw ConstrainedLayoutError.missingWorkspace(workspaceID)
		}
		let metrics: TreeLayoutMetrics = try treeMetrics(
			workspace.panelTree,
			gap: panelGap,
			scope: .workspace(workspaceID)
		) { panelID in
			try panelMetrics(
				panelID,
				workspace: workspace,
				registry: presentation.panelKinds
			)
		}
		return .init(minimumSize: metrics.minimumSize, growthWeight: metrics.growthWeight)
	}

	private func panelMetrics(
		_ panelID: PanelID,
		workspace: WorkspaceDescriptor,
		registry: PanelKindRegistry
	) throws -> LeafLayoutMetrics {
		guard let panel: PanelDescriptor = workspace.panels[panelID] else {
			throw ConstrainedLayoutError.missingPanel(panelID)
		}
		if let profile: LayoutProfile = panel.profileOverride {
			return .init(
				minimumSize: profile.minimumSize,
				growthWeight: profile.growthWeight
			)
		}
		guard let definition: PanelKindDefinition = registry.definition(for: panel.kindID)
		else {
			throw ConstrainedLayoutError.missingPanelKind(panel.kindID)
		}
		return .init(
			minimumSize: definition.defaultProfile.minimumSize,
			growthWeight: definition.defaultProfile.growthWeight
		)
	}

	private func solveTree<Leaf>(
		_ tree: LayoutTree<Leaf>,
		in frame: LayoutRect,
		gap: Double,
		scope: LayoutScope,
		leafMetrics: (Leaf) throws -> LeafLayoutMetrics
	) throws -> TreeSolution<Leaf>
	where Leaf: Codable & Hashable & Sendable {
		let metrics: TreeLayoutMetrics = try treeMetrics(
			tree,
			gap: gap,
			scope: scope,
			leafMetrics: leafMetrics
		)
		guard frame.size.width + 0.000_001 >= metrics.minimumSize.width,
			frame.size.height + 0.000_001 >= metrics.minimumSize.height
		else {
			throw ConstrainedLayoutError.infeasible(
				scope,
				nil,
				metrics.minimumSize,
				frame.size
			)
		}
		return try solveTreeNode(
			tree,
			in: frame,
			gap: gap,
			scope: scope,
			leafMetrics: leafMetrics
		)
	}

	private func solveTreeNode<Leaf>(
		_ tree: LayoutTree<Leaf>,
		in frame: LayoutRect,
		gap: Double,
		scope: LayoutScope,
		leafMetrics: (Leaf) throws -> LeafLayoutMetrics
	) throws -> TreeSolution<Leaf>
	where Leaf: Codable & Hashable & Sendable {
		switch tree {
		case .leaf(let leaf):
			return .init(
				leafFrames: [leaf: frame],
				dividers: [],
				effectiveRatios: [:]
			)
		case .split(
			let splitID,
			let axis,
			let preference,
			let first,
			let second
		):
			let firstMetrics: TreeLayoutMetrics = try treeMetrics(
				first,
				gap: gap,
				scope: scope,
				leafMetrics: leafMetrics
			)
			let secondMetrics: TreeLayoutMetrics = try treeMetrics(
				second,
				gap: gap,
				scope: scope,
				leafMetrics: leafMetrics
			)
			let available: Double = axis == .horizontal
				? frame.size.width - gap
				: frame.size.height - gap
			let firstMinimum: Double = axis == .horizontal
				? firstMetrics.minimumSize.width
				: firstMetrics.minimumSize.height
			let secondMinimum: Double = axis == .horizontal
				? secondMetrics.minimumSize.width
				: secondMetrics.minimumSize.height
			guard available > 0 else {
				throw ConstrainedLayoutError.infeasible(
					scope,
					splitID,
					minimumSize(
						axis: axis,
						gap: gap,
						first: firstMetrics.minimumSize,
						second: secondMetrics.minimumSize
					),
					frame.size
				)
			}
			let lowerBound: Double = firstMinimum / available
			let upperBound: Double = 1 - secondMinimum / available
			guard lowerBound <= upperBound,
				preference.desiredRatio.isFinite
			else {
				throw ConstrainedLayoutError.infeasible(
					scope,
					splitID,
					minimumSize(
						axis: axis,
						gap: gap,
						first: firstMetrics.minimumSize,
						second: secondMetrics.minimumSize
					),
					frame.size
				)
			}
			let feasibleRange: ClosedRange<Double> = lowerBound ... upperBound
			let ratio: Double = preference.desiredRatio.clamped(to: feasibleRange)
			let frames: SplitFrames = split(
				frame,
				axis: axis,
				ratio: ratio,
				gap: gap
			)
			let firstSolution: TreeSolution<Leaf> = try solveTreeNode(
				first,
				in: frames.first,
				gap: gap,
				scope: scope,
				leafMetrics: leafMetrics
			)
			let secondSolution: TreeSolution<Leaf> = try solveTreeNode(
				second,
				in: frames.second,
				gap: gap,
				scope: scope,
				leafMetrics: leafMetrics
			)
			var leafFrames: [Leaf: LayoutRect] = firstSolution.leafFrames
			leafFrames.merge(secondSolution.leafFrames) { _, _ in
				preconditionFailure("Validated tree leaves must be unique")
			}
			var ratios: [LayoutSplitReference: Double] =
				firstSolution.effectiveRatios
			ratios.merge(secondSolution.effectiveRatios) { _, _ in
				preconditionFailure("Validated split IDs must be unique")
			}
			let reference: LayoutSplitReference = .init(
				scope: scope,
				splitID: splitID
			)
			ratios[reference] = ratio
			let divider: LayoutDivider = .init(
				scope: scope,
				splitID: splitID,
				axis: axis,
				containerFrame: frame,
				frame: frames.divider
			)
			return .init(
				leafFrames: leafFrames,
				dividers: [divider]
					+ firstSolution.dividers
					+ secondSolution.dividers,
				effectiveRatios: ratios
			)
		}
	}

	private func treeMetrics<Leaf>(
		_ tree: LayoutTree<Leaf>,
		gap: Double,
		scope: LayoutScope,
		leafMetrics: (Leaf) throws -> LeafLayoutMetrics
	) throws -> TreeLayoutMetrics
	where Leaf: Codable & Hashable & Sendable {
		switch tree {
		case .leaf(let leaf):
			let metrics: LeafLayoutMetrics = try leafMetrics(leaf)
			return .init(
				minimumSize: metrics.minimumSize,
				growthWeight: metrics.growthWeight
			)
		case .split(let splitID, let axis, _, let first, let second):
			let firstMetrics: TreeLayoutMetrics = try treeMetrics(
				first,
				gap: gap,
				scope: scope,
				leafMetrics: leafMetrics
			)
			let secondMetrics: TreeLayoutMetrics = try treeMetrics(
				second,
				gap: gap,
				scope: scope,
				leafMetrics: leafMetrics
			)
			let size: LayoutSize = minimumSize(
				axis: axis,
				gap: gap,
				first: firstMetrics.minimumSize,
				second: secondMetrics.minimumSize
			)
			guard size.width.isFinite, size.height.isFinite else {
				throw ConstrainedLayoutError.infeasible(
					scope,
					splitID,
					size,
					.zero
				)
			}
			return .init(
				minimumSize: size,
				growthWeight: firstMetrics.growthWeight + secondMetrics.growthWeight
			)
		}
	}

	private func minimumSize(
		axis: LayoutAxis,
		gap: Double,
		first: LayoutSize,
		second: LayoutSize
	) -> LayoutSize {
		switch axis {
		case .horizontal:
			return .init(
				width: first.width + gap + second.width,
				height: max(first.height, second.height)
			)
		case .vertical:
			return .init(
				width: max(first.width, second.width),
				height: first.height + gap + second.height
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

	private func merge<Leaf>(
		solution: TreeSolution<Leaf>,
		intoDividers dividers: inout [LayoutDivider],
		effectiveRatios: inout [LayoutSplitReference: Double]
	) throws where Leaf: Hashable {
		dividers.append(contentsOf: solution.dividers)
		for (reference, ratio): (LayoutSplitReference, Double) in
			solution.effectiveRatios
		{
			guard effectiveRatios[reference] == nil else {
				throw ConstrainedLayoutError.duplicateSplitReference(reference)
			}
			effectiveRatios[reference] = ratio
		}
	}

	private func layoutQuality(
		panelFrames: [PanelID: LayoutRect],
		presentation: WorkspacePresentation
	) throws -> LayoutQuality {
		var maximumDeviation: Double = 0
		var totalDeviation: Double = 0
		for (panelID, frame): (PanelID, LayoutRect) in panelFrames {
			guard let panel: PanelDescriptor = presentation.workspaces.values
				.lazy
				.compactMap({ $0.panels[panelID] })
				.first
			else {
				throw ConstrainedLayoutError.missingPanel(panelID)
			}
			let profile: LayoutProfile
			if let override: LayoutProfile = panel.profileOverride {
				profile = override
			} else if let definition: PanelKindDefinition =
				presentation.panelKinds.definition(for: panel.kindID)
			{
				profile = definition.defaultProfile
			} else {
				throw ConstrainedLayoutError.missingPanelKind(panel.kindID)
			}
			let aspectRatio: Double = frame.size.width / frame.size.height
			let deviation: Double = profile.preferredAspectRatio.distance(
				to: aspectRatio
			)
			maximumDeviation = max(maximumDeviation, deviation)
			totalDeviation += deviation
		}
		return .init(
			maximumAspectRatioDeviation: maximumDeviation,
			totalAspectRatioDeviation: totalDeviation
		)
	}

	private func dividerSort(_ lhs: LayoutDivider, _ rhs: LayoutDivider) -> Bool {
		let lhsScope: String = scopeSortKey(lhs.scope)
		let rhsScope: String = scopeSortKey(rhs.scope)
		if lhsScope != rhsScope {
			return lhsScope < rhsScope
		}
		return lhs.splitID.rawValue < rhs.splitID.rawValue
	}

	private func scopeSortKey(_ scope: LayoutScope) -> String {
		switch scope {
		case .display(let displayID):
			return "0:\(displayID.rawValue)"
		case .workspace(let workspaceID):
			return "1:\(workspaceID.rawValue)"
		}
	}
}

private struct LeafLayoutMetrics {
	let minimumSize: LayoutSize
	let growthWeight: Double
}

private struct TreeLayoutMetrics {
	let minimumSize: LayoutSize
	let growthWeight: Double
}

private struct TreeSolution<Leaf> where Leaf: Hashable {
	let leafFrames: [Leaf: LayoutRect]
	let dividers: [LayoutDivider]
	let effectiveRatios: [LayoutSplitReference: Double]
}

private struct SplitFrames {
	let first: LayoutRect
	let divider: LayoutRect
	let second: LayoutRect
}
