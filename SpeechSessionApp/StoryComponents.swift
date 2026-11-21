import SwiftUI

/// Shared inline status for work that interprets or generates record content.
struct StoryThinkingStatus: View {
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(_ label: String = "Thinking…") { self.label = label }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "heart.fill")
                .font(.footnote)
                .foregroundStyle(StoryDesignTokens.action)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                .accessibilityHidden(true)
            Text(label)
                .font(StoryDesignTokens.font(.subheadline, weight: .medium))
                .foregroundStyle(StoryDesignTokens.secondaryInk)
        }
        .accessibilityElement(children: .combine)
    }
}

struct StoryOnboardingCopy: View {
    var title: String? = nil
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { StorySectionHeading(title: title) }
            if let detail {
                Text(detail)
                    .font(StoryDesignTokens.body)
                    .foregroundStyle(StoryDesignTokens.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StorySpeechBubble: View {
    let text: String
    var trailingTargetWidth: CGFloat? = nil
    let symbols: [String]
    var heading: String? = nil

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            if !symbols.isEmpty {
                HStack(spacing: 14) {
                    ForEach(symbols, id: \.self) { symbol in
                        Image(systemName: symbol)
                            .font(StoryDesignTokens.font(.title, weight: .semibold))
                            .foregroundStyle(StoryDesignTokens.bubbleContent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 4)
                .accessibilityHidden(true)
            }
            if let heading {
                Text(heading)
                    .font(StoryDesignTokens.bubbleQuote.bold())
                    .foregroundStyle(StoryDesignTokens.bubbleContent)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(text)
                .font(StoryDesignTokens.bubbleQuote)
                .foregroundStyle(StoryDesignTokens.bubbleContent)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(StoryDesignTokens.bubbleFill, in: RoundedRectangle(cornerRadius: 20))
            .overlay(alignment: trailingTargetWidth == nil ? .bottom : .bottomTrailing) {
                let side: CGFloat = 16
                let height = side * CGFloat(3).squareRoot() / 2
                Path { path in
                    path.move(to: .zero)
                    path.addLine(to: CGPoint(x: side, y: 0))
                    path.addLine(to: CGPoint(x: side / 2, y: height))
                    path.closeSubpath()
                }
                .fill(StoryDesignTokens.bubbleFill)
                .frame(width: side, height: height)
                .frame(width: trailingTargetWidth)
                .offset(y: height - 1)
                .accessibilityHidden(true)
            }
            .padding(.bottom, 13)
    }
}

struct StoryActionDock: View {
    let ask: () -> Void
    let add: () -> Void
    let guideToAdd: Bool
    @State private var addButtonWidth = StoryDesignTokens.controlHeight

    var body: some View {
        VStack(spacing: 4) {
            if guideToAdd {
                StorySpeechBubble(text: "Transcribe a visit, record a voice journal, or add a photo or file. We’ll pull the key details into your health story…", trailingTargetWidth: addButtonWidth, symbols: ["note.text", "waveform", "photo", "doc"], heading: "Add your first record")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 12)
            }
            HStack(alignment: .bottom, spacing: 12) {
                Button(action: ask) {
                    Label("Ask anything", systemImage: "bubble.left")
                        .font(StoryDesignTokens.label)
                        .frame(maxWidth: .infinity, minHeight: StoryDesignTokens.controlHeight)
                }
                .buttonBorderShape(.capsule)
                .storyControlStyle()
                Button(action: add) {
                    Image(systemName: "plus").font(StoryDesignTokens.label)
                        .foregroundStyle(StoryDesignTokens.onAction)
                        .frame(width: StoryDesignTokens.controlHeight, height: StoryDesignTokens.controlHeight)
                }
                .buttonBorderShape(.circle)
                .storyControlStyle(prominent: true)
                .accessibilityLabel("Add record")
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { addButtonWidth = $0 }
            }
        }.controlSize(.regular)
    }
}

struct StoryEmptyOverview: View {
    var body: some View {
        StoryOnboardingCopy(detail: "As you add records, your story takes shape here. Ask about the details or share a summary with your care team.")
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)
            .listRowBackground(StoryDesignTokens.canvas)
    }
}

struct StoryEmptyRecord: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            StoryRecordIcon(symbol: "doc")
                .saturation(0)
                .opacity(0.65)
                .accessibilityHidden(true)

            StoryOnboardingCopy(detail: "Extracted summaries of recordings, photos and files will appear here. Tap + below to add your first record.")
                .accessibilityLabel("Extracted summaries of recordings, photos and files will appear here. Use the Add record button below to get started.")
        }
        .padding(.vertical, 8)
        .listRowSeparator(.hidden)
        .listRowBackground(StoryDesignTokens.canvas)
    }
}

