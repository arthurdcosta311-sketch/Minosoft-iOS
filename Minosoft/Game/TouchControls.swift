import SwiftUI

/// Touch controls: virtual joystick on the left, break/place buttons on the
/// right, and drag-anywhere look on the layer underneath.
struct TouchControls: View {
    @Binding var move: JoystickVector
    var onLook: (CGSize) -> Void
    var onPrimary: () -> Void
    var onSecondary: () -> Void

    @State private var lastLook: CGSize = .zero

    var body: some View {
        ZStack {
            lookLayer
            HStack(alignment: .bottom) {
                VirtualJoystick(vector: $move)
                    .padding(20)
                Spacer()
                actionButtons
                    .padding(20)
            }
        }
    }

    private var lookLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onLook(CGSize(
                            width: value.translation.width - lastLook.width,
                            height: value.translation.height - lastLook.height
                        ))
                        lastLook = value.translation
                    }
                    .onEnded { _ in lastLook = .zero }
            )
    }

    private var actionButtons: some View {
        HStack(spacing: 16) {
            CircleButton(systemImage: "hammer.fill", label: "Break", action: onPrimary)
            CircleButton(systemImage: "square.stack.3d.up.fill", label: "Place", action: onSecondary)
        }
    }
}

struct VirtualJoystick: View {
    @Binding var vector: JoystickVector

    private let radius: CGFloat = 56

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: radius * 2, height: radius * 2)
            Circle()
                .fill(.white.opacity(0.8))
                .frame(width: 44, height: 44)
                .offset(knobOffset)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let translation = value.translation
                    let length = sqrt(translation.width * translation.width + translation.height * translation.height)
                    let clamped = min(length, radius)
                    let scale = length > 0 ? clamped / length : 0
                    vector = JoystickVector(
                        dx: Float(translation.width * scale / radius),
                        dy: Float(translation.height * scale / radius)
                    )
                }
                .onEnded { _ in vector = JoystickVector() }
        )
    }

    private var knobOffset: CGSize {
        CGSize(width: CGFloat(vector.dx) * radius, height: CGFloat(vector.dy) * radius)
    }
}

private struct CircleButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(label)
                    .font(.caption2)
            }
            .frame(width: 64, height: 64)
            .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }
}