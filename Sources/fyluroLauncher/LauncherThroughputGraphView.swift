import SwiftUI

struct LauncherThroughputGraphView: View {
    let tracker: LauncherThroughputTracker
    let isCompleted: Bool
    let liveBytesPerSecond: Double?
    let formattedTotalCopied: String
    let formattedTotalVerified: String

    @State private var hoveredBucket: LauncherThroughputBucket?
    @State private var hoveredLocationX: CGFloat?

    private let plotHeight: CGFloat = 64
    private let yAxisWidth: CGFloat = 58
    private let yAxisSpacing: CGFloat = 8

    var body: some View {
        let yMax = LauncherThroughputTracker.niceAxisCeiling(for: peakDisplayedRate)

        VStack(alignment: .leading, spacing: 6) {
            headerRow

            HStack(alignment: .center, spacing: yAxisSpacing) {
                yAxisColumn(yMax: yMax)
                    .frame(width: yAxisWidth, height: plotHeight, alignment: .trailing)

                GeometryReader { geometry in
                    let width = max(geometry.size.width, 1)
                    let height = max(geometry.size.height, 1)
                    let maxBuckets = max(40, Int(width / 2.5))
                    let buckets = LauncherThroughputTracker.buckets(from: tracker.samples, maxBuckets: maxBuckets)
                    let xSpan = timelineSpanSeconds

                    Canvas { context, size in
                        drawGrid(in: context, size: size)

                        guard !buckets.isEmpty else {
                            return
                        }

                        let points = plottedPoints(
                            buckets: buckets,
                            width: size.width,
                            height: size.height,
                            xSpan: xSpan,
                            yMax: yMax
                        )

                        drawPhaseSegments(in: context, points: points, height: size.height)
                        drawPhaseTransitions(in: context, points: points, height: size.height)

                        if let hovered = hoveredPoint(for: hoveredLocationX, in: points) {
                            drawHoverIndicator(in: context, point: hovered, height: size.height)
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let points = plottedPoints(
                                buckets: buckets,
                                width: width,
                                height: height,
                                xSpan: xSpan,
                                yMax: yMax
                            )
                            if let match = hoveredPoint(for: location.x, in: points) {
                                hoveredLocationX = location.x
                                hoveredBucket = match.bucket
                            } else {
                                hoveredLocationX = nil
                                hoveredBucket = nil
                            }
                        case .ended:
                            hoveredLocationX = nil
                            hoveredBucket = nil
                        }
                    }
                }
                .frame(height: plotHeight)
            }

            footerRow
                .padding(.leading, yAxisWidth + yAxisSpacing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: LauncherRadius.control, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: LauncherRadius.control, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.8)
                )
        )
    }

    private func yAxisColumn(yMax: Double) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(LauncherThroughputTracker.formattedRate(yMax))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(LauncherThroughputTracker.formattedRate(yMax * 0.5))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("0")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private struct PlottedPoint {
        let bucket: LauncherThroughputBucket
        let x: CGFloat
        let y: CGFloat
    }

    private var timelineSpanSeconds: TimeInterval {
        let recorded = tracker.timelineDurationSeconds
        if isCompleted {
            return max(recorded, 1.0)
        }
        return max(recorded, LauncherThroughputTracker.minimumLiveTimelineSpanSeconds)
    }

    private var peakDisplayedRate: Double {
        tracker.samples.map(\.bytesPerSecond).max() ?? 0
    }

    @ViewBuilder
    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                legendRow(
                    phase: .copy,
                    valueText: isCompleted
                        ? completedPhaseValue(
                            averageRate: tracker.averageCopyBytesPerSecond,
                            totalText: formattedTotalCopied
                        )
                        : runningPhaseValue(phase: .copy, totalText: formattedTotalCopied),
                    isEmphasized: !isCompleted && tracker.activePhase == .copy
                )

                legendRow(
                    phase: .verify,
                    valueText: isCompleted
                        ? completedPhaseValue(
                            averageRate: tracker.averageVerifyBytesPerSecond,
                            totalText: formattedTotalVerified
                        )
                        : runningPhaseValue(phase: .verify, totalText: formattedTotalVerified),
                    isEmphasized: !isCompleted && tracker.activePhase == .verify
                )
            }

            Spacer(minLength: 8)

            if let hovered = hoveredBucket {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 5) {
                        phaseDot(for: hovered.phase)
                        Text("\(hovered.phase.displayName) • \(hoveredRateText(for: hovered))")
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Text(hoveredTimestampText(for: hovered))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func legendRow(
        phase: LauncherThroughputPhase,
        valueText: String,
        isEmphasized: Bool
    ) -> some View {
        HStack(spacing: 6) {
            phaseDot(for: phase)
            Text(phase.displayName)
                .font(.caption.weight(isEmphasized ? .medium : .regular))
                .foregroundStyle(isEmphasized ? .primary : .secondary)
                .frame(width: 40, alignment: .leading)
            Text(valueText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(isEmphasized ? .primary : .secondary)
                .lineLimit(1)
        }
    }

    private var footerRow: some View {
        HStack {
            Text("0s")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
            if peakDisplayedRate >= 1 {
                Text("Peak \(LauncherThroughputTracker.formattedRate(peakDisplayedRate))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Text("•")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
            Text(LauncherThroughputTracker.formattedElapsed(timelineSpanSeconds))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private func phaseDot(for phase: LauncherThroughputPhase) -> some View {
        Circle()
            .fill(phaseColor(for: phase))
            .frame(width: 7, height: 7)
    }

    private func phaseColor(for phase: LauncherThroughputPhase) -> Color {
        switch phase {
        case .copy:
            return LauncherTone.info.color
        case .verify:
            return LauncherTone.success.color
        }
    }

    private func hoveredRateText(for bucket: LauncherThroughputBucket) -> String {
        let rate = LauncherThroughputTracker.formattedRate(bucket.bytesPerSecond)
        return bucket.isAggregated ? "\(rate) avg" : rate
    }

    private func hoveredTimestampText(for bucket: LauncherThroughputBucket) -> String {
        if bucket.isAggregated {
            let start = LauncherThroughputTracker.formattedElapsed(bucket.startElapsedSeconds)
            let end = LauncherThroughputTracker.formattedElapsed(bucket.endElapsedSeconds)
            if start != end {
                return "\(start)–\(end)"
            }
        }
        return "at \(LauncherThroughputTracker.formattedElapsed(bucket.endElapsedSeconds))"
    }

    private func runningPhaseValue(phase: LauncherThroughputPhase, totalText: String) -> String {
        if tracker.activePhase == phase, let liveBytesPerSecond {
            return "\(totalText) • \(LauncherThroughputTracker.formattedRate(liveBytesPerSecond))"
        }
        return totalText
    }

    private func completedPhaseValue(
        averageRate: Double?,
        totalText: String
    ) -> String {
        if let averageRate {
            return "avg \(LauncherThroughputTracker.formattedRate(averageRate))"
        }
        return totalText
    }

    private func plottedPoints(
        buckets: [LauncherThroughputBucket],
        width: CGFloat,
        height: CGFloat,
        xSpan: TimeInterval,
        yMax: Double
    ) -> [PlottedPoint] {
        let topPadding: CGFloat = 4
        let bottomPadding: CGFloat = 2
        let usableHeight = max(height - topPadding - bottomPadding, 1)
        let denominator = max(xSpan, 0.001)

        return buckets.map { bucket in
            let midpointElapsed = (bucket.startElapsedSeconds + bucket.endElapsedSeconds) * 0.5
            let xFraction = min(max(midpointElapsed / denominator, 0), 1)
            let yFraction = min(max(bucket.bytesPerSecond / yMax, 0), 1)
            let x = CGFloat(xFraction) * width
            let y = topPadding + usableHeight * (1 - CGFloat(yFraction))
            return PlottedPoint(bucket: bucket, x: x, y: y)
        }
    }

    private func hoveredPoint(for locationX: CGFloat?, in points: [PlottedPoint]) -> PlottedPoint? {
        guard let locationX, !points.isEmpty else {
            return nil
        }
        if let lastX = points.last?.x, locationX > lastX + 16 {
            return nil
        }
        return points.min(by: { abs($0.x - locationX) < abs($1.x - locationX) })
    }

    private func drawGrid(in context: GraphicsContext, size: CGSize) {
        let guideColor = Color.primary.opacity(0.08)
        let baselineColor = Color.primary.opacity(0.14)

        var topLine = Path()
        topLine.move(to: CGPoint(x: 0, y: 4))
        topLine.addLine(to: CGPoint(x: size.width, y: 4))
        context.stroke(topLine, with: .color(guideColor), lineWidth: 0.5)

        var midLine = Path()
        midLine.move(to: CGPoint(x: 0, y: size.height * 0.5))
        midLine.addLine(to: CGPoint(x: size.width, y: size.height * 0.5))
        context.stroke(midLine, with: .color(guideColor), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

        var baseLine = Path()
        baseLine.move(to: CGPoint(x: 0, y: size.height - 2))
        baseLine.addLine(to: CGPoint(x: size.width, y: size.height - 2))
        context.stroke(baseLine, with: .color(baselineColor), lineWidth: 0.8)
    }

    private func drawPhaseSegments(
        in context: GraphicsContext,
        points: [PlottedPoint],
        height: CGFloat
    ) {
        let baselineY = height - 2
        var segmentStart = 0

        while segmentStart < points.count {
            let phase = points[segmentStart].bucket.phase
            var segmentEnd = segmentStart
            while segmentEnd + 1 < points.count,
                  points[segmentEnd + 1].bucket.phase == phase {
                segmentEnd += 1
            }

            let segment = Array(points[segmentStart...segmentEnd])
            let color = phaseColor(for: phase)

            if segment.count == 1, let only = segment.first {
                var bar = Path()
                bar.move(to: CGPoint(x: only.x, y: baselineY))
                bar.addLine(to: CGPoint(x: only.x, y: only.y))
                context.stroke(bar, with: .color(color), lineWidth: 2)
            } else if let first = segment.first, let last = segment.last {
                var linePath = Path()
                linePath.move(to: CGPoint(x: first.x, y: first.y))
                for point in segment.dropFirst() {
                    linePath.addLine(to: CGPoint(x: point.x, y: point.y))
                }

                var fillPath = linePath
                fillPath.addLine(to: CGPoint(x: last.x, y: baselineY))
                fillPath.addLine(to: CGPoint(x: first.x, y: baselineY))
                fillPath.closeSubpath()

                let gradient = Gradient(colors: [
                    color.opacity(0.24),
                    color.opacity(0.03),
                ])
                context.fill(
                    fillPath,
                    with: .linearGradient(
                        gradient,
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: baselineY)
                    )
                )
                context.stroke(
                    linePath,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                )
            }

            segmentStart = segmentEnd + 1
        }
    }

    private func drawPhaseTransitions(
        in context: GraphicsContext,
        points: [PlottedPoint],
        height: CGFloat
    ) {
        guard points.count >= 2 else { return }
        for index in 1..<points.count {
            if points[index].bucket.phase != points[index - 1].bucket.phase {
                let dividerX = (points[index - 1].x + points[index].x) * 0.5
                var divider = Path()
                divider.move(to: CGPoint(x: dividerX, y: 2))
                divider.addLine(to: CGPoint(x: dividerX, y: height - 2))
                context.stroke(
                    divider,
                    with: .color(Color.primary.opacity(0.22)),
                    style: StrokeStyle(lineWidth: 0.8, dash: [2, 2])
                )
            }
        }
    }

    private func drawHoverIndicator(
        in context: GraphicsContext,
        point: PlottedPoint,
        height: CGFloat
    ) {
        let color = phaseColor(for: point.bucket.phase)

        var hairline = Path()
        hairline.move(to: CGPoint(x: point.x, y: 2))
        hairline.addLine(to: CGPoint(x: point.x, y: height - 2))
        context.stroke(hairline, with: .color(Color.primary.opacity(0.35)), lineWidth: 1)

        let dotRect = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
        context.fill(Path(ellipseIn: dotRect), with: .color(color))
        context.stroke(Path(ellipseIn: dotRect), with: .color(Color(nsColor: .controlBackgroundColor)), lineWidth: 1.5)
    }
}
