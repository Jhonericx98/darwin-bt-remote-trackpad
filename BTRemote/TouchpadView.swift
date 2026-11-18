#if os(iOS)
    import QuartzCore
    import SwiftUI
    import UIKit

    /// 1-finger drag: moves (optional pointer acceleration)
    /// 1-finger tap: left-clicks
    /// 2-finger tap: right-clicks
    /// 2-finger drag: scrolls vertically and horizontally (axis lock, optional inertia)
    ///
    /// Motion is accumulated with sub-unit precision and coalesced into at most one
    /// mouse report per display frame by `TouchpadEngine`. The BLE peripheral keeps a
    /// single pending report when its notification queue is full, so bursts of reports
    /// overwrite each other; the old scroll path sent a wheel report plus a zero report
    /// per step, and under load most wheel steps were replaced by the zero report.
    struct TouchpadView: UIViewRepresentable {
        let engine: TouchpadEngine
        var moveSensitivity: CGFloat
        var scrollSensitivity: CGFloat
        var pointerAcceleration: Bool
        var scrollInertia: Bool
        var reverseHorizontalScroll: Bool
        var onReport: (MouseReport) -> Void
        var onLeftClick: () -> Void
        var onRightClick: () -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeUIView(context: Context) -> UIView {
            let view = TouchSurfaceView()
            view.backgroundColor = .clear
            view.isMultipleTouchEnabled = true
            let c = context.coordinator
            view.onTouchDown = { [weak c] in c?.touchDown() }

            // one recognizer for pointer and scroll, so a second finger switches
            // to scrolling instead of moving the cursor at the same time
            let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handlePan(_:)))
            pan.minimumNumberOfTouches = 1
            pan.maximumNumberOfTouches = 2
            pan.delegate = c

            let left = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleLeft))
            left.numberOfTouchesRequired = 1
            left.delegate = c

            let right = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleRight))
            right.numberOfTouchesRequired = 2
            right.delegate = c

            [pan, left, right].forEach { view.addGestureRecognizer($0) }
            return view
        }

        func updateUIView(_ uiView: UIView, context: Context) {
            let c = context.coordinator
            c.engine = engine
            engine.output = onReport
            c.moveSensitivity = moveSensitivity
            c.scrollSensitivity = scrollSensitivity
            c.pointerAcceleration = pointerAcceleration
            c.scrollInertia = scrollInertia
            c.reverseHorizontalScroll = reverseHorizontalScroll
            c.onLeftClick = onLeftClick
            c.onRightClick = onRightClick
        }

        static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
            coordinator.engine?.touchEnded()
        }

        @MainActor
        final class Coordinator: NSObject, UIGestureRecognizerDelegate {
            var engine: TouchpadEngine?
            var moveSensitivity: CGFloat = 1
            var scrollSensitivity: CGFloat = 1
            var pointerAcceleration = true
            var scrollInertia = true
            var reverseHorizontalScroll = false
            var onLeftClick: () -> Void = {}
            var onRightClick: () -> Void = {}

            private enum Mode { case idle, pointer, scroll, settling }
            private enum Axis { case undecided, vertical, horizontal, free }

            private var mode = Mode.idle
            private var axis = Axis.undecided
            private var touchCount = 0
            /// scroll travel collected before the axis is decided
            private var lockTravel = CGVector.zero
            /// smoothed finger velocity in points per second
            private var velocity = CGVector.zero
            private var lastSampleAt: CFTimeInterval = 0
            private var lastScrollAt: CFTimeInterval = 0
            private var suppressTapsUntil: CFTimeInterval = 0

            /// finger points per wheel tick at 1× scroll speed (same as before)
            private static let pointsPerTick: CGFloat = 6
            private static let axisLockDistance: CGFloat = 6
            private static let axisLockRatio: CGFloat = 1.8
            /// finger speed (pt/s) needed at lift-off to keep scrolling
            private static let inertiaThreshold: CGFloat = 250
            /// lift-off must follow the last scroll movement within this time
            private static let inertiaWindow: CFTimeInterval = 0.1

            func touchDown() {
                // touching the surface stops inertia; that tap is not a click
                if engine?.stopMomentum() == true {
                    suppressTapsUntil = CACurrentMediaTime() + 0.35
                }
            }

            @objc func handlePan(_ pan: UIPanGestureRecognizer) {
                guard let view = pan.view, let engine else { return }
                let now = CACurrentMediaTime()
                switch pan.state {
                case .began:
                    engine.touchBegan()
                    touchCount = pan.numberOfTouches
                    mode = touchCount >= 2 ? .scroll : .pointer
                    axis = .undecided
                    lockTravel = .zero
                    // the recognizer's own estimate; a delta over ~0 s would spike
                    let v = pan.velocity(in: view)
                    velocity = CGVector(dx: v.x, dy: v.y)
                    lastSampleAt = now
                    process(pan, in: view, now: now, sampleVelocity: false)
                case .changed:
                    let count = pan.numberOfTouches
                    guard count == touchCount else {
                        // the centroid jumps when a finger lands or lifts: drop this delta
                        touchCount = count
                        pan.setTranslation(.zero, in: view)
                        lastSampleAt = now
                        if count >= 2, mode == .pointer {
                            mode = .scroll
                            axis = .undecided
                            lockTravel = .zero
                            velocity = .zero
                            engine.discardPointer()
                        } else if count < 2, mode == .scroll {
                            // one finger left: never turn the rest into cursor motion
                            mode = .settling
                        }
                        return
                    }
                    process(pan, in: view, now: now, sampleVelocity: true)
                case .ended, .cancelled, .failed:
                    if mode == .scroll || mode == .settling, scrollInertia, pan.state == .ended,
                       now - lastScrollAt < Self.inertiaWindow
                    {
                        startInertia()
                    }
                    mode = .idle
                    engine.touchEnded()
                default:
                    break
                }
            }

            private func process(_ pan: UIPanGestureRecognizer, in view: UIView, now: CFTimeInterval, sampleVelocity: Bool) {
                guard let engine else { return }
                let t = pan.translation(in: view)
                pan.setTranslation(.zero, in: view)
                if sampleVelocity {
                    let dt = max(now - lastSampleAt, 1.0 / 240)
                    velocity = CGVector(
                        dx: velocity.dx * 0.6 + t.x / dt * 0.4,
                        dy: velocity.dy * 0.6 + t.y / dt * 0.4
                    )
                }
                lastSampleAt = now
                let speed = hypot(velocity.dx, velocity.dy)

                switch mode {
                case .pointer:
                    let gain = moveSensitivity * (pointerAcceleration ? Self.pointerCurve(speed) : 1)
                    engine.addPointer(CGVector(dx: t.x * gain, dy: t.y * gain))
                case .scroll:
                    var d = CGVector(dx: t.x, dy: t.y)
                    if axis == .undecided {
                        lockTravel.dx += d.dx
                        lockTravel.dy += d.dy
                        guard hypot(lockTravel.dx, lockTravel.dy) >= Self.axisLockDistance else { return }
                        axis = Self.decideAxis(lockTravel)
                        d = lockTravel
                        lockTravel = .zero
                    }
                    lastScrollAt = now
                    engine.addScroll(ticks(constrained(d), speed: speed))
                case .settling, .idle:
                    break
                }
            }

            private func startInertia() {
                guard let engine else { return }
                let v = constrained(velocity)
                let speed = hypot(v.dx, v.dy)
                guard speed >= Self.inertiaThreshold else { return }
                engine.startMomentum(ticks(v, speed: speed))
            }

            /// finger points → wheel/pan ticks; wheel is positive when dragging up
            private func ticks(_ d: CGVector, speed: CGFloat) -> CGVector {
                let k = Self.scrollCurve(speed) * max(scrollSensitivity, 0.1) / Self.pointsPerTick
                let pan = d.dx * k * (reverseHorizontalScroll ? -1 : 1)
                return CGVector(dx: pan, dy: -d.dy * k)
            }

            private func constrained(_ d: CGVector) -> CGVector {
                switch axis {
                case .vertical: CGVector(dx: 0, dy: d.dy)
                case .horizontal: CGVector(dx: d.dx, dy: 0)
                case .free, .undecided: d
                }
            }

            private static func decideAxis(_ d: CGVector) -> Axis {
                let x = abs(d.dx)
                let y = abs(d.dy)
                if y >= x * axisLockRatio { return .vertical }
                if x >= y * axisLockRatio { return .horizontal }
                return .free
            }

            /// slow strokes are precise, fast strokes travel further (≈1× at 400 pt/s)
            private static func pointerCurve(_ speed: CGFloat) -> CGFloat {
                min(2.2, 0.6 + speed / 1000)
            }

            /// progressive scroll acceleration for fast swipes, up to 3×
            private static func scrollCurve(_ speed: CGFloat) -> CGFloat {
                min(3, 1 + max(0, speed - 500) / 700)
            }

            @objc func handleLeft() {
                guard CACurrentMediaTime() >= suppressTapsUntil else { return }
                onLeftClick()
            }

            @objc func handleRight() {
                guard CACurrentMediaTime() >= suppressTapsUntil else { return }
                onRightClick()
            }

            nonisolated func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer,
                shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
            ) -> Bool {
                true
            }
        }
    }

    private final class TouchSurfaceView: UIView {
        var onTouchDown: (() -> Void)?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            onTouchDown?()
            super.touchesBegan(touches, with: event)
        }
    }

    /// Paces trackpad output: fractional motion is carried between frames, at most one
    /// mouse report is sent per display frame (≤ 60 Hz), and held buttons are kept in
    /// every report so dragging with a held button works.
    @MainActor
    final class TouchpadEngine: ObservableObject {
        var output: (MouseReport) -> Void = { _ in }

        private var heldButtons: MouseButtons = []
        private var clickButton: MouseButtons = []
        private var clickReleaseAt: CFTimeInterval = 0
        /// pointer units (mickeys)
        private var pendingPointer = CGVector.zero
        /// ticks: dx = horizontal pan, dy = vertical wheel
        private var pendingScroll = CGVector.zero
        /// ticks per second
        private var momentum = CGVector.zero
        private var isTouching = false
        private var needsRestReport = false
        private var lastReportAt: CFTimeInterval = 0
        private var lastTick: CFTimeInterval = 0
        private var link: CADisplayLink?

        /// lets the last motion report drain before the all-zero report replaces it
        private static let restDelay: CFTimeInterval = 0.12
        /// press-to-release gap of a tap click
        private static let clickHold: CFTimeInterval = 0.03
        /// velocity kept per 60 Hz frame while coasting
        private static let friction: CGFloat = 0.95
        private static let minMomentum: CGFloat = 4
        private static let maxMomentum: CGFloat = 240

        func touchBegan() {
            isTouching = true
            run()
        }

        func touchEnded() {
            isTouching = false
            run()
        }

        func addPointer(_ d: CGVector) {
            pendingPointer.dx += d.dx
            pendingPointer.dy += d.dy
            run()
        }

        func addScroll(_ d: CGVector) {
            pendingScroll.dx += d.dx
            pendingScroll.dy += d.dy
            run()
        }

        func discardPointer() {
            pendingPointer = .zero
        }

        func startMomentum(_ v: CGVector) {
            let limit = Self.maxMomentum
            momentum = CGVector(dx: max(-limit, min(limit, v.dx)), dy: max(-limit, min(limit, v.dy)))
            if hypot(momentum.dx, momentum.dy) < Self.minMomentum {
                momentum = .zero
            } else {
                run()
            }
        }

        /// true when inertia was running
        @discardableResult
        func stopMomentum() -> Bool {
            let wasCoasting = momentum != .zero
            momentum = .zero
            if wasCoasting { pendingScroll = .zero }
            return wasCoasting
        }

        func press(_ button: MouseButtons) {
            heldButtons.insert(button)
            emit(force: true)
        }

        func release(_ button: MouseButtons) {
            heldButtons.remove(button)
            emit(force: true)
            run()
        }

        /// press now, release on a later frame so both reports reach the host
        func click(_ button: MouseButtons) {
            if !clickButton.isEmpty {
                clickButton = []
                emit(force: true)
            }
            clickButton = button
            clickReleaseAt = CACurrentMediaTime() + Self.clickHold
            emit(force: true)
            run()
        }

        fileprivate func tick(_ link: CADisplayLink) {
            let now = CACurrentMediaTime()
            let dt = lastTick > 0 ? min(max(now - lastTick, 0.001), 0.05) : 1.0 / 60
            lastTick = now

            if momentum != .zero {
                pendingScroll.dx += momentum.dx * dt
                pendingScroll.dy += momentum.dy * dt
                let decay = pow(Self.friction, CGFloat(dt * 60))
                momentum = CGVector(dx: momentum.dx * decay, dy: momentum.dy * decay)
                if hypot(momentum.dx, momentum.dy) < Self.minMomentum { momentum = .zero }
            }

            if !clickButton.isEmpty, now >= clickReleaseAt {
                clickButton = []
                emit(force: true)
            } else {
                emit(force: false)
            }

            if needsRestReport, !isTouching, momentum == .zero, now - lastReportAt >= Self.restDelay {
                // relative axes need no zero report; this one only refreshes the
                // peripheral's cached report so a reconnect does not replay motion
                output(MouseReport(buttons: heldButtons))
                needsRestReport = false
            }

            if !isTouching, momentum == .zero, clickButton.isEmpty, !needsRestReport {
                pendingPointer = .zero
                pendingScroll = .zero
                link.isPaused = true
                lastTick = 0
            }
        }

        private func run() {
            if let link {
                link.isPaused = false
                return
            }
            let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        /// sends pending whole units with the current buttons; `force` sends even without motion
        private func emit(force: Bool) {
            let dx = Self.take(&pendingPointer.dx)
            let dy = Self.take(&pendingPointer.dy)
            let wheel = Self.take(&pendingScroll.dy)
            let pan = Self.take(&pendingScroll.dx)
            let hasMotion = dx != 0 || dy != 0 || wheel != 0 || pan != 0
            guard force || hasMotion else { return }
            output(MouseReport(buttons: heldButtons.union(clickButton), dX: dx, dY: dy, wheel: wheel, pan: pan))
            lastReportAt = CACurrentMediaTime()
            if hasMotion { needsRestReport = true }
        }

        /// whole part (clamped to the report range); the remainder stays for the next frame
        private static func take(_ value: inout CGFloat) -> Int8 {
            let whole = max(-127, min(127, value.rounded(.towardZero)))
            value -= whole
            return Int8(whole)
        }
    }

    /// CADisplayLink retains its target; this keeps the engine free to deallocate
    @MainActor
    private final class DisplayLinkProxy: NSObject {
        weak var engine: TouchpadEngine?

        init(_ engine: TouchpadEngine) {
            self.engine = engine
        }

        @objc func tick(_ link: CADisplayLink) {
            guard let engine else {
                link.invalidate()
                return
            }
            engine.tick(link)
        }
    }
#endif
