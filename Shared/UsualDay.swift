import Foundation

/// Слот «обычного дня» на окне графика, в ммоль/л.
struct UsualSlot: Identifiable {
    let date: Date
    let low: Double
    let median: Double
    let high: Double
    /// Номер непрерывного куска: через пустой слот Charts тянули бы
    /// коридор, которого нет, поэтому каждый кусок — своя серия.
    let run: Int
    var id: Date { date }
}

extension Now {
    /// Профиль «обычного дня», разложенный на окно графика: каждый слот
    /// времени суток ставится на дату окна (оно может заходить во вчера) по
    /// поясу профиля, в середину слота. Время берётся по циферблату, а не
    /// минутами от полуночи: в день перевода часов отсчёт минутами сдвигал
    /// бы слоты на час. Слот, которого в этот день нет, и пустой слот
    /// пропускаются и рвут полосу.
    func usualDay(from start: Date, to end: Date) -> [UsualSlot] {
        guard let profile = profile, profile.slotMin > 0, !profile.slots.isEmpty,
              let zone = TimeZone(identifier: profile.tz) else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let half = TimeInterval(profile.slotMin * 30)

        var result: [UsualSlot] = []
        var run = 0
        var day = calendar.startOfDay(for: start)
        while day <= end {
            for (index, slot) in profile.slots.enumerated() {
                let minutes = index * profile.slotMin
                guard let slot, slot.count >= 3,
                      let slotStart = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day),
                      calendar.component(.hour, from: slotStart) == minutes / 60,
                      calendar.component(.minute, from: slotStart) == minutes % 60
                else {
                    run += 1
                    continue
                }
                let middle = slotStart.addingTimeInterval(half)
                guard middle >= start, middle <= end else { continue }
                // Страховка от повтора времени на осеннем переводе: Charts
                // нужны уникальные и возрастающие x.
                if let last = result.last, middle <= last.date { continue }
                result.append(UsualSlot(
                    date: middle,
                    low: slot[0] / Glucose.mgdlPerMmol,
                    median: slot[1] / Glucose.mgdlPerMmol,
                    high: slot[2] / Glucose.mgdlPerMmol,
                    run: run
                ))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }
}
