import Foundation

/// Everything an authenticator will say about itself for the price of one open — no PIN,
/// no touch.
///
/// Deliberately separate from `DeviceStatus`. That type is the small subset the HUD routes
/// on, and a copy of it is carried in every `DeviceStore.KeyState`; widening it to twenty
/// fields would put a full `getInfo` dump behind every routing decision. This one is read
/// on request, shown, and dropped.
///
/// Every field is optional-by-nature: authenticators differ in what they report, and a
/// missing value has to degrade to "not reported" rather than to a confident wrong number.
public struct AuthenticatorInfo: Sendable, Hashable, Codable {

    /// One entry of the authenticator's `options` map, as reported.
    ///
    /// Kept as a list of name/value pairs rather than mapped onto named properties: the set
    /// grows with every CTAP revision, and an option this build has never heard of is
    /// exactly the kind of thing the manager exists to show.
    public struct Option: Sendable, Hashable, Codable, Identifiable {
        public let name: String
        public let value: Bool
        public var id: String { name }

        public init(name: String, value: Bool) {
            self.name = name
            self.value = value
        }
    }

    public struct Algorithm: Sendable, Hashable, Codable, Identifiable {
        /// COSE identifier, e.g. `-7`.
        public let cose: Int
        /// Credential type, in practice always `public-key`.
        public let type: String
        public var id: String { "\(cose)/\(type)" }

        public init(cose: Int, type: String) {
            self.cose = cose
            self.type = type
        }

        /// Human name for the COSE identifier, or the raw number when it is not one we know.
        public var displayName: String { AuthenticatorInfo.algorithmName(cose: cose) }
    }

    /// A vendor certification the key claims, such as FIPS-CMVP or a FIDO L1/L2 level.
    public struct Certification: Sendable, Hashable, Codable, Identifiable {
        public let name: String
        public let value: UInt64
        public var id: String { name }

        public init(name: String, value: UInt64) {
            self.name = name
            self.value = value
        }
    }

    /// The size limits the key advertises. Zero means "not reported" for every one of them.
    public struct Limits: Sendable, Hashable, Codable {
        public let maxMessageSize: UInt64
        public let maxCredentialCountInList: UInt64
        public let maxCredentialIdLength: UInt64
        public let maxCredentialBlobLength: UInt64
        public let maxLargeBlob: UInt64
        public let maxRPIDsForMinPINLength: UInt64

        public init(maxMessageSize: UInt64,
                    maxCredentialCountInList: UInt64,
                    maxCredentialIdLength: UInt64,
                    maxCredentialBlobLength: UInt64,
                    maxLargeBlob: UInt64,
                    maxRPIDsForMinPINLength: UInt64) {
            self.maxMessageSize = maxMessageSize
            self.maxCredentialCountInList = maxCredentialCountInList
            self.maxCredentialIdLength = maxCredentialIdLength
            self.maxCredentialBlobLength = maxCredentialBlobLength
            self.maxLargeBlob = maxLargeBlob
            self.maxRPIDsForMinPINLength = maxRPIDsForMinPINLength
        }
    }

    // MARK: - Transport, from the open handle

    public let isFIDO2: Bool
    /// CTAPHID protocol version and the firmware triple of the transport, e.g. `2 / 5.7.4`.
    public let ctapHIDProtocol: Int
    public let ctapHIDVersion: String
    /// `wink`, `cbor`, `msg` — what the HID layer says it can do.
    public let capabilities: [String]
    public let supportsPIN: Bool
    public let supportsUV: Bool
    public let supportsCredentialManagement: Bool
    public let supportsCredentialProtection: Bool
    public let supportsPermissions: Bool
    public let hasPIN: Bool
    /// A built-in user-verification method — a fingerprint reader — is configured.
    public let hasUV: Bool
    /// PIN attempts left before the key locks itself permanently. `nil` when not reported;
    /// never render that as reassurance.
    public let pinRetriesRemaining: Int?
    /// Built-in UV attempts left. `nil` on every key without built-in UV, which is most.
    public let uvRetriesRemaining: Int?

    // MARK: - getInfo

    public let versions: [String]
    public let extensions: [String]
    public let options: [Option]
    /// Make and model, never the individual key — see `DeviceStatus.aaguid`. `nil` when the
    /// key reports all zeroes, which is how it declines to identify its model.
    public let aaguid: String?
    public let pinProtocols: [Int]
    public let algorithms: [Algorithm]
    public let transports: [String]
    public let certifications: [Certification]
    public let firmwareVersion: UInt64
    public let limits: Limits
    public let minPINLength: Int?
    public let forcePINChange: Bool
    /// Free resident-credential slots, when the key reports them.
    public let remainingResidentKeys: Int?
    public let uvAttempts: UInt64?
    /// Decoded `uv_modality` bitmask: `fingerprint`, `pin`, `face`, …
    public let uvModalities: [String]

