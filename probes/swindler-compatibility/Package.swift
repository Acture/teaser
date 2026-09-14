// swift-tools-version: 6.2
import PackageDescription

// Compile-only audit, not an application dependency. No Swindler.initialize().
let package: Package = .init(
	name: "SwindlerCompatibilityProbe",
	platforms: [.macOS(.v14)],
	dependencies: [
		.package(url: "https://github.com/tmandry/Swindler.git",
			revision: "bf2c42f1db8bb1aa6c0b634d9fca3ab4bd37931d"),
	],
	targets: [
		.executableTarget(name: "SwindlerProbe", dependencies: [
			.product(name: "Swindler", package: "Swindler"),
		], swiftSettings: [.swiftLanguageMode(.v6), .treatAllWarnings(as: .error)]),
	]
)
