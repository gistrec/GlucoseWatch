import Foundation
import SwiftUI

/// Выжимка снимка, которую GlucoseStat пишет рядом с data.json. Поля и
/// единицы те же, что у страницы: глюкоза в mg/dL, время в unix-секундах.
struct Now: Codable {
    struct Collector: Codable {
        let lastSuccess: Double?
    }

    struct Target: Codable {
        let low: Double
        let mid: Double
        let high: Double
    }

    struct Latest: Codable {
        let t: Double
        let mgdl: Double
        /// mg/dL в минуту за последние четверть часа; null, если точек мало.
        let rate: Double?
    }

    struct Forecast: Codable {
        let madeAt: Double
        let points: [[Double]]
        /// Нижняя граница: в девяти случаях из десяти сахар не уйдёт ниже.
        let lower: [[Double]]?
    }

    struct Dose: Codable {
        let left: Double
        let of: Double
        let until: Double
    }

    struct Active: Codable {
        let insulin: Dose?
        let carbs: Dose?
    }

    struct Points: Codable {
        let step: Double
        /// Пары [unix-секунды, mg/dL], усреднённые по шагу; пропуск сенсора —
        /// просто нет точек.
        let points: [[Double]]
    }

    struct Series: Codable {
        let day: Points
    }

    /// Сводка от местной полуночи — тот же подсчёт, что у карточек страницы:
    /// по сырым замерам, с весом по времени. Проценты, покрытие в секундах.
    struct Today: Codable {
        let covered: Double
        let tir: Double
        let below: Double
    }

    struct Sensor: Codable {
        let started: Double?
        let ends: Double?
    }

    /// Журнал бота: еда в граммах, болюс и базальный в единицах.
    struct Events: Codable {
        let meals: [[Double]]
        let bolus: [[Double]]
    }

    let generatedAt: Double
    let collector: Collector
    let target: Target
    let latest: Latest?
    let forecast: Forecast?
    let active: Active
    // Опциональны: старая выжимка их не несёт, и часы не должны из-за этого
    // остаться без цифры.
    let series: Series?
    let events: Events?
    let sensor: Sensor?
    let today: Today?
}

enum Feed {
    static let url = URL(string: "https://glucose.gistrec.cloud/now.json")!
    private static let cacheKey = "now.json"

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    /// Свежая выжимка с сервера. Удачный ответ запоминается: без сети часы
    /// покажут последнее известное значение с его возрастом, а не пустоту.
    static func load() async throws -> Now {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        let now = try decoder.decode(Now.self, from: data)
        UserDefaults.standard.set(data, forKey: cacheKey)
        return now
    }

    static var cached: Now? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? decoder.decode(Now.self, from: data)
    }

    /// Сеть, а при ошибке — последнее сохранённое.
    static func loadOrCached() async -> Now? {
        (try? await load()) ?? cached
    }
}

enum Glucose {
    static let mgdlPerMmol = 18.0

    /// Старше этого замер уже не «текущий»: Libre отдаёт точку раз в минуту,
    /// сборщик опрашивает раз в пять, так что четверть часа — это сбой.
    static let staleAfter: TimeInterval = 15 * 60

    /// Горизонт предупреждения о падении — тот же, что у страницы.
    static let fallMinutes = 30.0

    static func mmol(_ mgdl: Double) -> String {
        String(format: "%.1f", mgdl / mgdlPerMmol)
    }

    /// «45 мин», «2 ч 5 мин», «1 д 3 ч» — коротко, без секунд.
    static func ago(_ moment: Date, at date: Date) -> String {
        let minutes = max(Int(date.timeIntervalSince(moment) / 60), 0)
        if minutes < 60 { return "\(minutes) мин" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours) ч" : "\(hours) ч \(minutes % 60) мин" }
        return "\(hours / 24) д \(hours % 24) ч"
    }

    /// «45м», «1ч 44м», «10ч», «2д». Под кольцом 44 pt: «1ч 55м» занимает
    /// 45, а «10ч 55м» уже 54 и отъедает ширину у цифры глюкозы, поэтому
    /// с десяти часов минуты не пишутся — в такой давности они не важны.
    static func short(_ moment: Date, at date: Date) -> String {
        let minutes = max(Int(date.timeIntervalSince(moment) / 60), 0)
        if minutes < 60 { return "\(minutes)м" }
        let hours = minutes / 60
        if hours < 10 { return "\(hours)ч \(minutes % 60)м" }
        return hours < 24 ? "\(hours)ч" : "\(hours / 24)д"
    }

    /// Пороги стрелки как на странице (format.js, trendArrow).
    static func arrow(_ rate: Double?) -> String {
        guard let rate else { return "" }
        if rate >= 2 { return "↑" }
        if rate >= 1 { return "↗" }
        if rate > -1 { return "→" }
        if rate > -2 { return "↘" }
        return "↓"
    }

