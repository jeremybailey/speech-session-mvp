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

enum StoryRecordPrompts {
    static let questions = ["Who’s on your care team?", "What medications do you take?", "What’s bothering you?"]
}

struct StoryQuestionBubble: View {
    let text: String
    var body: some View {
        Text(text)
            .font(StoryDesignTokens.body)
            .foregroundStyle(StoryDesignTokens.onSoftSurface)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(StoryDesignTokens.softSurface, in: RoundedRectangle(cornerRadius: 20))
    }
}

enum StoryGuideAnchor: Hashable { case caption, button }

private struct StoryGuideBounds: PreferenceKey {
    static var defaultValue: [StoryGuideAnchor: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [StoryGuideAnchor: Anchor<CGRect>], nextValue: () -> [StoryGuideAnchor: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    func storyGuideAnchor(_ part: StoryGuideAnchor) -> some View {
        anchorPreference(key: StoryGuideBounds.self, value: .bounds) { [part: $0] }
    }

    func storyPromptAnchor(_ prompt: String) -> some View {
        anchorPreference(key: StoryGuideBounds.self, value: .bounds) {
            prompt == StoryRecordPrompts.questions.last ? [.caption: $0] : [:]
        }
    }

    func connectStoryGuide() -> some View {
        overlayPreferenceValue(StoryGuideBounds.self) { anchors in
            GeometryReader { geometry in
                if let caption = anchors[.caption], let button = anchors[.button] {
                    let text = geometry[caption], target = geometry[button]
                    let direction: CGFloat = target.midX >= text.midX ? 1 : -1
                    let start = CGPoint(x: text.midX + direction * min(text.width * 0.25, 40), y: text.maxY + 10)
                    let tip = CGPoint(x: target.midX, y: target.minY - 16)
                    Path { path in
                        path.move(to: start)
                        let neck = CGPoint(x: tip.x, y: tip.y - 15)
                        path.addCurve(to: neck,
                                      control1: CGPoint(x: start.x + direction * 16, y: start.y + 18),
                                      control2: CGPoint(x: neck.x, y: neck.y - 14))
                        path.addLine(to: CGPoint(x: tip.x, y: tip.y - 2))
                        path.move(to: CGPoint(x: tip.x - 7, y: tip.y - 11))
                        path.addLine(to: tip)
                        path.addLine(to: CGPoint(x: tip.x + 8, y: tip.y - 10))
                    }
                    .stroke(StoryDesignTokens.action, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

struct StoryActionDock: View {
    let ask: () -> Void
    let add: () -> Void
    let guideToAdd: Bool

    var body: some View {
        VStack(spacing: 4) {
            if guideToAdd {
                VStack(spacing: 8) {
                    ForEach(StoryRecordPrompts.questions, id: \.self) { question in
                        StoryQuestionBubble(text: question)
                            .storyPromptAnchor(question)
                    }
                }
                .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                    .padding(.bottom, 68)
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
                .storyGuideAnchor(.button)
            }
        }.controlSize(.regular)
        .connectStoryGuide()
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
        StoryOnboardingCopy(detail: "Your notes, recordings, and files will appear here, newest first.")
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

struct StoryCarePlanPreview: View {
    let add: () -> Void

    var body: some View {
        StoryFeaturePreview(title: "Your care plan in one place",
                            description: "Add a record to upload a written care plan or record a voice journal about what you’re following now.",
                            actionTitle: "Add a record", action: add) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Example care plan", systemImage: "list.bullet.clipboard")
                    .font(StoryDesignTokens.label)
                Divider()
                Text("Following now").font(StoryDesignTokens.caption)
                Text("Keep a list of questions for my next visit.").font(StoryDesignTokens.body)
                Divider()
                Text("Recorded recommendations").font(StoryDesignTokens.caption)
                Text("Bring the exercise sheet to the follow-up.").font(StoryDesignTokens.body)
            }
        }
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
    var body: some View {
        Label(title, systemImage: "link")
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
