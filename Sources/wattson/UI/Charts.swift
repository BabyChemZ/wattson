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


/// Time series as columns rather than a filled line.
///
/// Drawn on a Canvas because a series can hold a few hundred samples, and a
/// Rectangle per sample would build that many views on every refresh. Columns
/// beat an area chart here: with only a handful of readings an area chart is a
/// nearly flat line, while bars stay individually legible from the first one.
struct BarChart: View {
    let values: [Double]
    var tint: Color = .cpuTint
    var ceiling: Double = 100
    var guides: [Double] = [25, 50, 75, 100]
    /// How many columns to draw regardless of how many samples there are.
    ///
    /// Several hundred hairline bars is visual noise, not information: nobody
    /// reads a single second off a chart. Samples are averaged into this many
    /// buckets instead, which gives each column room to breathe and makes the
    /// shape of the last hour legible at a glance.
    var columns: Int = 48

    var body: some View {
        Canvas { context, size in
            for guide in guides {
                let y = size.height * (1 - min(guide / ceiling, 1))
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(.gray.opacity(0.14)), lineWidth: 0.5)
            }

            let buckets = Self.bucket(values, into: columns)
            guard !buckets.isEmpty else { return }

            let slot = size.width / CGFloat(columns)
            let barWidth = max(2, slot * 0.58)

            // Two layers per column: the bucket's peak in a faint wash, its
            // mean solid on top. Averaging alone flattens the spikes that make
            // a load chart worth looking at — a burst lasting a few seconds
            // disappears into the surrounding minute. This keeps the spike
            // visible as headroom above the body of the bar while the solid
            // part still reads as the level.
            for (index, bucket) in buckets.enumerated() {
                let x = CGFloat(index) * slot + (slot - barWidth) / 2

                let peakRatio = min(max(bucket.peak / ceiling, 0), 1)
                if peakRatio > 0 {
                    let peakHeight = max(2, size.height * peakRatio)
                    context.fill(
                        Path(roundedRect: CGRect(x: x, y: size.height - peakHeight,
                                                 width: barWidth, height: peakHeight),
                             cornerRadius: min(barWidth / 2, 2)),
                        with: .color(tint.opacity(0.22)))
                }

                let meanRatio = min(max(bucket.mean / ceiling, 0), 1)
                let meanHeight = max(1.5, size.height * meanRatio)
                context.fill(
                    Path(roundedRect: CGRect(x: x, y: size.height - meanHeight,
                                             width: barWidth, height: meanHeight),
                         cornerRadius: min(barWidth / 2, 2)),
                    with: .color(tint.opacity(0.5 + 0.3 * meanRatio)))
            }
        }
    }

    struct Bucket {
        var mean: Double
        var peak: Double
    }

    /// Reduce the series to `count` buckets, oldest first, keeping both the
    /// average and the highest sample in each. A short series occupies fewer
    /// columns rather than being stretched across the full width.
    static func bucket(_ values: [Double], into count: Int) -> [Bucket] {
        guard count > 0, !values.isEmpty else { return [] }
        guard values.count > count else {
            return values.map { Bucket(mean: $0, peak: $0) }
        }

        let size = Double(values.count) / Double(count)
        return (0..<count).map { index in
            let start = Int(Double(index) * size)
            let end = max(start + 1, Int(Double(index + 1) * size))
            let slice = values[start..<min(end, values.count)]
            guard !slice.isEmpty else { return Bucket(mean: 0, peak: 0) }
            return Bucket(mean: slice.reduce(0, +) / Double(slice.count),
                          peak: slice.max() ?? 0)
        }
    }
}

/// One process in a ranked list.
///
/// The bar is the row's background rather than a separate strip beneath it.
/// A label, a number and a rule stacked in three bands reads as clutter once
/// there are six of them; filling the row itself gives the same comparison in
/// one band, and keeps the type on a single baseline down the list.
struct ProcessBar: View {
    let name: String
    let value: Double
    let caption: String
    /// The largest value in the list, so rows are comparable to each other.
    let peak: Double
    var tint: Color = .cpuTint

    private var fraction: Double {
        min(max(value / max(peak, 0.0001), 0), 1)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.ui(11.5))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(caption)
                .font(.figure(11, .medium))
                .foregroundStyle(Color.inkMuted)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5.5)
        .background(
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.inkFaint.opacity(0.05))
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tint.opacity(0.15))
                        .frame(width: max(5, geo.size.width * fraction))
                }
            }
        )
    }
}


/// A labelled rule, for dividing a card into sections without nesting cards.
struct SectionRule: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Text(text.uppercased())
                .font(.ui(9, .semibold))
                .tracking(0.7)
                .foregroundStyle(Color.inkFaint)
            Rectangle()
                .fill(Color.hairline)
                .frame(height: 0.5)
        }
        .padding(.top, 2)
    }
}

/// Legend entry with the colour swatch and value on one baseline, so a column
/// of them aligns down the page.
struct LegendRow: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
            Text(label).font(.ui(11)).foregroundStyle(Color.inkMuted)
            Spacer(minLength: 12)
            Text(value).font(.figure(11, .medium)).foregroundStyle(Color.ink)
        }
    }
}


/// A chart with its axes labelled.
///
/// A trace without a scale is decoration: you can see that something rose,
/// but not to what, or when. The guide values are drawn against the same
/// geometry the chart uses so labels line up with the rules exactly.
struct AxisChart<Content: View>: View {
    let ceiling: Double
    var guides: [Double] = [25, 50, 75, 100]
    var unit: String = "%"
    /// Left edge and right edge of the time range, already formatted.
    var startLabel: String = ""
    var endLabel: String = ""
    var midLabels: [String] = []
    var height: CGFloat = 104
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 7) {
                ZStack(alignment: .topLeading) {
                    // Reserve the column, then place each label at its rule.
                    Color.clear.frame(width: 30, height: height)
                    ForEach(guides, id: \.self) { guide in
                        Text("\(Int(guide))\(unit)")
                            .font(.figure(8.5))
                            .foregroundStyle(Color.inkFaint)
                            .frame(width: 30, alignment: .trailing)
                            .offset(y: height * (1 - CGFloat(min(guide / ceiling, 1))) - 5)
                    }
                }
                content.frame(height: height)
            }

            HStack(spacing: 0) {
                Color.clear.frame(width: 37)
                Text(startLabel)
                ForEach(midLabels, id: \.self) { label in
                    Spacer()
                    Text(label)
                }
                Spacer()
                Text(endLabel)
            }
            .font(.figure(8.5))
            .foregroundStyle(Color.inkFaint)
        }
    }
}
