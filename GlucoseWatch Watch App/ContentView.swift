import SwiftUI
import WidgetKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var now: Now? = Feed.cached
    @State private var failed = false

    var body: some View {
        ScrollView {
            TimelineView(.everyMinute) { context in
                if let now, let latest = now.latest {
                    Reading(now: now, latest: latest, date: context.date, failed: failed)
                } else {
                    VStack(spacing: 8) {
                        if failed {
                            Text("Нет связи с glucose.gistrec.cloud")
                                .multilineTextAlignment(.center)
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
        }
        // Пока экран активен — запрос раз в минуту: поднял руку при открытом
        // приложении и видишь цифру не старше минуты-двух. Смена фазы
        // перезапускает задачу: в неактивном экране и в фоне опрос стоит,
        // а возвращение сразу начинается с запроса.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            var opened = true
            while !Task.isCancelled {
                await refresh(reloadComplications: opened)
                opened = false
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// ``reloadComplications`` — при открытии: у complication свой кэш, и она
    /// может отставать, даже когда у приложения цифра та же. Дальше — только
    /// на новом замере: из приложения на переднем плане перезагрузки не
    /// тратят бюджет виджета, но без нового замера дёргать его незачем.
    private func refresh(reloadComplications: Bool) async {
        do {
            let fresh = try await Feed.load()
            // Отмена кооперативная: ответ мог прийти, когда экран уже погас
            // или задача сменилась. Такой ответ старше следующего и не должен
            // ни перезаписать его, ни перерисовать complication.
            guard !Task.isCancelled else { return }
            let changed = fresh.latest?.t != now?.latest?.t
            now = fresh
            failed = false
            if reloadComplications || changed {
                WidgetCenter.shared.reloadAllTimelines()
            }
        } catch {
            // Отмена — экран ушёл в неактивный, а не сеть пропала.
            if !Task.isCancelled {
                failed = true
            }
        }
    }
}

private struct Reading: View {
    let now: Now
    let latest: Now.Latest
    let date: Date
    let failed: Bool

    var body: some View {
        let stale = now.isStale(at: date)
        let minutes = Int((date.timeIntervalSince1970 - latest.t) / 60)

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(Glucose.mmol(latest.mgdl))
                    .font(.system(size: 48, weight: .semibold, design: .rounded))
                Text(stale ? "" : Glucose.arrow(latest.rate))
                    .font(.title2)
            }
            .foregroundStyle(stale ? .gray : Glucose.color(latest.mgdl, now.target))

            Text(age(minutes) + (failed ? " · нет связи" : ""))
                .font(.footnote)
                .foregroundStyle(stale || failed ? .orange : .secondary)

            GlucoseChart(now: now, date: date)

            if !stale {
                if let fall = now.fallRisk {
                    Label("Может упасть до \(Glucose.mmol(fall)) за полчаса", systemImage: "arrow.down")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if let in30 = now.forecast(minutes: 30) {
                    Divider()
                    Row(title: "Через 30 мин", value: Glucose.mmol(in30))
                    if let in60 = now.forecast(minutes: 60) {
                        Row(title: "Через час", value: Glucose.mmol(in60))
                    }
                }
            }

            let insulin = now.live(now.active.insulin, at: date)
            let carbs = now.live(now.active.carbs, at: date)
            if insulin != nil || carbs != nil {
                Divider()
                if let insulin {
                    Row(title: "Инсулин", value: String(format: "%.1f из %.0f ед", insulin.left, insulin.of))
                }
                if let carbs {
                    Row(title: "Углеводы", value: String(format: "%.0f из %.0f г", carbs.left, carbs.of))
                }
            }

            day

            ReloadSummary(date: date)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var day: some View {
        let today = now.todayStats
        let sensor = now.sensorLeft(at: date)
        if today != nil || sensor != nil {
            Divider()
            if let today {
                Row(title: "Сегодня в диапазоне", value: String(format: "%.0f%%", today.tir))
                if today.below >= 0.5 {
                    Row(title: "Ниже диапазона", value: String(format: "%.0f%%", today.below))
                }
            }
            if let sensor {
                Row(title: "Сенсор", value: sensor > 0 ? Glucose.ago(date.addingTimeInterval(-sensor), at: date) : "истёк")
                    .foregroundStyle(sensor < 24 * 3600 ? .orange : .primary)
            }
        }
    }

    private func age(_ minutes: Int) -> String {
        minutes < 1 ? "только что" : "\(minutes) мин назад"
    }
}

/// Как часто система будит complication: по каждому виджету число
/// пробуждений за сутки и медианный интервал, ниже последние пробуждения
/// с возрастом замера, который они показали.
private struct ReloadSummary: View {
    let date: Date

    private static let names = [
        "GlucoseComplication": "Глюкоза",
        "ChartComplication": "График",
        "InsulinComplication": "Инсулин",
        "CarbsComplication": "Углеводы",
    ]

    var body: some View {
        let since = date.addingTimeInterval(-24 * 3600)
        let records = ReloadLog.records
        let day = records.filter { $0.at >= since.timeIntervalSince1970 }
        let kinds = Self.names.keys.sorted().filter { kind in day.contains { $0.kind == kind } }

        if !records.isEmpty {
            Divider()
            Text("Обновления циферблата")
                .font(.footnote.weight(.semibold))
            ForEach(kinds, id: \.self) { kind in
                let count = day.filter { $0.kind == kind }.count
                let median = ReloadLog.medianInterval(kind: kind, since: since)
                Row(title: Self.names[kind] ?? kind,
                    value: "\(count) за сутки" + (median.map { String(format: " · ~%.0f мин", $0) } ?? ""))
            }
            ForEach(Array(records.suffix(8).reversed().enumerated()), id: \.offset) { _, record in
                let at = Date(timeIntervalSince1970: record.at)
                let reading = record.reading.map { Glucose.short(Date(timeIntervalSince1970: $0), at: at) } ?? "—"
                HStack {
                    Text(at, format: .dateTime.hour().minute())
                    Text(Self.names[record.kind] ?? record.kind)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(record.fetched ? "замер \(reading)" : "нет сети")
                        .foregroundStyle(record.fetched ? Color.secondary : Color.orange)
                }
                .font(.caption2)
            }
        }
    }
}

private struct Row: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.footnote)
    }
}

#Preview {
    ContentView()
}
