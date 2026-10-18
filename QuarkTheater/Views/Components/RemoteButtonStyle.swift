import SwiftUI

/// Unified button style for tvOS remote navigation with clear, consistent
/// visual differentiation across normal, selected, and focused states.
struct RemoteButtonStyle: ButtonStyle {
    var isSelected: Bool = false
    var cornerRadius: CGFloat = 14
    var horizontalPadding: CGFloat = 20
    var verticalPadding: CGFloat = 12
    var minWidth: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        RemoteButtonBody(
            configuration: configuration,
            isSelected: isSelected,
            cornerRadius: cornerRadius,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            minWidth: minWidth
        )
    }

    private struct RemoteButtonBody: View {
        let configuration: Configuration
        let isSelected: Bool
        let cornerRadius: CGFloat
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        let minWidth: CGFloat

        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.headline.weight(isFocused || isSelected ? .bold : .medium))
                .lineLimit(1)
                .frame(minWidth: minWidth > 0 ? minWidth : nil)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .foregroundStyle(foregroundColor)
                .background(backgroundColor, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(borderColor, lineWidth: isFocused ? 2.5 : (isSelected ? 1.5 : 1))
                )
                .shadow(color: isFocused ? Color.black.opacity(0.4) : .clear, radius: 10, x: 0, y: 5)
        }

        private var foregroundColor: Color {
            if isFocused {
                return .black
            } else if isSelected {
                return .white
            } else {
                return .white.opacity(0.8)
            }
        }

        private var backgroundColor: Color {
            if isFocused {
                return .white
            } else if isSelected {
                return Color.cyan.opacity(0.35)
            } else {
                return Color.white.opacity(0.08)
            }
        }

        private var borderColor: Color {
            if isFocused {
                return .white
            } else if isSelected {
                return Color.cyan.opacity(0.6)
            } else {
                return Color.white.opacity(0.15)
            }
        }
    }
}