    /// Цвета зон для линии. Градиент кладётся на рамку линии, а не на весь
    /// график, поэтому пороги пересчитываются в доли от её собственного
    /// минимума и максимума; пары одинаковых позиций дают резкую смену
    /// цвета, а не перелив.
    static func zones(_ values: [Double], _ target: Now.Target) -> LinearGradient {
        let lowest = values.min() ?? 0
        let highest = values.max() ?? 0
        guard highest > lowest else {
            return LinearGradient(colors: [color(lowest, target)], startPoint: .bottom, endPoint: .top)
        }

        func at(_ mgdl: Double) -> Double { min(max((mgdl - lowest) / (highest - lowest), 0), 1) }

        let bands: [(from: Double, to: Double, color: Color)] = [
            (-.infinity, target.low, .red),
            (target.low, target.mid, .green),
            (target.mid, target.high, .yellow),
            (target.high, .infinity, .orange),
        ]
        let stops = bands.flatMap { band -> [Gradient.Stop] in
            let from = at(band.from), to = at(band.to)
            return to > from ? [.init(color: band.color, location: from), .init(color: band.color, location: to)] : []
        }
        return LinearGradient(stops: stops, startPoint: .bottom, endPoint: .top)
    }

    /// Зоны как на графике: ниже диапазона, «зелёная» до верха нормы
    /// натощак, «жёлтая» до верхнего порога, выше — красная.
    static func color(_ mgdl: Double, _ target: Now.Target) -> Color {
        if mgdl < target.low { return .red }
        if mgdl <= target.mid { return .green }
        if mgdl <= target.high { return .yellow }
        return .orange
    }
}

extension Now {
    var latestDate: Date? {
        latest.map { Date(timeIntervalSince1970: $0.t) }
    }

    func isStale(at date: Date) -> Bool {
        guard let latest else { return true }
        return date.timeIntervalSince1970 - latest.t > Glucose.staleAfter
    }

    /// Точка модельного прогноза через ``minutes`` от его расчёта, если она
    /// ещё впереди последнего замера.
    func forecast(minutes: Double) -> Double? {
        guard let forecast, let latest else { return nil }
        let at = forecast.madeAt + minutes * 60
        guard at > latest.t else { return nil }
        return forecast.points.first { $0.first == at }?.last
    }

    /// Куда может упасть сахар за полчаса, если это ниже порога. Логика
    /// страницы (chart.js, fallTail): нижняя граница прогноза, без неё —
    /// прямая по скорости; молчит, когда модель и сама ведёт под порог.
    var fallRisk: Double? {
        guard let latest else { return nil }
        if let model = forecast?.points, model.contains(where: { ($0.last ?? .infinity) <= target.low }) {
            return nil
        }

        var warning: Double?
        if let forecast, let lower = forecast.lower {
            let at = forecast.madeAt + Glucose.fallMinutes * 60
            if at > latest.t, let point = lower.first(where: { $0.first == at }) {
                warning = point.last
            }
        }
        if warning == nil, let rate = latest.rate, rate < 0 {
            warning = latest.mgdl + rate * Glucose.fallMinutes
        }

        guard let warning, warning <= target.low else { return nil }
        return max(warning, 40)
    }

    /// Сводка за сегодня, если данных набралось хотя бы на полчаса: сразу
    /// после полуночи процент от трёх замеров — шум, а не число.
    var todayStats: Today? {
        guard let today, today.covered >= 30 * 60 else { return nil }
        return today
    }

    /// Сколько осталось сенсору; nil, если срок неизвестен.
    func sensorLeft(at date: Date) -> TimeInterval? {
        guard let ends = sensor?.ends else { return nil }
        return ends - date.timeIntervalSince1970
    }

    /// Последняя запись журнала до ``date``: когда и сколько.
    func last(_ lane: [[Double]]?, before date: Date) -> (date: Date, amount: Double)? {
        guard let entry = (lane ?? []).last(where: { $0.count == 2 && $0[0] <= date.timeIntervalSince1970 }) else {
            return nil
        }
        return (Date(timeIntervalSince1970: entry[0]), entry[1])
    }

    /// Активная доза на момент ``date``. Остаток в выжимке посчитан на её
    /// сборку, а циферблат обновляется реже; между обновлениями он убывает
    /// линейно до конца действия — грубо, но лучше застывшей цифры.
    func live(_ dose: Dose?, at date: Date) -> Dose? {
        guard let dose, dose.until > generatedAt else { return nil }
        let share = (dose.until - date.timeIntervalSince1970) / (dose.until - generatedAt)
        let left = dose.left * min(max(share, 0), 1)
        guard left >= 0.05 else { return nil }
        return Dose(left: left, of: dose.of, until: dose.until)
    }
}
