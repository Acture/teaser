import AppKit
import Foundation
@testable import TeaserKit

// Runs the desktop-free adoption regression matrix. Every case drives the same
// `DesktopStageOrchestrator` and `WindowDragObserver` the application drives,
// with only the external-window system boundary substituted. Nothing here
// installs a global event monitor, shows a window, requests Accessibility
// permission, or touches a window the user owns.

NSApplication.shared.setActivationPolicy(.prohibited)

// Every case runs even after one fails, so a mutation of the product reports
// the whole set of regressions that caught it rather than only the first.
let cases: [TestCase] = adoptionCases() + dragObserverCases()
	+ windowPickerCases()
var failures: [String] = []
for testCase: TestCase in cases {
	do {
		try testCase.run()
	} catch {
		failures.append("\(testCase.name): \(error)")
	}
}
guard failures.isEmpty else {
	for failure: String in failures {
		fputs("Teaser window-adoption regression failed: \(failure)\n", stderr)
	}
	fputs(
		"Teaser window-adoption regression: \(failures.count) of \(cases.count) cases failed\n",
		stderr
	)
	exit(1)
}
print(
	"Teaser window-adoption regression passed: \(cases.count) cases "
		+ "(no desktop, no monitors, no prompts)"
)
