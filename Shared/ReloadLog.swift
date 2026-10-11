import Foundation

/// Журнал пробуждений complication: когда система её разбудила, какой
/// виджет, дошёл ли запрос до сервера и сколько было замеру. Нужен, чтобы
/// узнать реальную частоту обновлений — Apple её не называет. Пишет
/// расширение, читает приложение, поэтому лежит в общей группе.
enum ReloadLog {
    struct Record: Codable {
        let at: Double
        let kind: String
        let fetched: Bool
        /// Время замера, который виджет показал после пробуждения.
        let reading: Double?
    }

    private static let group = "group.cloud.gistrec.GlucoseWatch"
    private static let key = "reloads"
    /// Четыре виджета за сутки — сотни записей; хватит, чтобы увидеть день.
    private static let limit = 600

    private static var defaults: UserDefaults? { UserDefaults(suiteName: group) }

    static func record(kind: String, fetched: Bool, reading: Double?) {
        guard let defaults else { return }
        var all = records
        all.append(Record(at: Date.now.timeIntervalSince1970, kind: kind, fetched: fetched, reading: reading))
        if all.count > limit { all.removeFirst(all.count - limit) }
        defaults.set(try? JSONEncoder().encode(all), forKey: key)
    }

    static var records: [Record] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    /// Медиана промежутков между пробуждениями одного виджета за сутки, в
    /// минутах. Медиана, а не среднее: ночная пауза в два часа не должна
    /// перекрашивать обычный день.
    static func medianInterval(kind: String, since: Date) -> Double? {
        let times = records.filter { $0.kind == kind && $0.at >= since.timeIntervalSince1970 }.map(\.at)
        let gaps = zip(times.dropFirst(), times).map { ($0 - $1) / 60 }.sorted()
        guard !gaps.isEmpty else { return nil }
        let middle = gaps.count / 2
        return gaps.count % 2 == 1 ? gaps[middle] : (gaps[middle - 1] + gaps[middle]) / 2
    }
}
