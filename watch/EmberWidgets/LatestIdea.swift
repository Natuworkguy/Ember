import SwiftUI
import WidgetKit

/// The Smart Stack widget: your latest idea, how syncing stands, and a
/// tap to say the next one.
struct LatestIdeaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LatestIdea", provider: GlanceProvider()) { entry in
            LatestIdeaView(glance: entry.glance)
                .containerBackground(for: .widget) {
                    LinearGradient(
                        colors: [Color(red: 0.32, green: 0.12, blue: 0.04), Color(red: 0.12, green: 0.05, blue: 0.02)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                .widgetURL(URL(string: "ember://capture"))
        }
        .configurationDisplayName("Latest idea")
        .description("Your newest idea, and whether everything has synced. Tap to say another.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct GlanceEntry: TimelineEntry {
    let date: Date
    /// Nil when the app can't share it (no app group): the widget is
    /// then just a way in.
    let glance: Glance?
}

struct GlanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlanceEntry {
        GlanceEntry(date: .now, glance: Glance(
            latest: "Grappling hook that swings off any surface", latestAt: .now,
            waiting: 0, today: 3, lastSynced: .now, paired: true))
    }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : GlanceEntry(date: .now, glance: Glance.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        // The app asks for a new one whenever an idea is saved or synced;
        // the hour is only so a new day starts at zero.
        let entry = GlanceEntry(date: .now, glance: Glance.read())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(3600))))
    }
}

struct LatestIdeaView: View {
    let glance: Glance?
    private let ember = Color(red: 1.0, green: 0.48, blue: 0.18)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(ember)
                    .widgetAccentable()
                Text("Ember")
                    .font(.headline)
                    .widgetAccentable()
                Spacer(minLength: 4)
                status
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let glance, let latest = glance.latest {
                Text(latest)
                    .font(.caption)
                    .lineLimit(2)
                if let at = glance.latestAt {
                    Text(at, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Tap and say an idea.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var status: some View {
        if let glance {
            if !glance.paired {
                Text("Not paired")
            } else if glance.waiting > 0 {
                Label("\(glance.waiting)", systemImage: "clock")
            } else if glance.today > 0 {
                Text("\(glance.today) today")
            } else {
                Image(systemName: "checkmark")
            }
        }
    }
}
