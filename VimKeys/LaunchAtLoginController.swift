import Foundation
import ServiceManagement

protocol LaunchAtLoginStore {
    func register() throws
    func unregister() throws
    var status: SMAppService.Status { get }
}

extension SMAppService: LaunchAtLoginStore {}

@MainActor
final class LaunchAtLoginController {
    private let store: any LaunchAtLoginStore

    init(store: any LaunchAtLoginStore = SMAppService.mainApp) {
        self.store = store
    }

    var isEnabled: Bool {
        store.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try store.register()
        } else {
            try store.unregister()
        }
    }
}
