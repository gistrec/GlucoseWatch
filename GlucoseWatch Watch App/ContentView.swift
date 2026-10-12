import SwiftUI
import WidgetKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var now: Now? = Feed.cached
    @State private var failed = false
    @State private var page = ContentView.firstPage

    var body: some View {
        TimelineView(.everyMinute) { context in
            #if DEBUG
            // `-complications` показывает мини-графики complication вместо
            // приложения — чтобы снять их скриншот из терминала.
            if UserDefaults.standard.bool(forKey: "complications"), let now {
                ComplicationShowcase(now: now, date: context.date)
            } else {
                screen(date: context.date)
            }
            #else
            screen(date: context.date)
            #endif
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

    @ViewBuilder
    private func screen(date: Date) -> some View {
        if let now, let latest = now.latest {
            // Страницы вместо длинной прокрутки: колёсико листает экран
            // целиком, как в системных приложениях. Сверху то, ради чего
            // поднимают руку, ниже — подробности.
            TabView(selection: $page) {
                NowPage(now: now, latest: latest, date: date, failed: failed)
                    .tag(0)
                ForecastPage(now: now, date: date)
                    .tag(1)
                DayPage(now: now, date: date)
                    .tag(2)
            }
            .tabViewStyle(.verticalPage)
        } else {
            VStack(spacing: 8) {
                if failed {
                    Text("Нет связи с glucose.gistrec.cloud")
                        .multilineTextAlignment(.center)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Первая страница. В отладочной сборке её задаёт аргумент запуска
    /// `-page N` — чтобы снять скриншот любой страницы из терминала.
    private static var firstPage: Int {
        #if DEBUG
        return UserDefaults.standard.integer(forKey: "page")
        #else
        return 0
        #endif
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

/// Страница 1: цифра, давность и график — то, ради чего поднимают руку.
private struct NowPage: View {
    let now: Now
    let latest: Now.Latest
    let date: Date
    let failed: Bool

    var body: some View {
        let stale = now.isStale(at: date)
        let minutes = Int((date.timeIntervalSince1970 - latest.t) / 60)

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(Glucose.mmol(latest.mgdl))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                Text(stale ? "" : Glucose.arrow(latest.rate))
                    .font(.title2)
            }
            .foregroundStyle(stale ? .gray : Glucose.color(latest.mgdl, now.target))

            Text(age(minutes) + (failed ? " · нет связи" : ""))
                .font(.footnote)
                .foregroundStyle(stale || failed ? .orange : .secondary)

            GlucoseChart(now: now, date: date)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func age(_ minutes: Int) -> String {
        minutes < 1 ? "только что" : "\(minutes) мин назад"
    }
}

/// Страница 2: куда идёт сахар и что ещё действует.
private struct ForecastPage: View {
    let now: Now
    let date: Date

    var body: some View {
        let stale = now.isStale(at: date)
        let insulin = now.live(now.active.insulin, at: date)
        let carbs = now.live(now.active.carbs, at: date)

        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Прогноз")
                    .font(.headline)

                if stale {
                    Text("Данные устарели — прогноза нет")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else {
                    if let fall = now.fallRisk {
                        Label("Может упасть до \(Glucose.mmol(fall)) за полчаса", systemImage: "arrow.down")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    if let in30 = now.forecast(minutes: 30) {
                        Row(title: "Через 30 мин", value: Glucose.mmol(in30))
                        if let in60 = now.forecast(minutes: 60) {
                            Row(title: "Через час", value: Glucose.mmol(in60))
                        }
                    } else {
                        Text("Модель ещё не посчитала прогноз")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()
                Row(title: "Инсулин", value: insulin.map { String(format: "%.1f из %.0f ед", $0.left, $0.of) } ?? "не действует")
                Row(title: "Углеводы", value: carbs.map { String(format: "%.0f из %.0f г", $0.left, $0.of) } ?? "не действуют")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Справа полоса прокрутки и точки страниц — без отступа они
            // ложатся поверх цифр в правой колонке.
            .padding(.trailing, 8)
        }
    }
}

/// Страница 3: как идёт день и как часто обновляется циферблат.
private struct DayPage: View {
    let now: Now
    let date: Date

    var body: some View {
        let today = now.todayStats
        let sensor = now.sensorLeft(at: date)

        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("День")
                    .font(.headline)
                if let today {
                    Row(title: "В диапазоне", value: String(format: "%.0f%%", today.tir))
                    if today.below >= 0.5 {
                        Row(title: "Ниже диапазона", value: String(format: "%.0f%%", today.below))
                    }
                } else {
                    Text("День только начался")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let sensor {
                    Row(title: "Сенсор", value: sensor > 0 ? Glucose.ago(date.addingTimeInterval(-sensor), at: date) : "истёк")
                        .foregroundStyle(sensor < 24 * 3600 ? .orange : .primary)
                }

                ReloadSummary(date: date)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Справа полоса прокрутки и точки страниц — без отступа они
            // ложатся поверх цифр в правой колонке.
            .padding(.trailing, 8)
        }
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
        "ChartUsualComplication": "График+",
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

#if DEBUG
/// Мини-графики обеих complication «График» в рамке размером со слот
/// Modular Duo на 45 мм — для скриншотов из терминала.
private struct ComplicationShowcase: View {
    let now: Now
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("График").font(.caption2).foregroundStyle(.secondary)
            Sparkline(now: now, date: date)
                .frame(width: 172, height: 64)
            Text("График и обычный день").font(.caption2).foregroundStyle(.secondary)
            Sparkline(now: now, date: date, usual: true)
                .frame(width: 172, height: 64)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
#endif

#Preview {
    ContentView()
}
