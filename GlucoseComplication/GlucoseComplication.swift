import SwiftUI
import WidgetKit

struct Entry: TimelineEntry {
    let date: Date
    let now: Now?

    /// Вес для Smart Stack: система поднимает виджет наверх стопки, когда
    /// он важнее остальных. Риск гипо и низкий сахар — главное, высокий —
    /// заметно, ровный день — фон. Старая цифра поводом не считается.
    var relevance: TimelineEntryRelevance? {
        guard let now, let latest = now.latest, !now.isStale(at: date) else {
            return TimelineEntryRelevance(score: 0)
        }
        if latest.mgdl < now.target.low || now.fallRisk != nil {
            return TimelineEntryRelevance(score: 100, duration: 15 * 60)
        }
        if latest.mgdl > now.target.high {
            return TimelineEntryRelevance(score: 50, duration: 15 * 60)
        }
        return TimelineEntryRelevance(score: 5)
    }
}

struct Provider: TimelineProvider {
    /// Какой виджет спрашивает — для журнала пробуждений.
    let kind: String

    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, now: Feed.cached)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        Task {
            completion(Entry(date: .now, now: await Feed.loadOrCached()))
        }
    }

    /// Обновления раздаёт система — несколько десятков в сутки, а не каждые
    /// пять минут. Просим следующее к ожидаемому замеру, а до него записи
    /// идут каждые пять минут: на них досчитываются остатки инсулина и
    /// углеводов и давность журнала, а запись на пятнадцатой минуте гасит цифру, если обновления
    /// так и не было, — старая цифра на циферблате опаснее, чем серая.
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        Task {
            let fresh = try? await Feed.load()
            let now = fresh ?? Feed.cached
            ReloadLog.record(kind: kind, fetched: fresh != nil, reading: now?.latest?.t)
            let start = Date.now
            var dates = (0...12).map { start.addingTimeInterval(Double($0) * 5 * 60) }
            var next = start.addingTimeInterval(5 * 60)

            if let latest = now?.latest {
                let stale = Date(timeIntervalSince1970: latest.t + Glucose.staleAfter)
                if stale > start {
                    dates.append(stale)
                }
                next = max(next, Date(timeIntervalSince1970: latest.t + 5 * 60 + 30))
            }

            let entries = dates.sorted().map { Entry(date: $0, now: now) }
            completion(Timeline(entries: entries, policy: .after(next)))
        }
    }
}

struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        if let now = entry.now, let latest = now.latest {
            let stale = now.isStale(at: entry.date)
            let value = Glucose.mmol(latest.mgdl)
            let arrow = stale ? "" : Glucose.arrow(latest.rate)
            let color = stale ? Color.gray : Glucose.color(latest.mgdl, now.target)
            let since = Date(timeIntervalSince1970: latest.t)

            switch family {
            case .accessoryCircular:
                VStack(spacing: 0) {
                    Text(value)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .minimumScaleFactor(0.6)
                    Text(arrow)
                        .font(.caption)
                }
                .foregroundStyle(color)
                .widgetAccentable()

            case .accessoryCorner:
                Text("\(value)\(arrow)")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(color)
                    .widgetLabel {
                        Text(stale ? Glucose.ago(since, at: entry.date) : "")
                    }

            case .accessoryInline:
                Text(stale ? "\(value) · \(Glucose.ago(since, at: entry.date))" : "\(value) \(arrow)")

            default:
                Rectangular(now: now, latest: latest, stale: stale, value: value, arrow: arrow, color: color, since: since, date: entry.date)
            }
        } else {
            Text("—")
                .foregroundStyle(.gray)
        }
    }
}

private struct Rectangular: View {
    let now: Now
    let latest: Now.Latest
    let stale: Bool
    let value: String
    let arrow: String
    let color: Color
    let since: Date
    let date: Date

