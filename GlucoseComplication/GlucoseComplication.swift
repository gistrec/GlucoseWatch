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
            let now = await Feed.loadOrCached()
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
                        Text(since, style: .timer)
                    }

            case .accessoryInline:
                Text("\(value) \(arrow) · ") + Text(since, style: .timer)

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(value) \(arrow)")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .widgetAccentable()
                Spacer(minLength: 0)
                Age(since: since)
            }

            if !stale, let fall = now.fallRisk {
                Text("↓ до \(Glucose.mmol(fall)) за 30 мин")
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else {
                journal(now.last(now.events?.bolus, before: date), title: "Инсулин", unit: "ед", format: "%g")
            }

            journal(now.last(now.events?.meals, before: date), title: "Еда", unit: "г", format: "%.0f")
        }
    }

    /// «Инсулин 6 ед · 2 ч 5 мин»: сколько и как давно. Давность — своя, по
    /// записи таймлайна: системная .relative под час тикает секундами.
    @ViewBuilder
    private func journal(_ entry: (date: Date, amount: Double)?, title: String, unit: String, format: String) -> some View {
        if let entry {
            Text("\(title) \(String(format: format, entry.amount)) \(unit) · \(Glucose.ago(entry.date, at: date))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text("\(title) —")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Давность замера тикающим таймером. Ширина задана явно: таймер в
/// WidgetKit забирает всю свободную ширину строки и выдавливает цифру.
private struct Age: View {
    let since: Date

    var body: some View {
        Text(since, style: .timer)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .frame(width: 36, alignment: .trailing)
    }
}

struct GlucoseComplication: Widget {
    let kind = "GlucoseComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            ComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Глюкоза")
        .description("Сахар, тренд и когда были последние инсулин и еда.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

/// Цифра со стрелкой и кривая последних трёх часов — главное, что видно на
/// странице, в одном прямоугольнике.
struct ChartComplication: Widget {
    let kind = "ChartComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            ChartComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("График")
        .description("Сахар и кривая за три часа с прогнозом.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct ChartComplicationView: View {
    let entry: Entry

    var body: some View {
        if let now = entry.now, let latest = now.latest {
            let stale = now.isStale(at: entry.date)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(Glucose.mmol(latest.mgdl))
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundStyle(stale ? .gray : Glucose.color(latest.mgdl, now.target))
                        .widgetAccentable()
                    Text(stale ? "" : Glucose.arrow(latest.rate))
                        .font(.caption)
                    Spacer(minLength: 0)
                    Age(since: Date(timeIntervalSince1970: latest.t))
                }
                Sparkline(now: now, date: entry.date)
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
    StaticConfiguration(kind: kind.rawValue, provider: Provider()) { entry in
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
    today: nil
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
