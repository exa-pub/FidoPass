import SwiftUI
import FidoPassCore

/// How many PIN attempts are left before the key locks itself for good.
///
/// Eight consecutive failures are terminal, and nothing recovers from that but a factory
/// reset that wipes every credential — so the countdown is stated plainly rather than left
/// for the user to discover.
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
        case 1:  return "1 attempt left before this key locks permanently"
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
