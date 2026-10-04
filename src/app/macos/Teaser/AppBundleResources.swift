import Foundation

enum AppBundleResources {
	static let requiredFiles: [String] = [
		"LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md", "TRADEMARKS.md",
	]

	static func missingFiles(in resourceDirectory: URL?) -> [String] {
		guard let resourceDirectory else { return requiredFiles }
		return requiredFiles.filter { name in
			var isDirectory: ObjCBool = false
			let exists: Bool = FileManager.default.fileExists(
				atPath: resourceDirectory.appendingPathComponent(name).path,
				isDirectory: &isDirectory
			)
			return !exists || isDirectory.boolValue
		}
	}
}
