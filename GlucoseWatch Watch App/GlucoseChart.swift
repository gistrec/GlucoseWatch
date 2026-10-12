import Charts
import SwiftUI

/// Кривая как на странице: зелёный коридор целевого диапазона, линия в цветах
/// зон, пунктир прогноза модели, отметки еды и болюсов. Касание подписи окна
/// меняет окно; касание графика включает курсор, который ведёт колёсико.
struct GlucoseChart: View {
    let now: Now
    let date: Date

    static let windows: [Double] = [3, 6, 12, 24]
    @AppStorage("chartHours") private var hours = 3.0

    /// Курсор: индекс точки кривой, его крутит колёсико. Пока курсора нет,
    /// колёсико листает страницы — график забирает его только по касанию.
    @State private var scrubbing = false
    @State private var cursor = 0.0
    @FocusState private var focused: Bool

    /// Дольше этого между соседними точками — пропуск сенсора, линию рвём,
    /// а не тянем прямую через дыру.
    private static let gap: TimeInterval = 15 * 60

    var body: some View {
        let start = date.addingTimeInterval(-hours * 3600)
        let segments = segments(from: start)
        let forecast = forecastLine
        let end = forecast.last?.date ?? date
        let yesterday = yesterday(from: start, to: end)
        let values = segments.flatMap { $0.map(\.mmol) } + forecast.map(\.mmol) + yesterday.flatMap { $0.map(\.mmol) }
        let low = now.target.low / Glucose.mgdlPerMmol
        let high = now.target.high / Glucose.mgdlPerMmol
        let bottom = min(low - 1, (values.min() ?? low) - 0.5)
        let top = max(high + 1, (values.max() ?? high) + 0.5)

        let points = segments.flatMap { $0 }
        let picked = scrubbing && !points.isEmpty ? points[min(max(Int(cursor.rounded()), 0), points.count - 1)] : nil

        VStack(alignment: .leading, spacing: 2) {
            if let picked {
                cursorLabel(picked)
            } else {
                Text("\(Int(hours)) ч")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 12)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let index = Self.windows.firstIndex(of: hours) ?? 0
                        hours = Self.windows[(index + 1) % Self.windows.count]
                    }
            }

