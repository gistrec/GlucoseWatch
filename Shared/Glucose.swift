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

    /// Пороги стрелки как на странице (format.js, trendArrow).
    static func arrow(_ rate: Double?) -> String {
        guard let rate else { return "" }
        if rate >= 2 { return "↑" }
        if rate >= 1 { return "↗" }
        if rate > -1 { return "→" }
        if rate > -2 { return "↘" }
        return "↓"
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