    public init(isFIDO2: Bool,
                ctapHIDProtocol: Int,
                ctapHIDVersion: String,
                capabilities: [String],
                supportsPIN: Bool,
                supportsUV: Bool,
                supportsCredentialManagement: Bool,
                supportsCredentialProtection: Bool,
                supportsPermissions: Bool,
                hasPIN: Bool,
                hasUV: Bool,
                pinRetriesRemaining: Int?,
                uvRetriesRemaining: Int?,
                versions: [String],
                extensions: [String],
                options: [Option],
                aaguid: String?,
                pinProtocols: [Int],
                algorithms: [Algorithm],
                transports: [String],
                certifications: [Certification],
                firmwareVersion: UInt64,
                limits: Limits,
                minPINLength: Int?,
                forcePINChange: Bool,
                remainingResidentKeys: Int?,
                uvAttempts: UInt64?,
                uvModalities: [String]) {
        self.isFIDO2 = isFIDO2
        self.ctapHIDProtocol = ctapHIDProtocol
        self.ctapHIDVersion = ctapHIDVersion
        self.capabilities = capabilities
        self.supportsPIN = supportsPIN
        self.supportsUV = supportsUV
        self.supportsCredentialManagement = supportsCredentialManagement
        self.supportsCredentialProtection = supportsCredentialProtection
        self.supportsPermissions = supportsPermissions
        self.hasPIN = hasPIN
        self.hasUV = hasUV
        self.pinRetriesRemaining = pinRetriesRemaining
        self.uvRetriesRemaining = uvRetriesRemaining
        self.versions = versions
        self.extensions = extensions
        self.options = options
        self.aaguid = aaguid
        self.pinProtocols = pinProtocols
        self.algorithms = algorithms
        self.transports = transports
        self.certifications = certifications
        self.firmwareVersion = firmwareVersion
        self.limits = limits
        self.minPINLength = minPINLength
        self.forcePINChange = forcePINChange
        self.remainingResidentKeys = remainingResidentKeys
        self.uvAttempts = uvAttempts
        self.uvModalities = uvModalities
    }

    /// Whether the key can list its own credentials at all. A `false` here is the difference
    /// between "this key holds nothing" and "this key cannot be asked".
    public var canEnumerateCredentials: Bool { supportsCredentialManagement }

    /// The firmware version as the three bytes the key packs into one integer.
    public var firmwareVersionString: String {
        let major = (firmwareVersion >> 16) & 0xff
        let minor = (firmwareVersion >> 8) & 0xff
        let patch = firmwareVersion & 0xff
        return "\(major).\(minor).\(patch)"
    }

    // MARK: - What this key lets you change

    /// Value of a named option, or `nil` when the key never mentioned it.
    ///
    /// The distinction matters: CTAP uses "absent" for "not implemented" and `false` for
    /// "implemented and currently off", and offering a switch for the first would produce a
    /// control that can only fail.
    public func option(_ name: String) -> Bool? {
        options.first { $0.name == name }?.value
    }

    /// Whether the key implements `authenticatorConfig` at all. Everything below needs it.
    public var supportsConfiguration: Bool { option("authnrCfg") == true }

    /// `alwaysUv` is offered only when the key both implements config and mentions the
    /// option, whichever way it is currently set.
    public var canToggleAlwaysUV: Bool { supportsConfiguration && option("alwaysUv") != nil }
    public var alwaysUV: Bool { option("alwaysUv") == true }

    /// Raising the minimum PIN length is a one-way door — see `DeviceConfiguring`.
    public var canSetMinimumPINLength: Bool { supportsConfiguration && option("setMinPINLength") == true }

    public var canForcePINChange: Bool { supportsConfiguration && hasPIN }

    /// Most consumer keys never advertise `ep`, so this is usually absent rather than false.
    public var canEnableEnterpriseAttestation: Bool { supportsConfiguration && option("ep") != nil }
    public var enterpriseAttestationEnabled: Bool { option("ep") == true }

    /// Whether anything on this key is configurable. Used to hide the section rather than
    /// show one full of disabled controls.
    public var hasConfigurableSettings: Bool {
        canToggleAlwaysUV || canSetMinimumPINLength || canForcePINChange || canEnableEnterpriseAttestation
    }

    // MARK: - Formatting

    /// Name for a COSE algorithm identifier.
    ///
    /// Unknown identifiers keep their number rather than becoming "unknown": a key
    /// advertising an algorithm this build has not heard of is information, and collapsing
    /// every such case to one word throws it away.
    public static func algorithmName(cose: Int) -> String {
        switch cose {
        case -7: return "ES256"
        case -8: return "EdDSA"
        case -25: return "ECDH-ES256"
        case -35: return "ES384"
        case -36: return "ES512"
        case -257: return "RS256"
        case -65535: return "RS1"
        default: return "alg \(cose)"
        }
    }

    /// Decodes libfido2's `uv_modality` bitmask into the names of the modalities set.
    ///
    /// Bits this build does not know are reported as `bit N` rather than dropped, for the
    /// same reason unknown algorithms keep their number.
    public static func uvModalityNames(_ mask: UInt64) -> [String] {
        let known: [(UInt64, String)] = [
            (0x0001, "presence"),
            (0x0002, "fingerprint"),
            (0x0004, "pin"),
            (0x0008, "voice"),
            (0x0010, "face"),
            (0x0020, "location"),
            (0x0040, "eye"),
            (0x0080, "pattern"),
            (0x0100, "hand"),
            (0x0200, "none required"),
            (0x0400, "all required"),
            (0x0800, "external pin"),
            (0x1000, "external pattern"),
        ]
        guard mask != 0 else { return [] }
        var names: [String] = []
        var seen: UInt64 = 0
        for (bit, name) in known where mask & bit != 0 {
            names.append(name)
            seen |= bit
        }
        let leftover = mask & ~seen
        if leftover != 0 {
            for shift in 0..<64 where leftover & (1 << UInt64(shift)) != 0 {
                names.append("bit \(shift)")
            }
        }
        return names
    }
}
