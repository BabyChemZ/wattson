import SwiftUI

/// A sparkline: the shape of a process's recent CPU, drawn small enough to sit
/// inside a table row. Scaled to the series' own peak, because the question a
/// row answers is "what is this doing lately", not "how does it compare to
/// everything else".
struct Sparkline: View {
    let values: [Double]
    var tint: Color = .inkFaint
    /// Draw against a fixed ceiling instead of the series peak, when rows need
    /// to be comparable.
    var ceiling: Double?

    var body: some View {
        GeometryReader { geo in
            let peak = max(ceiling ?? values.max() ?? 1, 1)
            let points = positions(in: geo.size, peak: peak)

            ZStack {
                if points.count > 1 {
                    // Filled area first, so the stroke sits on top of it.
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        for p in points { path.addLine(to: p) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x,
                                                 y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(tint.opacity(0.16))

                    Path { path in
                        path.move(to: points[0])
                        for p in points.dropFirst() { path.addLine(to: p) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.2,
                                                     lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func positions(in size: CGSize, peak: Double) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let ratio = min(max(value / peak, 0), 1)
            return CGPoint(x: CGFloat(index) * step,
                           y: size.height * (1 - CGFloat(ratio)))
        }
    }
}

/// A thin horizontal meter. Used for CPU and memory in the vitals strip.
struct Meter: View {
    let fraction: Double
    var tint: Color = .accent

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.hairline)
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 3)
    }
}

/// One reading in the vitals strip: a label, a number, and a meter or sparkline.
struct Vital<Accessory: View>: View {
    let label: String
    let value: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.ui(9, .medium))
                .tracking(0.7)
                .foregroundStyle(Color.inkFaint)
            Text(value)
                .font(.figure(15, .regular))
                .foregroundStyle(Color.ink)
            accessory.frame(height: 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Daily history: one bar per day, median with the day's peak ghosted behind it.
/// This is the long memory made visible — the thing that makes today's reading
/// mean something.
struct DailyBars: View {
    let points: [DailyPoint]
    /// Today's reading, drawn as a rule across the chart for comparison.
    var todayMarker: Double?

    var body: some View {
        GeometryReader { geo in
            let peak = max(points.map(\.peak).max() ?? 1, todayMarker ?? 0, 1)
            let count = max(points.count, 1)
            let slot = geo.size.width / CGFloat(count)
            let barWidth = max(1.5, min(slot - 1.5, 7))

            ZStack(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(points.enumerated()), id: \.element.id) { _, point in
                        ZStack(alignment: .bottom) {
                            Capsule()
                                .fill(Color.inkFaint.opacity(0.28))
                                .frame(width: barWidth,
                                       height: max(1, geo.size.height * point.peak / peak))
                            Capsule()
                                .fill(Color.inkMuted)
                                .frame(width: barWidth,
                                       height: max(1, geo.size.height * point.median / peak))
                        }
                        .frame(width: slot)
                    }
                }

                if let today = todayMarker {
                    let y = geo.size.height * (1 - min(today / peak, 1))
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Color.accent,
                            style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
        }
    }
}

/// A segmented ring. Segments are drawn in order around the circle, each with
/// its own colour, so a single glance splits a total into its parts.
struct Donut: View {
    struct Segment: Identifiable {
        let id = UUID()
        let value: Double
        let color: Color
    }

    let segments: [Segment]
    let centerText: String
    var centerCaption: String?
    var lineWidth: CGFloat = 10

    private var total: Double { max(segments.reduce(0) { $0 + $1.value }, 0.0001) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.hairline, lineWidth: lineWidth)

            ForEach(Array(offsets.enumerated()), id: \.element.segment.id) { _, item in
                Circle()
                    .trim(from: item.start, to: item.end)
                    .stroke(item.segment.color,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }

            VStack(spacing: 1) {
                Text(centerText)
                    .font(.figure(17, .medium))
                    .foregroundStyle(Color.ink)
                if let centerCaption {
                    Text(centerCaption)
                        .font(.ui(9))
                        .foregroundStyle(Color.inkFaint)
                }
            }
        }
    }

    private var offsets: [(segment: Segment, start: CGFloat, end: CGFloat)] {
        var running = 0.0
        return segments.map { segment in
            let start = running / total
            running += max(segment.value, 0)
            return (segment, CGFloat(start), CGFloat(running / total))
        }
    }
}

/// A filled area chart over time, with horizontal guides. Values are percentages.
struct AreaChart: View {
    let values: [Double]
    var tint: Color = .cpuTint
    var ceiling: Double = 100
    var guides: [Double] = [25, 50, 75, 100]

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(guides, id: \.self) { guide in
                    let y = geo.size.height * (1 - min(guide / ceiling, 1))
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Color.hairline, lineWidth: 0.5)
                }

                if values.count > 1 {
                    let points = positions(in: geo.size)
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        for p in points { path.addLine(to: p) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x,
                                                 y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.45), tint.opacity(0.06)],
                                         startPoint: .top, endPoint: .bottom))

                    Path { path in
                        path.move(to: points[0])
                        for p in points.dropFirst() { path.addLine(to: p) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                }
            }
        }
    }

    private func positions(in size: CGSize) -> [CGPoint] {
        let step = size.width / CGFloat(max(values.count - 1, 1))
        return values.enumerated().map { index, value in
            CGPoint(x: CGFloat(index) * step,
                    y: size.height * (1 - CGFloat(min(max(value / ceiling, 0), 1))))
        }
    }
}

/// One labelled bar, used for per-core load and memory breakdowns.
struct LabelledBar: View {
    let label: String
    let value: String
    let fraction: Double
    var tint: Color = .cpuTint

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.ui(11)).foregroundStyle(Color.inkMuted)
                Spacer()
                Text(value).font(.figure(11, .medium)).foregroundStyle(Color.ink)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.hairline)
                    Capsule().fill(tint)
                        .frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
                }
            }
            .frame(height: 4)
        }
    }
}

/// Colour swatch plus label, for chart legends.
struct LegendDot: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label).font(.ui(10.5)).foregroundStyle(Color.inkMuted)
            Text(value).font(.figure(10.5, .medium)).foregroundStyle(Color.ink)
        }
    }
}


/// A determinate progress bar with an optional inline percentage.
struct ProgressBar: View {
    let fraction: Double
    var tint: Color = .accent
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.hairline)
                Capsule()
                    .fill(tint)
                    .frame(width: max(height, geo.size.width * min(max(fraction, 0), 1)))
                    .animation(.easeOut(duration: 0.4), value: fraction)
            }
        }
        .frame(height: height)
    }
}

/// Live countdown to the next sample. Without it the app looks idle between
/// ticks, which reads as stalled rather than waiting.
struct NextSampleCountdown: View {
    let nextTickAt: Date?
    let isSampling: Bool
    let isWarmingUp: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(caption(now: context.date))
                .font(.ui(10))
                .foregroundStyle(Color.inkFaint)
                .monospacedDigit()
        }
    }

    private func caption(now: Date) -> String {
        if isSampling {
            return isWarmingUp ? L("first samples…", "首次采样…")
                               : L("sampling…", "采样中…")
        }
        guard let nextTickAt else { return L("starting…", "启动中…") }
        let remaining = Int(max(0, nextTickAt.timeIntervalSince(now).rounded()))
        return L("next in \(remaining)s", "\(remaining) 秒后采样")
    }
}
