import Foundation
@testable import TeaserKit

enum Failure: Error {
	case assertion(String)
}

func require(_ condition: Bool, _ message: String) throws {
	guard condition else { throw Failure.assertion(message) }
}

func run() throws {
	let directory: URL = FileManager.default.temporaryDirectory
		.appendingPathComponent("teaser-bundle-tests-\(UUID().uuidString)")
	try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

	try require(
		AppBundleResources.missingFiles(in: nil) == AppBundleResources.requiredFiles,
		"a missing resource directory must reject every required resource"
	)
	try require(
		AppBundleResources.missingFiles(in: directory) == AppBundleResources.requiredFiles,
		"an empty resource directory must reject every required resource"
	)
	for name: String in AppBundleResources.requiredFiles {
		try Data("fixture \(name)".utf8).write(to: directory.appendingPathComponent(name))
	}
	try require(AppBundleResources.missingFiles(in: directory).isEmpty, "complete bundle rejected")

	let notice: URL = directory.appendingPathComponent("NOTICE")
	try FileManager.default.removeItem(at: notice)
	try require(AppBundleResources.missingFiles(in: directory) == ["NOTICE"], "missing notice not reported")
	try FileManager.default.createDirectory(at: notice, withIntermediateDirectories: false)
	try require(
		AppBundleResources.missingFiles(in: directory) == ["NOTICE"],
		"a directory must not be accepted as a notice file"
	)
	try FileManager.default.removeItem(at: directory)
	print("Teaser bundle regression passed: 5 cases (temporary files only; no App launch)")
}

try run()
