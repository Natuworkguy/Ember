import SwiftUI
import WidgetKit

/// The complications, tap one to say an idea or record one, and the
/// Smart Stack widget with your latest idea.
@main
struct EmberWidgets: WidgetBundle {
    var body: some Widget {
        LatestIdeaWidget()
        NewIdeaComplication()
        RecordIdeaComplication()
    }
}

struct Moment: TimelineEntry {
    let date: Date
}

/// Nothing on them changes, so there is one entry, for good.
struct Still: TimelineProvider {
    func placeholder(in context: Context) -> Moment { Moment(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (Moment) -> Void) {
        completion(Moment(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Moment>) -> Void) {
        completion(Timeline(entries: [Moment(date: .now)], policy: .never))
    }
}

private let ember = Color(red: 1.0, green: 0.42, blue: 0.13)

struct ComplicationFace: View {
    @Environment(\.widgetFamily) private var family
    let symbol: String
    let title: String
    let line: String

    var body: some View {
        switch family {
        case .accessoryCorner:
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(ember)
                .widgetLabel { Text(title) }
        case .accessoryInline:
            Label(title, systemImage: symbol)
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(ember)
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 0) {
                    Text("Ember")
                        .font(.headline)
                        .widgetAccentable()
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(ember)
                    .widgetAccentable()
            }
        }
    }
}

struct NewIdeaComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NewIdea", provider: Still()) { _ in
            ComplicationFace(symbol: "flame.fill", title: "New idea", line: "Tap and say an idea")
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "ember://capture"))
        }
        .configurationDisplayName("New idea")
        .description("Tap to say an idea to Ember.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

struct RecordIdeaComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RecordIdea", provider: Still()) { _ in
            ComplicationFace(symbol: "waveform", title: "Record idea", line: "Tap and talk")
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "ember://record"))
        }
        .configurationDisplayName("Record idea")
        .description("Tap to record an idea; your server finds the words.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular])
    }
}
