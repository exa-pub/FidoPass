import SwiftUI

struct KeyTouchPromptConfiguration {
    enum Accessory {
        case deviceName(String)
        case custom(String)

        var text: String {
            switch self {
            case .deviceName(let name):
                return name
            case .custom(let value):
                return value
            }
        }
    }

    let title: String
    let message: String
    let accent: Color
    let accessory: Accessory?

    init(title: String,
         message: String,
         accent: Color = .accentColor,
         accessory: Accessory? = nil) {
        self.title = title
        self.message = message
        self.accent = accent
        self.accessory = accessory
    }
}
