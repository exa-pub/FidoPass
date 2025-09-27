import SwiftUI

struct NoDevicesState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "usb.cable")
                .font(.system(size: 42))
                .foregroundColor(.secondary)
            Text("Connect a device")
                .font(.headline)
            Text("FidoPass will show accounts as soon as a key is connected.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SelectDeviceState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "hand.point.left.fill")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("Select a device")
                .font(.headline)
            Text("Click a device in the sidebar to view its accounts.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
