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

            // Сенсор расходится с глюкометром, и в проверенном сверками
            // диапазоне это расхождение известно: показываем, сколько было бы
            // по крови. Оценка, а не замер — так и подписана; «22/24» — сколько
            // сверок из всех согласны со смещением.
            if !stale, let blood = now.bloodEstimate(latest.mgdl), let bias = now.sensor?.bias {
                Text("≈ \(Glucose.mmol(blood)) по крови · \(Int(bias.agree))/\(Int(bias.pairs))")
                    .lineLimit(1)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

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

                if let analysis = now.analysis, let meal = analysis.meals.last {
                    LastMeal(meal: meal, targets: analysis.targets, date: date)
                }
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
                if let nights = now.nights, let night = nights.nights.last {
                    NightSummary(nights: nights, night: night, date: date)
                    Divider()
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

/// Как отработала последняя еда — разбор сервера за 4 часа от неё: подъём
/// до пика и где сахар к концу окна. Подъём выше ориентира — оранжевым,
/// провал после пика — красной строкой.
private struct LastMeal: View {
    let meal: Now.Analysis.Meal
    let targets: Now.Analysis.Targets
    let date: Date

    var body: some View {
        Divider()
        HStack {
            Text(title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Text(Glucose.short(Date(timeIntervalSince1970: meal.t), at: date))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        // Из гипо подъём выше ориентира — лечение, а не перебор: не красим.
        Row(title: meal.fromHypo == true ? "Подъём из гипо" : "Подъём", value: rise,
            valueColor: meal.fromHypo != true && meal.rise > targets.rise ? .orange : nil)
        Row(title: "Через 4 ч", value: outcome)
        if meal.hypo {
            Text("Ниже диапазона после пика")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    /// «Еда 53 г · 3 ед».
    private var title: String {
        let dose = meal.dose.map { String(format: " · %g ед", $0.units) } ?? ""
        return String(format: "Еда %.0f г", meal.carbs) + dose
    }

    /// «+2.8 за 55 мин» или «нет», если сахар после еды не поднимался.
    private var rise: String {
        guard meal.rise > 0 else { return "нет" }
        return String(format: "+%.1f за %.0f мин", meal.rise / Glucose.mgdlPerMmol, meal.peakMin)
    }

    /// Где сахар к концу окна относительно исходного. Закончен ли разбор,
    /// решает сервер (``complete``); время окна лишь отличает ещё открытое
    /// окно от закрытого, где сенсору не хватило замеров.
    private var outcome: String {
        if meal.cut { return "прервано едой" }
        if meal.complete {
            // Итога нет, если в конце окна не было замера или окно обрезала
            // следующая еда при подъёме в пределах ориентира.
            return meal.ret.map { String(format: "%+.1f", $0 / Glucose.mgdlPerMmol) } ?? "нет итога"
        }
        return date.timeIntervalSince1970 < meal.t + Self.window ? "разбор идёт" : "мало данных"
    }

    /// Окно разбора сервера (analysis.WINDOW).
    private static let window: TimeInterval = 4 * 3600
}

/// Последняя ночь, 00:00–06:00 по местным часам, и итог недели — то, что
/// утром хочется знать первым.
private struct NightSummary: View {
    let nights: Now.Nights
    let night: Now.Nights.Night
    let date: Date

    /// Порог покрытия, с которого сервер засчитывает ночь (NIGHT_MIN_COVERAGE).
    private static let minCoverage = 50.0

    var body: some View {
        Divider()
        HStack {
            Text("Ночь")
                .font(.footnote.weight(.semibold))
            Spacer()
            Text(status)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if let min = night.min {
            Row(title: "Минимум", value: Glucose.mmol(min), valueColor: night.hypo == true ? .red : nil)
        }
        // Всегда: у ночи без единого замера это единственная строка, которая
        // скажет «мало данных».
        Row(title: "Ниже \(Glucose.mmol(nights.hypoMgdl))", value: below)
        if let drift = night.drift {
            Row(title: "Дрейф 03→06", value: String(format: "%+.1f", drift / Glucose.mgdlPerMmol))
        }
        if nights.counted > 0 {
            Row(title: "Ночей с гипо", value: String(format: "%.0f из %.0f", nights.hypoNights, nights.counted))
        }
    }

    /// «идёт», пока конец ночи впереди; «12.10 · неполная», если ночь
    /// обрезана (окном, пропуском или сменой пояса); иначе просто дата.
    /// Флаг неполноты сам по себе не значит «идёт»: в старом снимке он
    /// остаётся и у закончившейся ночи.
    private var status: String {
        if ongoing { return "идёт" }
        return night.partial ? "\(day) · неполная" : day
    }

    private var ongoing: Bool {
        guard let end = nights.plannedEnd(of: night) else { return false }
        return night.partial && date < end
    }

    /// «39 мин · 2 раза»; «не было» — только про целую ночь, накрытую
    /// замерами, иначе отсутствие провала ничего не доказывает.
    private var below: String {
        guard let minutes = night.lowMinutes, minutes > 0 else {
            // Покрытие идущей ночи считается по прошедшей части: «не было»
            // про всю ночь можно сказать только про целую.
            guard night.coverage >= Self.minCoverage else { return "мало данных" }
            if ongoing { return "пока не было" }
            return night.partial ? "мало данных" : "не было"
        }
        return "\(Int(minutes)) мин · \(Glucose.times(Int(night.lowCount ?? 1)))"
    }

    /// «12.10» из «2026-10-12».
    private var day: String {
        let parts = night.date.split(separator: "-")
        return parts.count == 3 ? "\(parts[2]).\(parts[1])" : night.date
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
    /// Цвет одного значения; без него строка наследует цвет от родителя
    /// (так срок сенсора красит строку оранжевым).
    var valueColor: Color?

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            if let valueColor {
                Text(value).foregroundStyle(valueColor)
            } else {
                Text(value)
            }
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
