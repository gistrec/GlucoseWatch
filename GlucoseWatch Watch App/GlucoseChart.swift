import Charts
import SwiftUI

/// Кривая как на странице: зелёный коридор целевого диапазона, линия в цветах
/// зон, пунктир прогноза модели, отметки еды и болюсов. Касание меняет окно.
struct GlucoseChart: View {
    let now: Now
    let date: Date

    static let windows: [Double] = [3, 6, 12, 24]
    @AppStorage("chartHours") private var hours = 3.0

    /// Дольше этого между соседними точками — пропуск сенсора, линию рвём,
    /// а не тянем прямую через дыру.
    private static let gap: TimeInterval = 15 * 60

    var body: some View {
        let start = date.addingTimeInterval(-hours * 3600)
        let segments = segments(from: start)
        let forecast = forecastLine
        let values = segments.flatMap { $0.map(\.mmol) } + forecast.map(\.mmol)
        let low = now.target.low / Glucose.mgdlPerMmol
        let high = now.target.high / Glucose.mgdlPerMmol
        let bottom = min(low - 1, (values.min() ?? low) - 0.5)
        let top = max(high + 1, (values.max() ?? high) + 0.5)
        let end = forecast.last?.date ?? date

        VStack(alignment: .leading, spacing: 2) {
            Text("\(Int(hours)) ч")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Chart {
                RectangleMark(
                    xStart: .value("t", start),
                    xEnd: .value("t", end),
                    yStart: .value("mmol", low),
                    yEnd: .value("mmol", high)
                )
                .foregroundStyle(.green.opacity(0.15))

                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    ForEach(segment) { point in
                        LineMark(x: .value("t", point.date), y: .value("mmol", point.mmol), series: .value("s", "c\(index)"))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                            .foregroundStyle(Glucose.zones(segment.map(\.mgdl), now.target))
                    }
                }

                ForEach(forecast) { point in
                    LineMark(x: .value("t", point.date), y: .value("mmol", point.mmol), series: .value("s", "forecast"))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        .foregroundStyle(.white.opacity(0.7))
                }

                RuleMark(x: .value("t", date))
                    .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                    .foregroundStyle(.gray)

                ForEach(events(from: start, in: now.events?.meals), id: \.self) { t in
                    PointMark(x: .value("t", t), y: .value("mmol", bottom + 0.3))
                        .symbolSize(18)
                        .foregroundStyle(.orange)
                }
                ForEach(events(from: start, in: now.events?.bolus), id: \.self) { t in
                    PointMark(x: .value("t", t), y: .value("mmol", bottom + 0.3))
                        .symbol(.triangle)
                        .symbolSize(18)
                        .foregroundStyle(.cyan)
                }
            }
            .chartXScale(domain: start...end)
            .chartYScale(domain: bottom...top)
            .chartYAxis {
                AxisMarks(position: .trailing, values: [low, high]) { value in
                    AxisGridLine().foregroundStyle(.gray.opacity(0.3))
                    AxisValueLabel {
                        if let mmol = value.as(Double.self) {
                            Text(String(format: "%.1f", mmol)).font(.system(size: 9))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: hours <= 6 ? 1 : hours <= 12 ? 3 : 6)) { _ in
                    AxisGridLine().foregroundStyle(.gray.opacity(0.2))
                    AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)))
                        .font(.system(size: 9))
                }
            }
            .frame(height: 100)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            let index = Self.windows.firstIndex(of: hours) ?? 0
            hours = Self.windows[(index + 1) % Self.windows.count]
        }
    }

    private struct Point: Identifiable {
        let date: Date
        let mgdl: Double
        var id: Date { date }
        var mmol: Double { mgdl / Glucose.mgdlPerMmol }

        init(_ t: Double, _ mgdl: Double) {
            self.date = Date(timeIntervalSince1970: t)
            self.mgdl = mgdl
        }
    }

    /// Точки окна, разрезанные по пропускам. Последний замер свежее шага
    /// серии, поэтому дописывается в конец: иначе линия отстаёт от цифры.
    private func segments(from start: Date) -> [[Point]] {
        var points = (now.series?.day.points ?? [])
            .filter { $0.count == 2 && $0[0] >= start.timeIntervalSince1970 }
            .map { Point($0[0], $0[1]) }
        if let latest = now.latest, latest.t > (points.last?.date.timeIntervalSince1970 ?? 0) {
            points.append(Point(latest.t, latest.mgdl))
        }

        var segments: [[Point]] = []
        for point in points {
            if let last = segments.last?.last, point.date.timeIntervalSince(last.date) <= Self.gap {
                segments[segments.count - 1].append(point)
            } else {
                segments.append([point])
            }
        }
        return segments
    }

    /// От последнего замера через точки модели — та же ломаная, что на
    /// странице. Устаревший прогноз выжимка не несёт вовсе.
    private var forecastLine: [Point] {
        guard let latest = now.latest, !now.isStale(at: date), let forecast = now.forecast else { return [] }
        let ahead = forecast.points.filter { $0.count == 2 && $0[0] > latest.t }
        guard !ahead.isEmpty else { return [] }
        return [Point(latest.t, latest.mgdl)] + ahead.map { Point($0[0], $0[1]) }
    }

    private func events(from start: Date, in lane: [[Double]]?) -> [Date] {
        (lane ?? [])
            .compactMap(\.first)
            .map { Date(timeIntervalSince1970: $0) }
            .filter { $0 >= start && $0 <= date }
    }
}
