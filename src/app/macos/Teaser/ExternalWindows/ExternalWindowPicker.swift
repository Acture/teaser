import CoreGraphics
import Foundation

/// One row of the window picker: a candidate plus the text a list shows for it.
/// macOS reports an empty Core Graphics name for most windows and an
/// Accessibility title only for the windows it still resolves, so a row must
/// read sensibly with no title at all.
struct ExternalWindowPickerRow: Equatable, Sendable {
	let candidate: ExternalWindowCandidate
	let primaryText: String
	let secondaryText: String

	var isAdoptable: Bool { candidate.isAdoptable }
}

/// Rows for a picker, filtered by `query` and ordered so the windows a user can
/// actually take come first. Rejected candidates are kept, because a list that
/// silently drops them cannot explain why a window is missing.
func externalWindowPickerRows(
	candidates: [ExternalWindowCandidate],
	query: String = ""
) -> [ExternalWindowPickerRow] {
	let needle: String = query.trimmingCharacters(in: .whitespacesAndNewlines)
		.lowercased()
	var seen: Set<ExternalWindowIdentity> = []
	let matching: [ExternalWindowCandidate] = candidates.filter { candidate in
		guard seen.insert(candidate.identity).inserted else { return false }
		guard !needle.isEmpty else { return true }
		return candidate.applicationName.lowercased().contains(needle)
			|| (candidate.windowTitle?.lowercased().contains(needle) ?? false)
	}
	return matching.sorted { first, second in
		if first.isAdoptable != second.isAdoptable { return first.isAdoptable }
		let names: ComparisonResult = first.applicationName.localizedCaseInsensitiveCompare(
			second.applicationName
		)
		if names != .orderedSame { return names == .orderedAscending }
		if first.isVisibleOnCurrentSpace != second.isVisibleOnCurrentSpace {
			return first.isVisibleOnCurrentSpace
		}
		return first.identity.windowID < second.identity.windowID
	}.map { candidate in
		.init(
			candidate: candidate,
			primaryText: candidate.windowTitle ?? candidate.applicationName,
			secondaryText: externalWindowPickerDetail(for: candidate)
		)
	}
}

/// The trailing detail line: application name when the title already carried it,
/// then size, then whether the window is on screen right now. A hidden window is
/// still adoptable, so its state is information, not a warning.
func externalWindowPickerDetail(for candidate: ExternalWindowCandidate) -> String {
	var parts: [String] = []
	if candidate.windowTitle != nil {
		parts.append(candidate.applicationName)
	}
	parts.append(externalWindowPickerSize(candidate.appKitScreenFrame.size))
	parts.append(candidate.isVisibleOnCurrentSpace ? "On screen" : "Hidden")
	return parts.joined(separator: " · ")
}

private func externalWindowPickerSize(_ size: CGSize) -> String {
	guard size.width.isFinite, size.height.isFinite,
		size.width.magnitude < 1e9, size.height.magnitude < 1e9
	else { return "unknown size" }
	return "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
}
