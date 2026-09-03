import FidoPassCore
import Foundation

/// The key is waiting to be touched.
struct TouchPrompt: Equatable {
    var title: String
    var message: String
    var deviceName: String
    var startedAt: Date = Date()
}
