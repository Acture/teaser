import ApplicationServices
import AXSwift
@testable import Swindler

// This function is type-checked, never called. It measures the internal bridge
// needed in a small upstream patch; @testable is NOT a shipping integration.
@MainActor
func accessibilityElement(of window: Swindler.Window) -> AXUIElement? {
	(window.delegate as? OSXWindowDelegate<AXSwift.UIElement, AXSwift.Application, AXSwift.Observer>)?
		.axElement.element
}

print("Swindler internal identity bridge compiled; no window services initialized")
