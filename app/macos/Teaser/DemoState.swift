import Combine
import Foundation

@MainActor
final class DemoState: ObservableObject {
	@Published private(set) var presentation: PresentationState

	init(presentation: PresentationState = .demoInitial()) {
		self.presentation = presentation
	}

	func send(_ action: DemoAction) {
		DemoReducer.reduce(state: &presentation, action: action)
	}
}
