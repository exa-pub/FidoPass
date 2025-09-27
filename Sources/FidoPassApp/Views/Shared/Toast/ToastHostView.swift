import SwiftUI

struct ToastHostView: View {
    let toast: AccountsViewModel.ToastMessage?

    var body: some View {
        Group {
            if let toast {
                ToastView(toast: toast)
                    .frame(maxWidth: 480)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}
