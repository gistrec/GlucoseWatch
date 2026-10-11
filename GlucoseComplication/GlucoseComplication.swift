import SwiftUI
import WidgetKit

struct Entry: TimelineEntry {
    let date: Date
    let now: Now?
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
    /// пять минут. Просим следующее к ожидаемому замеру, а вторая запись
    /// гасит значение, если до тех пор обновления так и не будет: старая
    /// цифра на циферблате опаснее, чем серая.
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        Task {
            let now = await Feed.loadOrCached()
            var entries = [Entry(date: .now, now: now)]
            var next = Date.now.addingTimeInterval(5 * 60)

            if let latest = now?.latest {
                let stale = Date(timeIntervalSince1970: latest.t + Glucose.staleAfter)
                if stale > .now {
                    entries.append(Entry(date: stale, now: now))
                }
                next = max(next, Date(timeIntervalSince1970: latest.t + 5 * 60 + 30))
            }

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
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(value) \(arrow)")
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .foregroundStyle(color)
                    .widgetAccentable()
                Spacer(minLength: 0)
                Text(since, style: .timer)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            if !stale, let fall = now.fallRisk {
                Text("↓ может упасть до \(Glucose.mmol(fall))")
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else if !stale, let in30 = now.forecast(minutes: 30) {
                let in60 = now.forecast(minutes: 60).map { " · 60′ \(Glucose.mmol($0))" } ?? ""
                Text("30′ \(Glucose.mmol(in30))\(in60)")
                    .font(.caption2)
            }

            Text(activeLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var activeLine: String {
        var parts: [String] = []
        if let insulin = Now.live(now.active.insulin, at: date) {
            parts.append(String(format: "инс %.1f ед", insulin.left))
        }
        if let carbs = Now.live(now.active.carbs, at: date) {
            parts.append(String(format: "угл %.0f г", carbs.left))
        }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
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
        .description("Текущий сахар, тренд, прогноз и активные инсулин с углеводами.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryCorner, .accessoryInline])
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
    )
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
