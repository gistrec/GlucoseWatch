import Charts
import SwiftUI

/// Кривая без осей для циферблата: коридор, линия последних часов и пунктир
/// прогноза. Цвет одной линией, а не по зонам: на циферблате в режиме
/// tinted система всё равно перекрасит её в один тон.
struct Sparkline: View {
    let now: Now
    let date: Date
    var hours = 3.0

    var body: some View {
        let start = date.addingTimeInterval(-hours * 3600)
        let points = curve(from: start)
        let tail = now.isStale(at: date) ? [] : forecast
        let values = points.map(\.1) + tail.map(\.1)
        let low = now.target.low / Glucose.mgdlPerMmol
        let high = now.target.high / Glucose.mgdlPerMmol
        let bottom = min(low - 0.5, values.min() ?? low)
        let top = max(high + 0.5, values.max() ?? high)
        let end = tail.last?.0 ?? date

        Chart {
            RectangleMark(
                xStart: .value("t", start), xEnd: .value("t", end),
                yStart: .value("mmol", low), yEnd: .value("mmol", high)
            )
            .foregroundStyle(.green.opacity(0.2))

            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("t", point.0), y: .value("mmol", point.1), series: .value("s", "c\(point.2)"))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .foregroundStyle(.primary)
            }
            ForEach(Array(tail.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("t", point.0), y: .value("mmol", point.1), series: .value("s", "forecast"))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .foregroundStyle(.secondary)
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: bottom...top)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
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
