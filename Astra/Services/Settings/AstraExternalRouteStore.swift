import Foundation
import Combine

@MainActor
final class AstraExternalRouteStore: ObservableObject {
    static let shared = AstraExternalRouteStore()

    @Published private(set) var pendingRoute: AstraExternalRoute?

    private init() {}

    func submit(_ route: AstraExternalRoute) {
        pendingRoute = route
    }

    func clear(_ route: AstraExternalRoute) {
        guard pendingRoute?.id == route.id else { return }
        pendingRoute = nil
    }
}
