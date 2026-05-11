import Foundation
import GRDB
import SQLiteVec1

public enum SQLiteVec1Support {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var registered = false
        var registrationError: String?
    }

    private static let state = State()

    public static func register() throws {
        state.lock.lock()
        defer { state.lock.unlock() }

        if let registrationError = state.registrationError {
            throw StoreError.migrationFailed(registrationError)
        }
        guard !state.registered else { return }

        let rc = sqlite3_vec1_extra_init(nil)
        guard rc == 0 else {
            let message = "sqlite vec1 registration failed with code \(rc)"
            state.registrationError = message
            throw StoreError.migrationFailed(message)
        }
        state.registered = true
    }

    static func register(on db: Database) throws {
        try register()
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_extension_init(db.sqliteConnection, &message, nil)
        if let message {
            defer { sqlite3_free(message) }
            guard rc == 0 else {
                throw StoreError.migrationFailed(String(cString: message))
            }
        }
        guard rc == 0 else {
            throw StoreError.migrationFailed("sqlite vec1 connection init failed with code \(rc)")
        }
    }
}
