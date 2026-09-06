import Foundation
import IOKit

/// Minimal client for the System Management Controller.
///
/// Apple Silicon exposes no public temperature API, and `AppleSMC` does not
/// appear under `ioreg -c AppleSMC` — but the service is there and accepts a
/// user client, which is how Activity Monitor's peers read sensors. Keys are
/// four-character codes; their names and count differ per chip, so rather than
/// hard-coding a list this enumerates whatever the machine actually has.
final class SMC {
    private var connection: io_connect_t = 0

    // Selector and commands from the SMC protocol.
    private static let kernelIndex: UInt32 = 2
    private static let cmdReadBytes: UInt8 = 5
    private static let cmdReadKeyInfo: UInt8 = 9
    private static let cmdReadIndex: UInt8 = 8

    /// The request struct has to match the SMC's layout byte for byte.
    static func layoutIsValid() -> Bool { MemoryLayout<SMCKeyData>.stride == 80 }

    init?() {
        guard Self.layoutIsValid() else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess
        else { return nil }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    // MARK: - Public reads

    /// Temperature keys, discovered once. Enumerating every key on the machine
    /// takes most of a second; reading a known list of them takes milliseconds,
    /// so the discovery happens once and the reads reuse it.
    private var temperatureKeys: [String]?

    /// The hottest few sensors per group, refreshed occasionally.
    ///
    /// Reading all 116 sensors costs 60ms. Each group is summarised by its
    /// hottest member anyway, so routine passes read only a handful of
    /// candidates and a full sweep re-picks them now and then, in case the
    /// hottest core changes.
    private var representativeKeys: [String] = []
    private var passesSinceFullSweep = 0
    private static let fullSweepEvery = 12

    /// Temperature sensors in Celsius. `full` forces every sensor to be read —
    /// used by the sensors page, which shows them all.
    func temperatures(full: Bool = false) -> [String: Double] {
        if temperatureKeys == nil {
            temperatureKeys = keys().filter { $0.hasPrefix("T") }
        }
        let sweep = full || representativeKeys.isEmpty
            || passesSinceFullSweep >= Self.fullSweepEvery
        passesSinceFullSweep = sweep ? 0 : passesSinceFullSweep + 1

        let candidates = sweep ? (temperatureKeys ?? []) : representativeKeys
        var result: [String: Double] = [:]
        for key in candidates {
            guard let value = readFloat(key), value > 5, value < 130 else { continue }
            result[key] = value
        }
        if sweep { representativeKeys = Self.pickRepresentatives(from: result) }
        return result
    }

    /// Two hottest sensors from each naming group, so a group's peak stays
    /// tracked even if the individual hottest core changes.
    private static func pickRepresentatives(from readings: [String: Double]) -> [String] {
        let groups = ["Tp", "Te", "Tg", "Ts", "Ta", "TVD", "TCM", "TB"]
        var picked: [String] = []
        for group in groups {
            let members = readings.filter { $0.key.hasPrefix(group) }
                .sorted { $0.value > $1.value }
                .prefix(2)
                .map(\.key)
            picked.append(contentsOf: members)
        }
        return picked
    }

    /// Fan speeds in RPM, if the machine has fans at all.
    func fanSpeeds() -> [Double] {
        guard let count = readFloat("FNum"), count >= 1 else { return [] }
        return (0..<Int(count)).compactMap { readFloat(String(format: "F%dAc", $0)) }
    }

    // MARK: - Key enumeration

    private func keys() -> [String] {
        guard let total = readUInt32("#KEY"), total > 0, total < 10_000 else { return [] }
        return (0..<total).compactMap { keyName(atIndex: $0) }
    }

    private func keyName(atIndex index: UInt32) -> String? {
        var input = SMCKeyData()
        input.data8 = Self.cmdReadIndex
        input.data32 = index
        guard let output = call(input) else { return nil }
        return Self.decode(key: output.key)
    }

    // MARK: - Value reads

    private func readFloat(_ key: String) -> Double? {
        guard let (info, output) = read(key) else { return nil }
        let type = Self.decode(key: info.keyInfo.dataType)
        let bytes = Self.byteArray(output.bytes, count: Int(info.keyInfo.dataSize))

        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                    | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: raw))
        case "sp78":
            // Signed fixed point, 7 integer bits and 8 fractional.
            guard bytes.count >= 2 else { return nil }
            return Double(Int8(bitPattern: bytes[0])) + Double(bytes[1]) / 256
        case "ui8 ", "ui16", "ui32":
            return Double(Self.unsignedInteger(bytes))
        default:
            return nil
        }
    }

    private func readUInt32(_ key: String) -> UInt32? {
        guard let (info, output) = read(key) else { return nil }
        let bytes = Self.byteArray(output.bytes, count: Int(info.keyInfo.dataSize))
        return UInt32(Self.unsignedInteger(bytes))
    }

    /// Two round trips: the key's type and size, then its bytes.
    private func read(_ key: String) -> (SMCKeyData, SMCKeyData)? {
        guard let encoded = Self.encode(key: key) else { return nil }

        var infoRequest = SMCKeyData()
        infoRequest.key = encoded
        infoRequest.data8 = Self.cmdReadKeyInfo
        guard let info = call(infoRequest), info.keyInfo.dataSize > 0 else { return nil }

        var valueRequest = SMCKeyData()
        valueRequest.key = encoded
        valueRequest.data8 = Self.cmdReadBytes
        valueRequest.keyInfo = info.keyInfo
        guard let output = call(valueRequest) else { return nil }
        return (info, output)
    }

    private func call(_ input: SMCKeyData) -> SMCKeyData? {
        var input = input
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride

        let result = IOConnectCallStructMethod(
            connection, Self.kernelIndex,
            &input, MemoryLayout<SMCKeyData>.stride,
            &output, &outputSize)
        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    // MARK: - Four-character codes

    private static func encode(key: String) -> UInt32? {
        let scalars = Array(key.utf8)
        guard scalars.count == 4 else { return nil }
        return scalars.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func decode(key: UInt32) -> String {
        let bytes = [UInt8(truncatingIfNeeded: key >> 24),
                     UInt8(truncatingIfNeeded: key >> 16),
                     UInt8(truncatingIfNeeded: key >> 8),
                     UInt8(truncatingIfNeeded: key)]
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func byteArray(_ tuple: SMCBytes, count: Int) -> [UInt8] {
        var bytes = withUnsafeBytes(of: tuple) { Array($0) }
        if count > 0, count < bytes.count { bytes = Array(bytes.prefix(count)) }
        return bytes
    }

    private static func unsignedInteger(_ bytes: [UInt8]) -> UInt64 {
        // SMC integers arrive big-endian.
        bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

// MARK: - Protocol structures
// Layouts must match the SMC's expectations byte for byte.

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: IOByteCount32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    /// Explicit tail padding. Swift packs a nested struct by its size (9) while
    /// C lays it out by its stride (12), which shifts every following field and
    /// leaves the whole request four bytes short of what the SMC expects.
    private var reserved: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

private struct SMCKeyData {
    /// Must be exactly 80 bytes; `SMC.verifyLayout()` asserts it.
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                           0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}
