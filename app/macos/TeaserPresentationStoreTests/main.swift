import Darwin
import Foundation

private enum TestFailure: Error { case assertion(String) }

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
	guard condition() else { throw TestFailure.assertion(message) }
}

private func run() throws {
	let files: FileManager = .default
	let directory: URL = files.temporaryDirectory.appendingPathComponent("teaser-store-test-\(UUID().uuidString)")
	try files.createDirectory(at: directory, withIntermediateDirectories: false)
	defer { try? files.removeItem(at: directory) }
	try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
	let store: PresentationStore = .init(documentURL: directory.appendingPathComponent("presentation.json"))
	let missing: PresentationDocument? = try store.load()
	try expect(missing == nil, "a missing file must produce no saved state")
	let document: PresentationDocument = .init(
		presentation: ShowcasePreset.presentation(), notes: [.init(panelID: ShowcasePreset.notesPanelID, text: "中文 notes")]
	)
	try store.save(document)
	let loaded: PresentationDocument? = try store.load()
	try expect(loaded == document, "presentation and Notes must round-trip")
	let directoryMode: Int? = try files.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
	let fileMode: Int? = try files.attributesOfItem(atPath: store.documentURL.path)[.posixPermissions] as? Int
	try expect(directoryMode == 0o700 && fileMode == 0o600, "existing directories and saved files must be private")
	let data: Data = try Data(contentsOf: store.documentURL)
	let encoded: String = String(decoding: data, as: UTF8.self)
	let future: Data = Data(encoded.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 99").utf8)
	try future.write(to: store.documentURL)
	do {
		_ = try store.load()
		throw TestFailure.assertion("future schemas must be rejected")
	} catch PresentationStoreError.unsupportedSchemaVersion(99) {}
	let afterFailedLoad: Data = try Data(contentsOf: store.documentURL)
	try expect(afterFailedLoad == future, "a failed load must not overwrite the source")
}

do {
	try run()
	print("Teaser presentation-store tests passed")
} catch {
	fputs("Teaser presentation-store tests failed: \(error)\n", stderr)
	exit(1)
}