            Chart {
                RectangleMark(
                    xStart: .value("t", start),
                    xEnd: .value("t", end),
                    yStart: .value("mmol", low),
                    yEnd: .value("mmol", high)
                )
                .foregroundStyle(.green.opacity(0.15))

                // Вчера в те же часы — тонкая серая линия под сегодняшней:
                // видно, повторяется ли картина. Без цвета зон, чтобы не
                // спорить с сегодняшней кривой.
                ForEach(Array(yesterday.enumerated()), id: \.offset) { index, segment in
                    ForEach(segment) { point in
                        LineMark(x: .value("t", point.date), y: .value("mmol", point.mmol), series: .value("s", "y\(index)"))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 1.2, lineCap: .round))
                            .foregroundStyle(.gray.opacity(0.55))
                    }
                }

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

                // Пороги подписаны на самих линиях, внутри графика: ось справа
                // отъедала ширину, и кривая не доходила до края экрана.
                ForEach([low, high], id: \.self) { level in
                    RuleMark(y: .value("mmol", level))
                        .lineStyle(StrokeStyle(lineWidth: 0.6, dash: [2, 3]))
                        .foregroundStyle(.gray.opacity(0.6))
                        .annotation(position: .top, alignment: .trailing, spacing: 1) {
                            Text(String(format: "%.1f", level))
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(.gray)
                        }
                }

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

                if let picked {
                    RuleMark(x: .value("t", picked.date))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .foregroundStyle(.white.opacity(0.6))
                    PointMark(x: .value("t", picked.date), y: .value("mmol", picked.mmol))
                        .symbolSize(50)
                        .foregroundStyle(.white)
                }
            }
            .chartXScale(domain: start...end)
            .chartYScale(domain: bottom...top)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: hours <= 6 ? 1 : hours <= 12 ? 3 : 6)) { _ in
                    AxisGridLine().foregroundStyle(.gray.opacity(0.2))
                    AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)))
                        .font(.system(size: 9))
                }
            }
            // Резиновая высота: на первой странице график забирает всё, что
            // осталось под цифрой. Жёсткие 100 pt не помещались на 40–41 мм,
            // а прокрутки у страницы нет — низ графика пропадал.
            .frame(minHeight: 60, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .focusable(scrubbing)
        .focused($focused)
        .digitalCrownRotation(
            $cursor, from: 0, through: Double(max(points.count - 1, 1)), by: 1,
            sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true
        )
        .onTapGesture {
            scrubbing.toggle()
            if scrubbing {
                cursor = Double(max(points.count - 1, 0))
            }
            focused = scrubbing
        }
        // Колёсико ушло к странице (смахнули экран, система сняла фокус) —
        // курсор гаснет, чтобы не висеть на старой точке.
        .onChange(of: focused) { _, isFocused in
            if !isFocused {
                scrubbing = false
            }
        }
        #if DEBUG
        // `-scrub 0.6` ставит курсор на долю кривой — для скриншотов.
        .onAppear {
            if UserDefaults.standard.object(forKey: "scrub") != nil {
                scrubbing = true
                cursor = (UserDefaults.standard.double(forKey: "scrub") * Double(max(points.count - 1, 0))).rounded()
            }
        }
        #endif
    }

    /// «9.7 · 23:40», а рядом с записью журнала — «· Еда 53 г»: ближайшая
    /// запись в пределах десяти минут от точки.
    private func cursorLabel(_ point: Point) -> some View {
        let t = point.date.timeIntervalSince1970
        // Граммы целыми, как везде в приложении; единицы — как записаны.
        let lanes: [(entries: [[Double]], title: String, unit: String, format: String)] = [
            (now.events?.meals ?? [], "Еда", "г", "%.0f"),
            (now.events?.bolus ?? [], "Инсулин", "ед", "%g"),
        ]
        let near = lanes
            .flatMap { lane in
                lane.entries.filter { $0.count == 2 && abs($0[0] - t) <= 600 }
                    .map { (distance: abs($0[0] - t), text: "\(lane.title) \(String(format: lane.format, $0[1])) \(lane.unit)") }
            }
            .min { $0.distance < $1.distance }

        return HStack(spacing: 4) {
            Text(Glucose.mmol(point.mgdl))
                .foregroundStyle(Glucose.color(point.mgdl, now.target))
            Text(point.date, format: .dateTime.hour().minute())
                .foregroundStyle(.secondary)
            if let near {
                Text("· \(near.text)")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption2.weight(.semibold).monospacedDigit())
        .lineLimit(1)
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

    /// Вчерашняя кривая за то же окно, сдвинутая на календарные сутки вперёд
    /// по поясу часов, и разрезанная по пропускам. Сутки календарные, а не
    /// 86 400 секунд: в день перевода часов они длятся 23 или 25 часов, и
    /// ровный сдвиг уводил бы линию на час. Шаг двухсуточной серии — 10
    /// минут, поэтому порог разрыва шире, чем у сегодняшней.
    private func yesterday(from start: Date, to end: Date) -> [[Point]] {
        let calendar = Calendar.current
        let points = (now.series?.twoDays?.points ?? [])
            .filter { $0.count == 2 }
            .compactMap { raw -> Point? in
                guard let shifted = calendar.date(byAdding: .day, value: 1, to: Date(timeIntervalSince1970: raw[0])),
                      shifted >= start, shifted <= end else { return nil }
                return Point(shifted.timeIntervalSince1970, raw[1])
            }

        var pieces: [[Point]] = []
        for point in points {
            // Весной вчерашних 02:xx сегодня нет, и календарь переносит их на
            // 03:xx, где уже лежат настоящие вчерашние 03:xx. Такие точки
            // идут назад или повторяют время — у Charts это дубли
            // идентификаторов, поэтому берём только строго вперёд.
            if let last = pieces.last?.last, point.date <= last.date {
                continue
            }
            if let last = pieces.last?.last, point.date.timeIntervalSince(last.date) <= 25 * 60 {
                pieces[pieces.count - 1].append(point)
            } else {
                pieces.append([point])
            }
        }
        return pieces
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
