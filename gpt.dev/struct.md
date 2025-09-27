# FidoPass Project Structure

## Root Items
- `Package.swift` – Swift Package definition providing the `FidoPassCore` library, the `FidoPassApp` executable, the `CLibfido2` system module, and external dependencies.
- `Sources/` – primary source code for both the core library and the SwiftUI app.
- `Resources/` – auxiliary assets (icons, plist files, etc.).
- `gpt.dev/` – documentation intended for GPT developers (`struct.md` and `context.md`).
- `gpt.tmp/` – temporary artefacts generated during analysis (architecture overviews, drafts, notes).

## FidoPassCore — Library
```
Sources/FidoPassCore/
├── Public/
│   └── FidoPassCore.swift           # Public façade wiring the services together
├── Errors/
│   └── FidoPassError.swift          # Core error definitions
├── Models/
│   ├── Account.swift                # Resident credential model
│   ├── PasswordPolicy.swift         # Password policy configuration
│   └── FidoDevice.swift             # Device metadata + computed labels
├── Protocols/
│   ├── DeviceRepositoryProtocol.swift
│   ├── EnrollmentServiceProtocol.swift
│   ├── PortableEnrollmentServiceProtocol.swift
│   ├── SecretDerivationServiceProtocol.swift
│   └── PasswordGenerating.swift     # Contracts used for dependency injection & testing
├── Devices/
│   ├── DeviceRepository.swift       # libfido2 access, device opening, capability checks
│   └── DeviceLabelFormatter.swift   # Display/identity formatting, deterministic hashes
├── Enrollment/
│   ├── EnrollmentService.swift      # Standard enroll/enumerate/delete/update operations
│   └── PortableEnrollmentService.swift # Portable workflows (XOR, import/export key handling)
├── Secrets/
│   ├── HmacSecretService.swift      # hmac-secret assertions via libfido2
│   ├── SecretDerivationService.swift# Resident/portable salt derivation, fixed component
│   ├── PasswordGenerator.swift      # Combines derivation & HKDF to produce secret material
│   └── PasswordEngine.swift         # Maps entropy bytes to passwords, enforces char classes
├── Storage/
│   └── KeychainStore.swift          # Keychain persistence for `Account` payloads
├── Support/
│   ├── CryptoHelpers.swift          # `SecRandomCopyBytes` wrapper
│   ├── SaltFactory.swift            # Salt factories (resident, portable, fixed component)
│   └── Libfido2Context.swift        # libfido2 init + error checking helper
```

## FidoPassApp — SwiftUI Application
```
Sources/FidoPassApp/
├── App/
│   └── FidoPassApp.swift            # Entry point, WindowGroup, command handlers
├── Bootstrap/
│   └── AppActivationService.swift   # macOS activation & window focus handling
├── Services/
│   ├── ClipboardService.swift       # NSPasteboard wrapper
│   └── KeyboardLayoutService.swift  # Enforces English keyboard layout (macOS)
├── Utilities/
│   └── View+CardDecoration.swift    # Shared SwiftUI view modifiers
├── ViewModels/
│   ├── AccountsViewModel.swift                 # Published state & lifecycle hooks
│   ├── AccountsViewModel+Devices.swift         # Device listing, reload, unlock/lock
│   ├── AccountsViewModel+Passwords.swift       # Password generation, toasts, focus helpers
│   ├── AccountsViewModel+Persistence.swift     # Recent-label persistence & iCloud merge
│   └── AccountsViewModel+Enrollment.swift      # Enrollment (standard/portable) & deletion
├── Components/
│   ├── DeviceAvatarView.swift        # Device avatar with lock indicator
│   ├── DeviceColorPalette.swift      # Deterministic per-device colour selection
│   └── KeyTouchPrompt/
│       ├── KeyTouchPromptConfiguration.swift
│       └── KeyTouchPromptContainer.swift      # Overlay shown during key interaction
├── Views/
│   ├── Root/
│   │   └── ContentView.swift         # Navigation layout, alerts, toast overlay
│   ├── Devices/
│   │   ├── DeviceSidebarView.swift   # Device list sidebar
│   │   ├── UnlockPromptView.swift    # PIN entry + keyboard layout integration
│   │   └── DeviceStatesView.swift    # Empty/selection states for devices
│   ├── Accounts/
│   │   ├── AccountColumnView.swift   # Column header & filtering UI
│   │   └── AccountListView.swift     # Account list, rows, empty-state view
│   ├── AccountDetail/
│   │   ├── AccountDetailContainerView.swift  # Wrapper with key-touch overlay
│   │   └── AccountDetailView.swift   # Sections: summary, generation, portable, results
│   ├── NewAccount/
│   │   └── NewAccountView.swift      # Enrollment form (standard & portable modes)
│   └── Shared/
│       ├── SectionCard.swift         # Shared section container styling
│       ├── StatusBanner.swift        # Inline status banner
│       └── Toast/
│           ├── ToastHostView.swift
│           └── ToastView.swift
```

## Temporary & Support Directories
- `gpt.tmp/` – AI-generated artefacts created during exploration (`overview.md`, legacy structure drafts, etc.).
- `gpt.dev/` – living documentation for GPT agents (`struct.md`, `context.md`).

## Recommendations
- When adding new services or view models, follow the existing separation: define protocols, supply concrete implementations, and inject dependencies.
- Place new tests in `Tests/…`, using the protocols in `Sources/FidoPassCore/Protocols` to build mocks and stubs.
- Keep `struct.md` aligned with the real directory layout whenever files move or responsibilities change.
