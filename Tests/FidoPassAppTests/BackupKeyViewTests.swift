import XCTest
import SwiftUI
import FidoPassCore
import TestSupport
@testable import FidoPassAppKit

@MainActor
final class BackupKeyViewTests: AppTestCase {
    private func panelHeight(_ store: PanelStore) -> CGFloat {
        NSHostingView(rootView: PanelRootView(store: store)).fittingSize.height
    }

    func testCopyAndClipboardClearDoNotResizeTheBackupScreen() async throws {
        for account in [Account.v2Fixture(id: "vault", kind: .portable),
                        Account.portableFixture(id: "legacy", legacy: true)] {
            let (store, backend, _) = await AppTestFactory.unlockedStore(accounts: [account])
            let ref = AccountRef(try XCTUnwrap(store.visibleAccounts.first))
            await store.showBackupKey(for: ref)
            let beforeCopy = panelHeight(store)
            let exports = backend.exportCalls.count

            store.copyBackupKey()
            XCTAssertNil(store.statusText, "Copy feedback belongs beside the key, not in a growing footer")
            XCTAssertNil(store.error)
            XCTAssertEqual(store.generation.receipt?.ref, ref)
            XCTAssertEqual(store.generation.receipt?.item, .backupKey)
            XCTAssertNotNil(store.generation.secondsUntilClear)
            XCTAssertEqual(panelHeight(store), beforeCopy, accuracy: 0.5)

            store.copyBackupKey()
            XCTAssertEqual(panelHeight(store), beforeCopy, accuracy: 0.5)
            XCTAssertEqual(backend.exportCalls.count, exports, "Copying an existing backup needs no new key operation")

            store.generation.clearClipboard()
            XCTAssertNil(store.generation.secondsUntilClear)
            XCTAssertEqual(panelHeight(store), beforeCopy, accuracy: 0.5)
            store.panelDidClose()
            XCTAssertNil(store.backup)
        }
    }
}
