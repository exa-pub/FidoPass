import SwiftUI
import FidoPassCore

struct AuthenticatorOverviewView: View {
    let info: AuthenticatorInfo
    let inventory: CredentialInventory?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ManagerSectionHeader(title: "Overview",
                                 note: "Everything this authenticator reports about itself. Read without a PIN and without a touch.")

            group("Identity") {
                ManagerRow(label: "Model (AAGUID)", value: info.aaguid ?? "not reported",
                           monospaced: info.aaguid != nil, copyable: info.aaguid != nil)
                ManagerRow(label: "Firmware", value: info.firmwareVersionString)
                ManagerRow(label: "CTAPHID", value: "protocol \(info.ctapHIDProtocol) · \(info.ctapHIDVersion)")
                ManagerRow(label: "Versions", value: list(info.versions))
                ManagerRow(label: "Transports", value: list(info.transports))
                ManagerRow(label: "HID capabilities", value: list(info.capabilities))
                if !info.certifications.isEmpty {
                    ManagerRow(label: "Certifications",
                               value: info.certifications.map { "\($0.name) \($0.value)" }.joined(separator: ", "))
                }
            }

            group("PIN and verification") {
                ManagerRow(label: "PIN configured", value: info.hasPIN ? "yes" : "no — enrolment needs one")
                ManagerRow(label: "PIN attempts left",
                           value: info.pinRetriesRemaining.map(String.init) ?? "not reported")
                ManagerRow(label: "Shortest PIN allowed",
                           value: info.minPINLength.map(String.init) ?? "4 (the protocol minimum)")
                if info.forcePINChange {
                    ManagerRow(label: "PIN change", value: "required before anything else")
                }
                ManagerRow(label: "PIN protocols", value: list(info.pinProtocols.map(String.init)))
                ManagerRow(label: "Built-in verification", value: info.hasUV ? "configured" : "none")
                if !info.uvModalities.isEmpty {
                    ManagerRow(label: "Verification methods", value: list(info.uvModalities))
                }
                if let uvRetries = info.uvRetriesRemaining {
                    ManagerRow(label: "Verification attempts left", value: String(uvRetries))
                }
                if let attempts = info.uvAttempts {
                    ManagerRow(label: "Verification attempts allowed", value: String(attempts))
                }
            }

            group("Capabilities") {
                ManagerRow(label: "Credential management",
                           value: info.supportsCredentialManagement ? "supported" : "not supported — credentials cannot be listed")
                ManagerRow(label: "Credential protection", value: info.supportsCredentialProtection ? "supported" : "not supported")
                ManagerRow(label: "Permissions", value: info.supportsPermissions ? "supported" : "not supported")
                ManagerRow(label: "Configuration", value: info.supportsConfiguration ? "supported" : "not supported")
                ManagerRow(label: "FIDO2", value: info.isFIDO2 ? "yes" : "no — U2F only")
            }

            group("Storage") {
                ManagerRow(label: "Free credential slots",
                           value: info.remainingResidentKeys.map(String.init) ?? "not reported")
                if let inventory {
                    ManagerRow(label: "Discoverable credentials", value: "\(inventory.credentialCount)")
                    ManagerRow(label: "Relying parties", value: "\(inventory.relyingParties.count)")
                    if let bytes = inventory.largeBlobArrayBytes {
                        ManagerRow(label: "Large blob array", value: "\(bytes) B of \(info.limits.maxLargeBlob) B")
                    }
                }
            }

            group("Extensions") {
                if info.extensions.isEmpty {
                    ManagerRow(label: "—", value: "none reported")
                } else {
                    // One per row rather than a comma list: these are the names a reader
                    // comes here to check for, and a run-on line is the wrong shape for that.
                    ForEach(info.extensions, id: \.self) { name in
                        ManagerRow(label: name, value: "supported")
                    }
                }
            }

            group("Algorithms") {
                ForEach(info.algorithms) { algorithm in
                    ManagerRow(label: algorithm.displayName, value: "\(algorithm.cose) · \(algorithm.type)")
                }
                if info.algorithms.isEmpty {
                    ManagerRow(label: "—", value: "none reported")
                }
            }

            group("Options") {
                // Shown whole, including names this build has never heard of: an unfamiliar
                // option is exactly the kind of thing this window exists to surface.
                ForEach(info.options) { option in
                    ManagerRow(label: option.name, value: option.value ? "true" : "false")
                }
                if info.options.isEmpty {
                    ManagerRow(label: "—", value: "none reported")
                }
            }

            group("Limits") {
                ManagerRow(label: "Max message size", value: bytes(info.limits.maxMessageSize))
                ManagerRow(label: "Max credentials in a list", value: number(info.limits.maxCredentialCountInList))
                ManagerRow(label: "Max credential id length", value: bytes(info.limits.maxCredentialIdLength))
                ManagerRow(label: "Max credBlob length", value: bytes(info.limits.maxCredentialBlobLength))
                ManagerRow(label: "Max large blob", value: bytes(info.limits.maxLargeBlob))
                ManagerRow(label: "Max RP ids for minimum PIN length", value: number(info.limits.maxRPIDsForMinPINLength))
            }

            Text("Device paths change on every reconnect, so they are never stored. The AAGUID names the model, not this key — it is shared by every key like it.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
        }
    }

    private func list(_ values: [String]) -> String {
        values.isEmpty ? "none reported" : values.joined(separator: ", ")
    }

    private func bytes(_ value: UInt64) -> String { value == 0 ? "not reported" : "\(value) B" }
    private func number(_ value: UInt64) -> String { value == 0 ? "not reported" : "\(value)" }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.top, 14)
            .padding(.bottom, 2)
        content()
    }
}

