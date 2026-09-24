import AppKit

/// The canvas's published accessibility elements: one `AXGroup` per placed
/// Panel, hung under the canvas view, which is itself a group under the canvas
/// window.
///
/// Publishing a tree is the server half of accessibility and needs no
/// permission. It is the opposite of the client half the rest of the App uses:
/// adopting a provider window reads *another* application's elements and does
/// require the Accessibility service. Nothing here calls `AXIsProcessTrusted`,
/// asks for it, or touches another process, so a headless harness can build and
/// update this tree without prompting anyone.
///
/// Elements are cached by `PanelID` and mutated in place. Handing the
/// accessibility server a fresh object on every read would invalidate the token
/// it is holding, and a screen reader's cursor would fall out of the canvas
/// every time a divider moved.
@MainActor
final class CanvasAccessibilityTree {
	private unowned let parent: NSView
	private var elements: [PanelID: NSAccessibilityElement] = [:]
	private(set) var value: CanvasAccessibility
	/// In tree order, which is the order the canvas lays the Panels out in.
	private(set) var children: [NSAccessibilityElement] = []

	init(parent: NSView, value: CanvasAccessibility) {
		self.parent = parent
		self.value = value
		apply(value)
	}

	/// Returns whether anything a reader could observe changed. The canvas
	/// re-derives a snapshot on every orchestrator tick — several times per drag
	/// frame — and most of those say nothing new about the tree.
	@discardableResult
	func update(_ next: CanvasAccessibility) -> Bool {
		guard next != value else { return false }
		value = next
		apply(next)
		return true
	}

	private func apply(_ value: CanvasAccessibility) {
		var live: Set<PanelID> = []
		children = value.panels.map { panel in
			live.insert(panel.panelID)
			let element: NSAccessibilityElement = elements[panel.panelID]
				?? makeElement(for: panel.panelID)
			elements[panel.panelID] = element
			element.setAccessibilityTitle(panel.title)
			element.setAccessibilityLabel(panel.description)
			// Spelled out, not spoken: a group role carries no value a reader
			// announces, which is exactly right for an identity an automated
			// read needs and a person does not want recited.
			element.setAccessibilityValue(panel.workspaceID)
			element.setAccessibilityHelp(panel.shortfall)
			element.setAccessibilityFocused(panel.isFocused)
			element.setAccessibilityFrameInParentSpace(
				.init(
					x: panel.frame.minX,
					y: panel.frame.minY,
					width: panel.frame.size.width,
					height: panel.frame.size.height
				)
			)
			return element
		}
		// A Panel that left the canvas keeps no element: a stale group would
		// report a rectangle nothing is drawn in.
		for panelID: PanelID in elements.keys where !live.contains(panelID) {
			elements.removeValue(forKey: panelID)
		}
	}

	private func makeElement(for panelID: PanelID) -> NSAccessibilityElement {
		let element: NSAccessibilityElement = .init()
		element.setAccessibilityRole(.group)
		element.setAccessibilityRoleDescription(
			CanvasAccessibilityWording.panelRoleDescription
		)
		// The Panel's own stable identity, so an automated read can address a
		// Panel without matching on a title a provider is free to change.
		element.setAccessibilityIdentifier(panelID.rawValue)
		element.setAccessibilityParent(parent)
		return element
	}
}