    /// Цифра со стрелкой слева, под ней прогноз на 30 минут; справа кольца
    /// остатков инсулина и еды, под каждым — давность последней записи.
    /// Инсулин и еду различают цвета колец, так что единицы не подписаны.
    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(arrow)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                }
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .widgetAccentable()

                if stale {
                    Age(since: since, stale: stale, date: date)
                } else {
                    forecast
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            Ring(dose: now.live(now.active.insulin, at: date), last: now.last(now.events?.bolus, before: date),
                 tint: .cyan, format: "%.1f", date: date)
            Ring(dose: now.live(now.active.carbs, at: date), last: now.last(now.events?.meals, before: date),
                 tint: .orange, format: "%.0f", date: date)
        }
    }

    /// «4.7 → 4.4» — прогноз модели через полчаса и через час. Подписи
    /// «30′ … 60′» не влезают (94 pt при ~70 свободных), стрелка читается
    /// как «потом». При риске гипо — красная нижняя граница «30′ ↓3.8»:
    /// её проверяли только на получасе, на часе ложных тревог втрое больше.
    private var forecast: some View {
        let fall = now.fallRisk
        let in30 = now.forecast(minutes: 30).map(Glucose.mmol)
        let in60 = now.forecast(minutes: 60).map(Glucose.mmol)
        let text = fall.map { "30′ ↓\(Glucose.mmol($0))" }
            ?? in30.map { first in in60.map { "\(first) → \($0)" } ?? first }
            ?? "прогноза нет"
        return Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(fall == nil ? Color.secondary : Color.red)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// Кольцо остатка дозы с числом внутри и давностью последней записи под ним.
/// В полный размер и с белой давностью: ужатые до 72 % читались плохо.
private struct Ring: View {
    let dose: Now.Dose?
    let last: (date: Date, amount: Double)?
    let tint: Color
    let format: String
    let date: Date

    var body: some View {
        VStack(spacing: 1) {
            Gauge(value: dose?.left ?? 0, in: 0...max(dose?.of ?? 1, dose?.left ?? 0)) {
                EmptyView()
            } currentValueLabel: {
                Text(dose.map { String(format: format, $0.left) } ?? "—")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.7)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tint)
            .frame(width: 44, height: 44)

            Text(last.map { Glucose.short($0.date, at: date) } ?? "—")
                .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// Давность замера — только когда цифра посерела. Пока данные свежие,
/// тикающий таймер на циферблате лишь отвлекает: свежесть и так видна по
/// цвету. Коротко («15м», «1ч 5м») и всегда в одну строку: с жёсткой
/// шириной «15 мин» обрезалось до «15...» и переносилось на две строки.
private struct Age: View {
    let since: Date
    let stale: Bool
    let date: Date

    var body: some View {
        if stale {
            Text(Glucose.short(since, at: date))
                .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.orange)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

struct GlucoseComplication: Widget {
    let kind = "GlucoseComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider(kind: kind)) { entry in
            ComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Глюкоза")
        .description("Сахар, тренд и когда были последние инсулин и еда.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

/// Кривая последних шести часов с порогами и прогнозом на весь слот.
struct ChartComplication: Widget {
    let kind = "ChartComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider(kind: kind)) { entry in
            ChartComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("График")
        .description("Кривая за шесть часов с порогами и прогнозом.")
        .supportedFamilies([.accessoryRectangular])
    }
}

/// Та же кривая, а под ней «обычный день» за две недели: видно, обычный ли
/// сейчас подъём для этого времени суток. Отдельной complication, чтобы
/// выбирать в редакторе циферблата, а не настройкой в приложении.
struct ChartUsualComplication: Widget {
    let kind = "ChartUsualComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider(kind: kind)) { entry in
            ChartComplicationView(entry: entry, usual: true)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("График и обычный день")
        .description("Кривая за шесть часов, а под ней коридор и медиана за две недели.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct ChartComplicationView: View {
    let entry: Entry
    var usual = false

    var body: some View {
        if let now = entry.now, let latest = now.latest {
            let stale = now.isStale(at: entry.date)

            // Цифра живёт в верхнем слоте, здесь весь слот под кривую. Остаётся
            // только давность, когда данные устарели: иначе старый график не
            // отличить от свежего.
            Sparkline(now: now, date: entry.date, usual: usual)
                .overlay(alignment: .topTrailing) {
                    Age(since: Date(timeIntervalSince1970: latest.t), stale: stale, date: entry.date)
                        .padding(.horizontal, 3)
                        .background(.black, in: RoundedRectangle(cornerRadius: 4))
                }
        } else {
            Text("—")
                .foregroundStyle(.gray)
        }
    }
}

enum DoseKind: String {
    case insulin = "InsulinComplication"
    case carbs = "CarbsComplication"
}

/// Сколько осталось от активной дозы — кольцом, как заряд батареи. Widget
/// создаётся без аргументов, поэтому вид дозы — отдельным типом на каждую.
private func doseConfiguration(_ kind: DoseKind) -> some WidgetConfiguration {
    StaticConfiguration(kind: kind.rawValue, provider: Provider(kind: kind.rawValue)) { entry in
        DoseView(entry: entry, kind: kind)
            .containerBackground(.fill.tertiary, for: .widget)
    }
    .configurationDisplayName(kind == .insulin ? "Инсулин" : "Углеводы")
    .description(kind == .insulin ? "Сколько болюсного инсулина ещё действует." : "Сколько углеводов ещё всасывается.")
    .supportedFamilies([.accessoryCircular, .accessoryCorner])
}

struct InsulinComplication: Widget {
    var body: some WidgetConfiguration { doseConfiguration(.insulin) }
}

struct CarbsComplication: Widget {
    var body: some WidgetConfiguration { doseConfiguration(.carbs) }
}

struct DoseView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry
    let kind: DoseKind

    var body: some View {
        let active = entry.now?.active
        let dose = entry.now?.live(kind == .insulin ? active?.insulin : active?.carbs, at: entry.date)
        let left = dose?.left ?? 0
        let of = max(dose?.of ?? 1, left)
        let value = kind == .insulin ? String(format: "%.1f", left) : String(format: "%.0f", left)
        let unit = kind == .insulin ? "ед" : "г"
        let tint: Color = kind == .insulin ? .cyan : .orange

        switch family {
        case .accessoryCorner:
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(tint)
                .widgetLabel {
                    Gauge(value: left, in: 0...of) {
                        Text(unit)
                    }
                    .tint(tint)
                }
        default:
            Gauge(value: left, in: 0...of) {
                Text(unit)
            } currentValueLabel: {
                Text(value)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tint)
            .widgetAccentable()
        }
    }
}

private let sample = Now(
    generatedAt: Date.now.timeIntervalSince1970,
    collector: .init(lastSuccess: Date.now.timeIntervalSince1970),
    target: .init(low: 70, mid: 130, high: 180),
    latest: .init(t: Date.now.timeIntervalSince1970 - 120, mgdl: 135, rate: 1.3),
    forecast: .init(
        madeAt: Date.now.timeIntervalSince1970 - 300,
        points: [[Date.now.timeIntervalSince1970 + 1500, 135], [Date.now.timeIntervalSince1970 + 3300, 125]],
        lower: [[Date.now.timeIntervalSince1970 + 1500, 104], [Date.now.timeIntervalSince1970 + 3300, 89]]
    ),
    active: .init(
        insulin: .init(left: 0.3, of: 6, until: Date.now.timeIntervalSince1970 + 3600),
        carbs: .init(left: 11, of: 68, until: Date.now.timeIntervalSince1970 + 3600)
    ),
    series: nil,
    events: nil,
    sensor: nil,
    today: nil,
    profile: nil,
    nights: nil,
    analysis: nil
)

#Preview(as: .accessoryRectangular) {
    GlucoseComplication()
} timeline: {
    Entry(date: .now, now: sample)
}

#Preview(as: .accessoryCircular) {
    GlucoseComplication()
} timeline: {
    Entry(date: .now, now: sample)
}

#Preview(as: .accessoryRectangular) {
    ChartComplication()
} timeline: {
    Entry(date: .now, now: sample)
}

#Preview(as: .accessoryCircular) {
    InsulinComplication()
} timeline: {
    Entry(date: .now, now: sample)
}
