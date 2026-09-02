import Foundation
import CLibfido2

/// The part of device access that callers outside the module may need to substitute.
///
/// Deliberately narrow: opening a device hands out a raw `fido_dev_t *`, which must not
/// appear in any public signature. Everything that needs an open device sits behind the
/// higher-level service protocols instead.
public protocol DeviceListing: Sendable {
    func listDevices(limit: Int) throws -> [FidoDevice]
}
