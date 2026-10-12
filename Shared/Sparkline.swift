import Charts
import SwiftUI

/// Кривая для циферблата (Н8 из макетов): шесть часов, линия в цветах зон,
/// пунктиры порогов с подписями и часы по низу. Цифры нет — она в верхнем
/// слоте.
struct Sparkline: View {
    let now: Now
    let date: Date
    var hours = 6.0
    /// Рисовать ли под кривой «обычный день» — коридор и медиану за две
    /// недели. Для этого отдельная complication, а не настройка.
    var usual = false

    var body: some View {
        let start = date.addingTimeInterval(-hours * 3600)
        let points = curve(from: start)
        let pieces = Dictionary(grouping: points, by: \.2).sorted { $0.key < $1.key }.map(\.value)
        let tail = now.isStale(at: date) ? [] : forecast
        let end = tail.last?.0 ?? date
        let band = usual ? now.usualDay(from: start, to: end) : []
        let values = points.map(\.1) + tail.map(\.1) + band.flatMap { [$0.low, $0.high] }
        let low = now.target.low / Glucose.mgdlPerMmol
        let high = now.target.high / Glucose.mgdlPerMmol
        let bottom = min(low - 0.5, values.min() ?? low)
        let top = max(high + 0.5, values.max() ?? high)
        let stale = now.isStale(at: date)

        Chart {
            RectangleMark(
                xStart: .value("t", start), xEnd: .value("t", end),
                yStart: .value("mmol", low), yEnd: .value("mmol", high)
            )
            .foregroundStyle(.green.opacity(0.16))

            ForEach([low, high], id: \.self) { level in
                RuleMark(y: .value("mmol", level))
                    .lineStyle(StrokeStyle(lineWidth: 0.6, dash: [2, 3]))
                    .foregroundStyle(.gray)
                    .annotation(position: .top, alignment: .trailing, spacing: 0) {
                        Text(String(format: "%.1f", level))
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(.gray)
                    }
            }

            ForEach(band) { slot in
                AreaMark(x: .value("t", slot.date), yStart: .value("mmol", slot.low), yEnd: .value("mmol", slot.high), series: .value("s", "usual\(slot.run)"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.gray.opacity(0.25))
                LineMark(x: .value("t", slot.date), y: .value("mmol", slot.median), series: .value("s", "median\(slot.run)"))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [2, 2]))
                    .foregroundStyle(.gray.opacity(0.75))
            }

            ForEach(Array(pieces.enumerated()), id: \.offset) { index, piece in
                ForEach(Array(piece.enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value("t", point.0), y: .value("mmol", point.1), series: .value("s", "c\(index)"))
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(stale
                            ? AnyShapeStyle(Color.gray)
                            : AnyShapeStyle(Glucose.zones(piece.map { $0.1 * Glucose.mgdlPerMmol }, now.target)))
                }
            }
            ForEach(Array(tail.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("t", point.0), y: .value("mmol", point.1), series: .value("s", "forecast"))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: bottom...top)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour)) { _ in
                AxisGridLine().foregroundStyle(.gray.opacity(0.3))
                AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)), centered: false)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.gray)
            }
        }
    }

    /// Точки с номером куска: пропуск сенсора дольше четверти часа рвёт
    /// линию, а не тянет прямую через дыру.
    private func curve(from start: Date) -> [(Date, Double, Int)] {
        var points = (now.series?.day.points ?? [])
            .filter { $0.count == 2 && $0[0] >= start.timeIntervalSince1970 }
            .map { ($0[0], $0[1]) }
        if let latest = now.latest, latest.t > (points.last?.0 ?? 0) {
            points.append((latest.t, latest.mgdl))
        }
        var piece = 0
        var previous = -Double.infinity
        return points.map { t, mgdl in
            if t - previous > Glucose.staleAfter { piece += 1 }
            previous = t
            return (Date(timeIntervalSince1970: t), mgdl / Glucose.mgdlPerMmol, piece)
        }
    }

    private var forecast: [(Date, Double)] {
        guard let latest = now.latest, let points = now.forecast?.points else { return [] }
        let ahead = points.filter { $0.count == 2 && $0[0] > latest.t }
        guard !ahead.isEmpty else { return [] }
        return ([[latest.t, latest.mgdl]] + ahead).map {
            (Date(timeIntervalSince1970: $0[0]), $0[1] / Glucose.mgdlPerMmol)
        }
    }
}
