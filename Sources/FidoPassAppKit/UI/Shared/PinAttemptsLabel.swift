import SwiftUI
import FidoPassCore

/// Remaining PIN attempts; a blocked key requires a reset that erases its credentials.
struct PinAttemptsLabel: View {
    let remaining: Int

    var body: some View {
        Label(text, systemImage: remaining <= 1 ? "exclamationmark.triangle.fill" : "info.circle")
            .font(.caption)
            .foregroundStyle(color)
    }

    private var text: String {
        switch remaining {
        case 0:  return "Locked — no attempts left"
        case 1:  return "1 attempt left before this key is blocked"
        default: return "\(remaining) attempts left"
        }
    }

    private var color: Color {
        switch remaining {
        case 0, 1: return .red
        case 2, 3: return .orange
        default:   return .secondary
        }
    }
}
