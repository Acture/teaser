// swift-tools-version: 6.2
import PackageDescription

// The Swift half of Teaser. `TeaserKit` holds every product source that does not
// need the application bundle or a built libghostty; each test target is a plain
// executable whose `main.swift` runs its cases and exits non-zero on failure, so
// the harnesses stay readable without an XCTest rewrite.
//
// `.swiftLanguageMode(.v6)` carries Swift 6 language mode with complete strict
// concurrency, and `.treatAllWarnings(as: .error)` is the gate's
// `-warnings-as-errors`. Neither needs `unsafeFlags`.
let strict: [SwiftSetting] = [
	.swiftLanguageMode(.v6),
	.treatAllWarnings(as: .error),
]

func testExecutable(_ name: String) -> Target {
	.executableTarget(
		name: name,
		dependencies: ["TeaserKit"],
		path: "app/macos/\(name)",
		swiftSettings: strict
	)
}

let package: Package = Package(
	name: "Teaser",
	// Matches `LSMinimumSystemVersion` in the application's Info.plist. Without
	// it the availability annotations across AppKit and SwiftUI do not resolve.
	platforms: [.macOS(.v14)],
	dependencies: [
		.package(url: "https://github.com/stevengharris/SplitView.git", exact: "3.5.3"),
		.package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", exact: "3.1.0"),
	],
	targets: [
		// Declares `_AXUIElementGetWindow` so window identity is the window
		// server's own `CGWindowID` instead of a geometry guess. Teaser links no
		// other private declaration.
		.target(
			name: "TeaserPrivateAccessibility",
			path: "app/macos/TeaserPrivateAccessibility",
			publicHeadersPath: "include"
		),
		.target(
			name: "TeaserKit",
			dependencies: [
				.product(name: "SplitView", package: "SplitView"),
				.product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
				.target(name: "TeaserPrivateAccessibility"),
			],
			path: "app/macos/Teaser",
			exclude: [
				"Info.plist",
				// Imports `GhosttyKit`, which arrives with a built libghostty.
				"Terminal/TerminalSurfaceAdapter.swift",
			],
			swiftSettings: strict
		),
		.executableTarget(
			name: "Teaser",
			dependencies: ["TeaserKit"],
			path: "app/macos/TeaserLauncher",
			swiftSettings: strict
		),
		testExecutable("TeaserProbeTests"),
		testExecutable("TeaserLayoutTests"),
		testExecutable("TeaserPresentationStoreTests"),
		testExecutable("TeaserDesktopStageTopologyTests"),
		testExecutable("TeaserDesktopStageControlsTests"),
		testExecutable("TeaserDesktopStageSafetyTests"),
		testExecutable("TeaserExternalWindowTests"),
		testExecutable("TeaserWindowAdoptionTests"),
		testExecutable("TeaserHerdrTests"),
	]
)
