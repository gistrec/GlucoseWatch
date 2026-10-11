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
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await refresh() }
            }
        }
    }

    private func refresh() async {
        do {
            now = try await Feed.load()
            failed = false
            // Открыл приложение — пусть и циферблат увидит свежую цифру.
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            failed = true
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func age(_ minutes: Int) -> String {
        minutes < 1 ? "только что" : "\(minutes) мин назад"
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
