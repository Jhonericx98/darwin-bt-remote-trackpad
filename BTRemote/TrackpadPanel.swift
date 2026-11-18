import SwiftUI

struct TrackpadPanel: View {
    let hid: HIDInput

    @AppStorage(AppSettings.touchpadSensitivityKey) private var touchpadSensitivity = AppSettings.defaultPointerSensitivity
    @AppStorage(AppSettings.scrollSensitivityKey) private var scrollSensitivity = AppSettings.defaultScrollSensitivity
    #if os(iOS)
        @AppStorage(AppSettings.pointerAccelerationKey) private var pointerAcceleration = true
        @AppStorage(AppSettings.scrollInertiaKey) private var scrollInertia = true
        @AppStorage(AppSettings.reverseHorizontalScrollKey) private var reverseHorizontalScroll = false
        @AppStorage(AppSettings.scrollAsStepsKey) private var scrollAsSteps = true
        @StateObject private var engine = TouchpadEngine()
    #endif
    #if os(macOS)
        @State private var dragOffset: CGSize = .zero
    #endif

    var body: some View {
        VStack(spacing: cellGap) {
            HStack(spacing: cellGap) {
                surface
                scrollColumn.frame(width: 46)
            }
            .frame(maxHeight: .infinity)
            mouseButtonsRow.frame(height: 52)
        }
    }

    private var surface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(groupFill)
            #if os(iOS)
                TouchpadView(
                    engine: engine,
                    moveSensitivity: touchpadSensitivity,
                    scrollSensitivity: scrollSensitivity,
                    pointerAcceleration: pointerAcceleration,
                    scrollInertia: scrollInertia,
                    reverseHorizontalScroll: reverseHorizontalScroll,
                    scrollAsSteps: scrollAsSteps,
                    onReport: { hid.sendMouse($0) },
                    backlog: { hid.backlog() },
                    onLeftClick: { Haptics.tap(); engine.click(.left) },
                    onRightClick: { Haptics.tap(); engine.click(.right) }
                )
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let dx = HIDInput.clamp((value.translation.width - dragOffset.width) * touchpadSensitivity)
                        let dy = HIDInput.clamp((value.translation.height - dragOffset.height) * touchpadSensitivity)
                        dragOffset = value.translation
                        hid.move(dx: dx, dy: dy)
                    }
                    .onEnded { _ in
                        dragOffset = .zero
                        hid.sendMouse(.zero)
                    }
            )
        #endif
    }

    private var scrollAmount: Int8 {
        max(1, HIDInput.clamp(CGFloat(3 * scrollSensitivity)))
    }

    private var scrollColumn: some View {
        VStack(spacing: cellGap) {
            scrollButton("arrow.up", L10n.Mouse.wheelUp, scrollAmount)
            scrollButton("arrow.down", L10n.Mouse.wheelDown, -scrollAmount)
        }
    }

    private var mouseButtonsRow: some View {
        HStack(spacing: cellGap) {
            mouseButton(.left, L10n.Mouse.leftButton)
            mouseButton(.middle, L10n.Mouse.middleButton)
            mouseButton(.right, L10n.Mouse.rightButton)
        }
    }

    private func mouseButton(_ button: MouseButtons, _ label: LocalizedStringKey) -> some View {
        HoldButton(
            onPress: { pressMouse(button) },
            onRelease: { releaseMouse(button) },
            background: { RoundedRectangle(cornerRadius: 12).fill(groupFill) },
            label: { Color.clear }
        )
        .accessibilityLabel(label)
    }

    /// on iOS held buttons go through the engine, so dragging on the surface keeps them pressed
    private func pressMouse(_ button: MouseButtons) {
        #if os(iOS)
            engine.press(button)
        #else
            hid.sendMouse(MouseReport(buttons: button))
        #endif
    }

    private func releaseMouse(_ button: MouseButtons) {
        #if os(iOS)
            engine.release(button)
        #else
            hid.sendMouse(.zero)
        #endif
    }

    /// on iOS holding an arrow keeps scrolling (and speeds up) instead of a single step
    private func pressScroll(_ wheel: Int8) {
        #if os(iOS)
            engine.startHoldScroll(direction: wheel > 0 ? 1 : -1, rate: 20 * scrollSensitivity)
        #else
            hid.scroll(wheel)
        #endif
    }

    private func releaseScroll() {
        #if os(iOS)
            engine.stopHoldScroll()
        #endif
    }

    private func scrollButton(_ icon: String, _ label: LocalizedStringKey, _ wheel: Int8) -> some View {
        HoldButton(
            onPress: { pressScroll(wheel) },
            onRelease: { releaseScroll() },
            background: { RoundedRectangle(cornerRadius: 12).fill(groupFill) },
            label: { Image(systemName: icon).font(.body) }
        )
        .accessibilityLabel(label)
    }
}
