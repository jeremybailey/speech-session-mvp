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

struct StoryActionDock: View {
    let ask: () -> Void
    let add: () -> Void
    var guideToAdd = false

    var body: some View {
        HStack(spacing: 12) {
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
            .overlay(alignment: .top) {
                if guideToAdd {
                    Image(systemName: "arrow.turn.right.down")
                        .font(.title2).foregroundStyle(StoryDesignTokens.action)
                        .offset(y: -36).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
        }.controlSize(.regular)
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