/// A feature introduction with a sample of the finished experience and one next step.
struct StoryFeaturePreview<Example: View>: View {
    let title: String
    let description: String
    let actionTitle: String
    let action: () -> Void
    @ViewBuilder let example: () -> Example

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            example()
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StoryDesignTokens.softSurface, in: RoundedRectangle(cornerRadius: StoryDesignTokens.tileRadius))
            StoryOnboardingCopy(title: title, detail: description)
            Button(action: action) {
                Label(actionTitle, systemImage: "plus")
                    .foregroundStyle(StoryDesignTokens.onAction)
                    .font(StoryDesignTokens.label)
                    .frame(maxWidth: .infinity, minHeight: StoryDesignTokens.controlHeight)
            }
            .storyControlStyle(prominent: true)
        }
        .foregroundStyle(StoryDesignTokens.ink)
        .padding(20)
    }
}

extension View {
    @ViewBuilder func storyControlStyle(prominent: Bool = false, tint: Color = StoryDesignTokens.primaryButtonFill) -> some View {
        if #available(iOS 26, *) {
            if prominent { self.buttonStyle(.glassProminent).tint(tint) }
            else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent).tint(tint) }
            else { self.buttonStyle(.bordered) }
        }
    }
}

struct StorySourceTag: View {
    let title: String
    var systemImage = "link"
    var inlineLineHeight: CGFloat? = nil
    var body: some View {
        Label(title, systemImage: systemImage)
            .font(StoryDesignTokens.font(.footnote, weight: .medium))
            .foregroundStyle(StoryDesignTokens.action)
            .padding(.horizontal, 10)
            .padding(.vertical, inlineLineHeight == nil ? 5 : 0)
            .frame(height: inlineLineHeight)
            .background(StoryDesignTokens.softSurface, in: Capsule())
            .frame(minWidth: 44, minHeight: inlineLineHeight ?? 44)
            .contentShape(Rectangle())
    }
}

struct StoryRecordIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(StoryDesignTokens.font(.title3, weight: .medium))
            .foregroundStyle(StoryDesignTokens.onSoftSurface)
            .frame(width: StoryDesignTokens.iconSize, height: StoryDesignTokens.iconSize)
            .background(StoryDesignTokens.softSurface, in: RoundedRectangle(cornerRadius: StoryDesignTokens.tileRadius))
            .accessibilityHidden(true)
    }
}

struct StorySectionHeading: View {
    let title: String
    var body: some View {
        Text(title).font(StoryDesignTokens.sectionHeading).foregroundStyle(StoryDesignTokens.ink)
            .textCase(nil).accessibilityAddTraits(.isHeader)
    }
}

private struct StoryScreenArrival: ViewModifier {
    let ready: Bool
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22)) { view in
                view.opacity(reduceMotion || (appeared && ready) ? 1 : 0.82)
            }
            .onAppear { appeared = true }
    }
}

extension View {
    func storyLoadIn(ready: Bool = true) -> some View {
        modifier(StoryScreenArrival(ready: ready))
    }
}

// One accessible status
// replaces the decorative lines; Reduce Motion keeps the silhouette still.
struct StoryLoadingPlaceholder: View {
    let label: String
    var rows = 1
    enum Layout { case list, narrative, summary }
    var layout: Layout = .list
    @ScaledMetric(relativeTo: .body) private var lineHeight: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        lines
        .foregroundStyle(StoryDesignTokens.ink.opacity(0.12))
        .overlay {
            if !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { tick in
                    let phase = tick.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, StoryDesignTokens.canvas.opacity(0.8), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.7)
                            .offset(x: g.size.width * (1.7 * phase - 0.7))
                    }
                }
                .mask { lines }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .padding(.vertical, 8)
    }
    private var lines: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(0..<rows, id: \.self) { row in
                if layout == .list {
                    VStack(alignment: .leading, spacing: 9) {
                        Capsule().frame(height: 13)
                        Capsule().frame(maxWidth: 175).frame(height: 11)
                    }
                } else {
                    VStack(alignment: .leading, spacing: lineHeight * 0.8) {
                        if layout == .summary {
                            line(row.isMultiple(of: 2) ? 0.38 : 0.5, height: lineHeight * 1.35)
                        }
                        line(0.96, height: lineHeight)
                        line(0.87, height: lineHeight)
                        line(row.isMultiple(of: 2) ? 0.67 : 0.52, height: lineHeight)
                    }
                }
            }
        }
    }
    private func line(_ fraction: CGFloat, height: CGFloat) -> some View {
        GeometryReader { geometry in
            Capsule().frame(width: geometry.size.width * fraction)
        }
        .frame(height: height)
    }
}
