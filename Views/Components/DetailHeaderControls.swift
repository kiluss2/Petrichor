import SwiftUI

struct DetailHeaderControls<Trailing: View>: View {
    let isPinned: Bool
    let isPlaybackDisabled: Bool
    let showsPlaybackControls: Bool
    /// Nil hides the pin button, as for content the library doesn't hold.
    let onTogglePin: (() -> Void)?
    let onPlay: () -> Void
    /// Nil hides the Shuffle button.
    let onShuffle: (() -> Void)?
    @ViewBuilder let trailing: () -> Trailing

    init(
        isPinned: Bool,
        isPlaybackDisabled: Bool,
        showsPlaybackControls: Bool = true,
        onTogglePin: (() -> Void)?,
        onPlay: @escaping () -> Void,
        onShuffle: (() -> Void)?,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.isPinned = isPinned
        self.isPlaybackDisabled = isPlaybackDisabled
        self.showsPlaybackControls = showsPlaybackControls
        self.onTogglePin = onTogglePin
        self.onPlay = onPlay
        self.onShuffle = onShuffle
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            if let onTogglePin {
                Button(action: onTogglePin) {
                    Image(systemName: isPinned ? "pin.slash.fill" : "pin.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 27, height: 27)
                }
                .adaptiveCircularButtonStyle()
                .help(isPinned ? String(localized: "Remove from Home") : String(localized: "Pin to Home"))
            }

            if showsPlaybackControls {
                controlButton(title: "Play", icon: Icons.playFill, action: onPlay)
                    .adaptiveButtonStyle(prominent: true)
                    .disabled(isPlaybackDisabled)

                if let onShuffle {
                    controlButton(title: "Shuffle", icon: Icons.shuffleFill, action: onShuffle)
                        .adaptiveButtonStyle()
                        .disabled(isPlaybackDisabled)
                }
            }

            trailing()
        }
    }


    private func controlButton(title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(width: 90)
            .padding(.vertical, 6)
        }
    }
}

extension DetailHeaderControls where Trailing == EmptyView {
    init(
        isPinned: Bool,
        isPlaybackDisabled: Bool,
        showsPlaybackControls: Bool = true,
        onTogglePin: (() -> Void)?,
        onPlay: @escaping () -> Void,
        onShuffle: (() -> Void)?
    ) {
        self.isPinned = isPinned
        self.isPlaybackDisabled = isPlaybackDisabled
        self.showsPlaybackControls = showsPlaybackControls
        self.onTogglePin = onTogglePin
        self.onPlay = onPlay
        self.onShuffle = onShuffle
        self.trailing = { EmptyView() }
    }
}
