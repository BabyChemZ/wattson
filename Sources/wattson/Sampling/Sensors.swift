import Foundation

/// Temperatures grouped the way someone reads them, rather than as 116 raw keys.
///
/// Apple's key naming is undocumented but consistent by prefix: Tp* are
/// performance cores, Te* efficiency cores, Tg* the GPU, Ts*/Ta* skin and
/// ambient, TVD*/TCM* the power delivery. Individual cores fluctuate a lot, so
/// a cluster is reported by its hottest sensor — that is the one that decides
/// when the system throttles.
struct SensorReadings: Equatable {
    var performanceCore: Double?
    var efficiencyCore: Double?
    var gpu: Double?
    var powerDelivery: Double?
    var skin: Double?
    var hottest: (name: String, value: Double)?
    var all: [String: Double] = [:]
    var fanRPM: [Double] = []

    /// The single number worth showing as "CPU temperature".
    var cpu: Double? {
        [performanceCore, efficiencyCore].compactMap { $0 }.max()
    }

    static func == (a: SensorReadings, b: SensorReadings) -> Bool {
        a.all == b.all && a.fanRPM == b.fanRPM
    }

    static func from(_ temperatures: [String: Double], fans: [Double]) -> SensorReadings {
        func peak(_ prefixes: [String]) -> Double? {
            temperatures.filter { key, _ in prefixes.contains { key.hasPrefix($0) } }
                .values.max()
        }

        var readings = SensorReadings()
        readings.all = temperatures
        readings.fanRPM = fans
        readings.performanceCore = peak(["Tp"])
        readings.efficiencyCore = peak(["Te"])
        readings.gpu = peak(["Tg"])
        readings.powerDelivery = peak(["TVD", "TCM"])
        readings.skin = peak(["Ts", "Ta"])
        if let hottest = temperatures.max(by: { $0.value < $1.value }) {
            readings.hottest = (hottest.key, hottest.value)
        }
        return readings
    }
}
