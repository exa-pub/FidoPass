# GPT Developer Context

1. **Read `gpt.dev/struct.md` before making any changes.** It captures the current project layout, file responsibilities, and architectural conventions.
2. **Update `gpt.dev/struct.md` after adjusting code structure.** If you move files, rename modules, or change ownership of components, reflect it there immediately.
3. `FidoPassCore` is modular: libfido2 and cryptographic work lives inside dedicated services (`Devices/`, `Secrets/`, `Enrollment/`). UI layers interact only with the public façade `FidoPassCore.shared` (or protocol-based injections for tests).
4. **Write code comments and long-form documentation in English.** This keeps the project consistent for all contributors.
4. The SwiftUI app is organised by responsibility (`ViewModels/`, `Views/<…>`, `Components/`, `Services/`). When creating new screens, follow the same folder structure and prefer reusable components.
5. Use the service wrappers (`ClipboardService`, `KeyboardLayoutService`) for system integrations; avoid calling AppKit APIs directly from views.
6. Toasts and overlay UIs live in `Views/Shared/`. Add new shared affordances near existing ones to encourage reuse.
7. For tests, rely on the protocols under `Sources/FidoPassCore/Protocols`. Store shared mocks/utilities inside `Tests/<ModuleName>Tests/Support/`.
8. Keep additional scripts or human-facing docs in separate folders (`Scripts/`, `Docs/`, etc.) so that source trees stay focused.
9. Anything merged into the repository must follow the English-only rule.

If you reshape the architecture, record the rationale briefly in `struct.md` so future contributors understand the evolution.
