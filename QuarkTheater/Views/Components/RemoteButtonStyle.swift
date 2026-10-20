import SwiftUI

enum BrandPalette {
    static let deepCharcoal = Color(red: 0x12 / 255.0, green: 0x14 / 255.0, blue: 0x17 / 255.0)
    static let secondary = Color(red: 0x20 / 255.0, green: 0x24 / 255.0, blue: 0x2A / 255.0)
    static let glassWhite = Color(red: 0xF3 / 255.0, green: 0xF6 / 255.0, blue: 0xF8 / 255.0)
    static let iceBlue = Color(red: 0xA9 / 255.0, green: 0xD7 / 255.0, blue: 0xF4 / 255.0)
    static let warmPeach = Color(red: 0xF3 / 255.0, green: 0xB6 / 255.0, blue: 0xA1 / 255.0)
    static let secondaryText = Color(red: 0x9D / 255.0, green: 0xA5 / 255.0, blue: 0xAC / 255.0)
    static let iceGlow = iceBlue.opacity(0.55)
}

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
                return BrandPalette.glassWhite
            } else {
                return BrandPalette.glassWhite.opacity(0.8)
            }
        }

        private var backgroundColor: Color {
            if isFocused {
                return BrandPalette.glassWhite
            } else if isSelected {
                return BrandPalette.glassWhite.opacity(0.12)
            } else {
                return BrandPalette.glassWhite.opacity(0.08)
            }
        }

        private var borderColor: Color {
            if isFocused {
                return BrandPalette.glassWhite
            } else if isSelected {
                return BrandPalette.iceBlue.opacity(0.22)
            } else {
                return BrandPalette.glassWhite.opacity(0.15)
            }
        }
    }
}
