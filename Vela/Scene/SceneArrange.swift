import SwiftUI

/// Wraps a scene element so it can be dragged and resized directly on the stage.
///
/// The element keeps its real frame: moving writes a fraction of the stage into the arrangement,
/// so the composition holds its proportions when the window is resized, and resizing writes a
/// scale that the layout reads back when it measures the columns.
struct ArrangeableElement<Content: View>: View {
    let title: String
    let stageSize: CGSize
    /// The element's unscaled width, used to turn a drag into a scale factor.
    let naturalWidth: CGFloat
    let isArranging: Bool
    @Binding var arrangement: SceneArrangement
    /// Pulls the outline in from the element's frame, for a column whose frame is taller than
    /// the content inside it. Without this the resize handle would sit off the bottom edge.
    var verticalInset: CGFloat = 0
    @ViewBuilder var content: () -> Content

    @State private var moveStart: SceneArrangement?
    @State private var scaleStart: Double?

    var body: some View {
        content()
            // While arranging, the controls inside an element must not swallow the drag.
            .allowsHitTesting(!isArranging)
            .overlay {
                if isArranging {
                    ZStack(alignment: .bottomTrailing) {
                        chrome
                        resizeHandle
                    }
                    .padding(.vertical, verticalInset)
                }
            }
            .contentShape(Rectangle())
            .offset(x: arrangement.offsetX * stageSize.width, y: arrangement.offsetY * stageSize.height)
            .gesture(moveGesture, including: isArranging ? .all : .none)
            .animation(.easeInOut(duration: 0.2), value: isArranging)
            .accessibilityElement(children: isArranging ? .ignore : .contain)
            .accessibilityLabel(isArranging ? "\(title) position" : "")
    }

    // MARK: Chrome

    private var chrome: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
            .foregroundStyle(.white.opacity(0.55))
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.05)))
            .overlay(alignment: .top) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.6)))
                    .offset(y: -11)
            }
            .allowsHitTesting(false)
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.black.opacity(0.75))
            .frame(width: 26, height: 26)
            .background(Circle().fill(.white.opacity(0.92)))
            .offset(x: 13, y: 13)
            .gesture(resizeGesture)
            .accessibilityLabel("Resize \(title)")
    }

    // MARK: Gestures

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = moveStart ?? arrangement
                if moveStart == nil { moveStart = start }
                var next = start
                next.offsetX = start.offsetX + value.translation.width / max(1, stageSize.width)
                next.offsetY = start.offsetY + value.translation.height / max(1, stageSize.height)
                arrangement = next.clamped()
            }
            .onEnded { _ in moveStart = nil }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = scaleStart ?? arrangement.scale
                if scaleStart == nil { scaleStart = start }
                // Dragging away from the centre grows the element in proportion to its own width,
                // so the same gesture feels the same on a narrow panel and a wide lyric column.
                let growth = (value.translation.width + value.translation.height) / max(120, naturalWidth)
                var next = arrangement
                next.scale = start * (1 + growth)
                arrangement = next.clamped()
            }
            .onEnded { _ in scaleStart = nil }
    }
}

/// The bar that explains arrange mode and gets you out of it.
struct ArrangeToolbar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.resize")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.palette.highlight.swiftUIColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Arranging the scene").font(.system(size: 12, weight: .semibold))
                Text("Drag an element to move it. Drag its corner to resize.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
            }
            Divider().frame(height: 26).overlay(Color.white.opacity(0.15))
            Button("Reset") { model.resetArrangement() }
                .disabled(model.settings.lyricArrangement.isIdentity && model.settings.panelArrangement.isIdentity)
            Button("Done") { model.endArrangingScene() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(model.reduceTransparency ? 0.92 : 0.72))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
        )
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
    }
}
