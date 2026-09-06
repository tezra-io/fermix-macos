import Foundation

/// The protocol-version rule of M34 §7.1, owned in one place.
///
/// The version is a window on both sides: the app speaks the set its contract
/// publishes, `hello` reports the daemon's, and the negotiated version is the
/// highest the two share. Two refusals follow and they mean opposite things — an
/// empty intersection is `incompatibleProtocol` and nothing can be done, while a
/// method whose minimum exceeds the negotiated version is
/// `methodRequiresNewerEngine` and the restart onto the bundled engine is
/// exactly what fixes it.
///
/// Both the live client and the fixture gateway run this function rather than
/// each carrying its own ladder, so a surface developed against the double is
/// developed against the rule the socket actually applies.
public enum ManagementNegotiation {
    /// The highest version both sides speak, or nil where they share none.
    public static func highestShared(
        speakable: [Int],
        daemon: ManagementProtocolRange
    ) -> Int? {
        speakable.filter { daemon.window.contains($0) }.max()
    }

    /// The version `method` would be sent under, or the refusal §7.1 names.
    ///
    /// The order keeps the two refusals distinct: a shared version has to exist
    /// at all before a method's minimum can be compared with it.
    public static func negotiate(
        method: ManagementMethod,
        contract: ManagementContract,
        daemon: ManagementProtocolRange
    ) throws -> Int {
        guard let negotiated = highestShared(
            speakable: contract.speakableVersions,
            daemon: daemon
        ) else {
            throw ManagementError.incompatibleProtocol(
                app: contract.speakableVersions,
                daemon: daemon
            )
        }

        let required = contract.minimumVersion(for: method)
        guard required <= negotiated else {
            throw ManagementError.methodRequiresNewerEngine(
                method: method,
                required: required,
                negotiated: negotiated
            )
        }
        return negotiated
    }
}
