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
                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
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
        VStack(alignment: heading == nil ? .leading : .center, spacing: 8) {
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
                    .font(StoryDesignTokens.label)
                    .foregroundStyle(StoryDesignTokens.bubbleContent)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(text)
                .font(StoryDesignTokens.body)
                .foregroundStyle(StoryDesignTokens.bubbleContent)
                .multilineTextAlignment(heading == nil ? .leading : .center)
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

            StoryOnboardingCopy(detail: "Your notes, recordings, photos and files will appear here. Tap + below to add your first record.")
                .accessibilityLabel("Your notes, recordings, photos and files will appear here. Use the Add record button below to get started.")
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
    @ViewBuilder func storyControlStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26, *) {
            if prominent { self.buttonStyle(.glassProminent).tint(StoryDesignTokens.action) }
            else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent).tint(StoryDesignTokens.action) }
            else { self.buttonStyle(.bordered) }
        }
    }
}

struct StorySourceTag: View {
    let title: String
    var systemImage = "link"
    var body: some View {
        Label(title, systemImage: systemImage)
            .font(StoryDesignTokens.font(.body, weight: .medium))
            .foregroundStyle(StoryDesignTokens.action)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(StoryDesignTokens.softSurface, in: Capsule())
            .frame(minHeight: 44)
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

// Only drawn while the first local snapshot is pending. One accessible status
// replaces the decorative lines; Reduce Motion keeps the silhouette still.
struct StoryLoadingPlaceholder: View {
    let label: String
    var rows = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweeping = false

    var body: some View {
        lines
        .foregroundStyle(StoryDesignTokens.ink.opacity(0.12))
        .overlay {
            if !reduceMotion {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, StoryDesignTokens.canvas.opacity(0.8), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.7)
                        .offset(x: sweeping ? g.size.width : -g.size.width * 0.7)
                        .animation(.linear(duration: 1.6).repeatForever(autoreverses: false), value: sweeping)
                        .onAppear { sweeping = true }
                        .onDisappear { sweeping = false }
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
            ForEach(0..<rows, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 9) {
                    Capsule().frame(height: 13)
                    Capsule().frame(maxWidth: 175).frame(height: 11)
                }
            }
        }
    }
}
