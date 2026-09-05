import Foundation

/// Keeps auxiliary windows reachable after screen or Dock changes.
enum WindowPlacement {
    static func clamped(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        return CGRect(x: min(max(frame.minX, visible.minX), visible.maxX - width),
                      y: min(max(frame.minY, visible.minY), visible.maxY - height),
                      width: width, height: height)
    }

    static func beside(_ other: CGRect, size: CGSize, in visible: CGRect) -> CGRect {
        let candidates = [
            CGRect(x: other.minX - size.width - 12, y: other.maxY - size.height, width: size.width, height: size.height),
            CGRect(x: other.maxX + 12, y: other.maxY - size.height, width: size.width, height: size.height),
            CGRect(x: other.minX, y: other.maxY + 12, width: size.width, height: size.height),
            CGRect(x: other.minX, y: other.minY - size.height - 12, width: size.width, height: size.height)
        ]
        if let fit = candidates.first(where: { visible.contains($0) }) { return fit }
        // On a small screen use the largest side space, reducing the test tool if needed.
        let left = max(0, other.minX - visible.minX - 12)
        let right = max(0, visible.maxX - other.maxX - 12)
        let width = min(size.width, max(left, right))
        if width >= 360 {
            let x = left >= right ? visible.minX : other.maxX + 12
            return clamped(CGRect(x: x, y: other.maxY - size.height, width: width, height: size.height), to: visible)
        }
        // Leave the lower onboarding actions visible when no side can fit.
        return clamped(CGRect(x: visible.minX, y: other.maxY + 12,
                              width: size.width, height: min(size.height, max(160, visible.maxY - other.maxY - 12))), to: visible)
    }
}
