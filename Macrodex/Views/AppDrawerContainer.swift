import Observation
import SwiftUI
import UIKit

private final class DrawerDisplayLinkTarget {
    private let handler: (CADisplayLink) -> Void

    init(_ handler: @escaping (CADisplayLink) -> Void) {
        self.handler = handler
    }

    @objc func tick(_ link: CADisplayLink) {
        handler(link)
    }
}

private final class DrawerPanGestureRecognizer: UIPanGestureRecognizer {
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
}

private struct DrawerPanGestureInstaller: UIViewRepresentable {
    var progress: CGFloat
    var isOpen: Bool
    var isSettling: Bool
    var activationWidth: CGFloat
    var drawerWidth: CGFloat
    var onBegan: () -> Void
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat, CGFloat) -> Void
    var onCancelled: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        context.coordinator.update(installer: self)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(installer: self)
        if let window = uiView.window {
            context.coordinator.install(on: window)
        } else {
            DispatchQueue.main.async {
                guard let window = uiView.window else { return }
                context.coordinator.install(on: window)
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private var installer: DrawerPanGestureInstaller?
        private weak var installedView: UIView?
        private lazy var recognizer: UIPanGestureRecognizer = {
            let recognizer = DrawerPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.maximumNumberOfTouches = 1
            recognizer.delegate = self
            return recognizer
        }()

        func update(installer: DrawerPanGestureInstaller) {
            self.installer = installer
        }

        func install(on view: UIView) {
            guard installedView !== view else { return }
            if let installedView {
                installedView.removeGestureRecognizer(recognizer)
            }
            installedView = view
            view.addGestureRecognizer(recognizer)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let installer,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view
            else { return false }

            let velocity = pan.velocity(in: view)
            let translation = pan.translation(in: view)
            let location = pan.location(in: view)
            let horizontalVelocity = abs(velocity.x)
            let verticalVelocity = abs(velocity.y)
            let horizontalTranslation = abs(translation.x)
            let verticalTranslation = abs(translation.y)
            let hasHorizontalIntent =
                horizontalTranslation > 3
                    ? horizontalTranslation > verticalTranslation * 1.05
                    : horizontalVelocity > 24 && horizontalVelocity > verticalVelocity * 1.05

            let drawerIsTouchable = installer.isOpen || installer.isSettling || installer.progress > 0.001
            if drawerIsTouchable {
                return hasHorizontalIntent
            }

            let isOpening = velocity.x > 0 || translation.x > 0
            return hasHorizontalIntent && isOpening && location.x <= installer.activationWidth
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let installer, let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view).x
            let velocity = recognizer.velocity(in: view).x

            switch recognizer.state {
            case .began:
                installer.onBegan()
            case .changed:
                installer.onChanged(translation)
            case .ended:
                installer.onEnded(translation, velocity)
            case .cancelled, .failed:
                installer.onCancelled()
            default:
                break
            }
        }
    }
}

@MainActor
@Observable
final class DrawerController {
    static let spring = Animation.interactiveSpring(response: 0.28, dampingFraction: 0.86)
    static let settleDuration: Duration = .milliseconds(420)

    var isOpen = false
    /// Coarse published drawer visibility for dependent screens. The visual
    /// fractional progress stays local to `AppDrawerContainer` to avoid
    /// invalidating heavy content on every animation frame.
    var progress: CGFloat = 0
    var selectedPrimaryItem: DrawerPrimaryItem = .dashboard
    private var contentInteractionSuppressedUntil = Date.distantPast

    var shouldSuppressContentInteractions: Bool {
        progress > 0.001 || Date() < contentInteractionSuppressedUntil
    }

    func open() {
        setOpen(true, triggerHaptic: true)
    }

    func close() {
        setOpen(false)
    }

    func toggle() {
        setOpen(!isOpen, triggerHaptic: !isOpen)
    }

    func setOpen(_ open: Bool, animated: Bool = true, triggerHaptic: Bool = false) {
        guard isOpen != open else { return }
        suppressContentInteractionsBriefly()

        if open {
            UIApplication.shared.macrodexDismissKeyboard()
        }

        if triggerHaptic {
            AppHaptics.light()
        }

        let update = {
            self.isOpen = open
        }

        if animated {
            withAnimation(Self.spring, update)
        } else {
            update()
        }
    }

    func suppressContentInteractionsBriefly(duration: TimeInterval = 0.65) {
        contentInteractionSuppressedUntil = max(contentInteractionSuppressedUntil, Date().addingTimeInterval(duration))
    }

    func setDrawerVisible(_ visible: Bool) {
        let newProgress: CGFloat = visible ? 1 : 0
        guard progress != newProgress else { return }
        progress = newProgress
    }
}

struct DrawerMenuButton: View {
    @Environment(DrawerController.self) private var drawerController

    var body: some View {
        Button {
            drawerController.toggle()
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityIdentifier("drawer.menu")
        .accessibilityLabel(drawerController.isOpen ? "Close menu" : "Open menu")
    }
}

struct AppDrawerContainer<Drawer: View, Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let controller: DrawerController
    var openingActivationWidth: CGFloat = 52
    var topSafeAreaInset: CGFloat = 0
    var bottomSafeAreaInset: CGFloat = 0
    @ViewBuilder let drawer: () -> Drawer
    @ViewBuilder let content: () -> Content

    @State private var drawerProgress: CGFloat = 0
    @State private var dragStartProgress: CGFloat = 0
    @State private var isDraggingDrawer = false
    @State private var isSettlingDrawer = false
    @State private var suppressContentHitTesting = false
    @State private var visibilityTask: Task<Void, Never>?
    @State private var settleLink: CADisplayLink?
    @State private var settleLinkTarget: DrawerDisplayLinkTarget?
    @State private var settleGeneration = 0
    @State private var locallySettledControllerTarget: Bool?

    var body: some View {
        GeometryReader { geometry in
            let drawerWidth = min(320, max(276, geometry.size.width * 0.8))
            let progress = min(max(drawerProgress, 0), 1)
            let contentOffset = drawerWidth * progress
            let contentShift = contentOffset
            let drawerTopInset = max(geometry.safeAreaInsets.top, topSafeAreaInset)

            ZStack(alignment: .leading) {
                content()
                    .offset(x: contentShift)
                    .allowsHitTesting(!(suppressContentHitTesting || isDraggingDrawer || progress > 0.001))
                    .zIndex(1)

                if progress > 0.001 {
                    HStack(spacing: 0) {
                        Color.clear
                            .frame(width: contentOffset)
                            .allowsHitTesting(false)

                        overlayTint
                            .opacity(0.30 * progress)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                settleDrawer(open: false)
                            }
                    }
                    .ignoresSafeArea()
                    .zIndex(2)
                }

                drawer()
                    .frame(width: drawerWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, drawerTopInset)
                    .background(Color(uiColor: .systemBackground))
                    .clipShape(
                        UnevenRoundedRectangle(
                            cornerRadii: .init(
                                topLeading: 0,
                                bottomLeading: 0,
                                bottomTrailing: 0,
                                topTrailing: 28
                            ),
                            style: .continuous
                        )
                    )
                    .allowsHitTesting(controller.isOpen && !isDraggingDrawer && !isSettlingDrawer)
                    .shadow(color: .black.opacity(0.12), radius: 18, x: 6, y: 0)
                    .offset(x: contentOffset - drawerWidth)
                    .zIndex(3)

                if shouldCaptureDrawerInterrupts(progress: progress) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .zIndex(4)
                }

                DrawerPanGestureInstaller(
                    progress: progress,
                    isOpen: controller.isOpen,
                    isSettling: isSettlingDrawer,
                    activationWidth: min(max(openingActivationWidth, 0), drawerWidth),
                    drawerWidth: drawerWidth,
                    onBegan: {
                        beginDrawerPan()
                    },
                    onChanged: { translation in
                        updateDrawerPan(translation: translation, drawerWidth: drawerWidth)
                    },
                    onEnded: { translation, velocity in
                        endDrawerPan(
                            translation: translation,
                            velocity: velocity,
                            drawerWidth: drawerWidth
                        )
                    },
                    onCancelled: {
                        cancelDrawerPan()
                    }
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onAppear {
                drawerProgress = controller.isOpen ? 1 : 0
                controller.setDrawerVisible(controller.isOpen)
            }
            .onChange(of: controller.isOpen) { _, isOpen in
                if let localTarget = locallySettledControllerTarget {
                    locallySettledControllerTarget = nil
                    if localTarget == isOpen {
                        return
                    }
                }
                guard !isDraggingDrawer else { return }
                markDrawerSettling()
                animateDrawerProgress(to: isOpen ? 1 : 0)
                updatePublishedDrawerVisibility(open: isOpen, immediate: false)
            }
        }
    }

    private var overlayTint: Color {
        colorScheme == .dark ? .white : .black
    }

    private func shouldCaptureDrawerInterrupts(progress: CGFloat) -> Bool {
        isSettlingDrawer || isDraggingDrawer || (progress > 0.001 && progress < 0.999)
    }

    private func beginDrawerPan() {
        cancelDrawerProgressAnimation()
        isSettlingDrawer = false
        dragStartProgress = drawerProgress
        isDraggingDrawer = true
        if !controller.isOpen, drawerProgress <= 0.001 {
            UIApplication.shared.macrodexDismissKeyboard()
        }
        updatePublishedDrawerVisibility(open: true, immediate: true)
        controller.suppressContentInteractionsBriefly(duration: 0.8)
        suppressContentHitTestingBriefly()
    }

    private func updateDrawerPan(translation: CGFloat, drawerWidth: CGFloat) {
        guard isDraggingDrawer, drawerWidth > 0 else { return }
        let proposed = dragStartProgress + translation / drawerWidth
        setDrawerProgressWithoutAnimation(proposed)
    }

    private func endDrawerPan(translation: CGFloat, velocity: CGFloat, drawerWidth: CGFloat) {
        guard isDraggingDrawer, drawerWidth > 0 else { return }
        let currentProgress = dragStartProgress + translation / drawerWidth
        let projectedProgress = currentProgress + (velocity * 0.16) / drawerWidth
        let shouldOpen: Bool
        if velocity > 160 {
            shouldOpen = true
        } else if velocity < -160 {
            shouldOpen = false
        } else if dragStartProgress > 0.55, translation < -drawerWidth * 0.16 {
            shouldOpen = false
        } else if dragStartProgress < 0.45, translation > drawerWidth * 0.16 {
            shouldOpen = true
        } else {
            shouldOpen = projectedProgress > 0.5
        }

        settleDrawer(open: shouldOpen, triggerHaptic: shouldOpen && !controller.isOpen)
    }

    private func cancelDrawerPan() {
        guard isDraggingDrawer else { return }
        let shouldOpen = drawerProgress > 0.45
        settleDrawer(open: shouldOpen)
    }

    private func settleDrawer(open: Bool, triggerHaptic: Bool = false) {
        let wasDraggingDrawer = isDraggingDrawer
        markDrawerSettling()
        updatePublishedDrawerVisibility(open: true, immediate: wasDraggingDrawer)
        if controller.isOpen != open {
            locallySettledControllerTarget = open
        }
        controller.setOpen(
            open,
            animated: false,
            triggerHaptic: triggerHaptic
        )
        animateDrawerProgress(to: open ? 1 : 0)
        if !open {
            updatePublishedDrawerVisibility(open: false, immediate: false)
        }
        isDraggingDrawer = false
        if wasDraggingDrawer {
            controller.suppressContentInteractionsBriefly(duration: 0.8)
            suppressContentHitTestingBriefly()
        }
    }

    private func markDrawerSettling() {
        settleGeneration += 1
        let generation = settleGeneration
        isSettlingDrawer = true
        Task { @MainActor in
            try? await Task.sleep(for: DrawerController.settleDuration)
            guard generation == settleGeneration, !isDraggingDrawer, settleLink == nil else { return }
            isSettlingDrawer = false
        }
    }

    private func animateDrawerProgress(to target: CGFloat) {
        cancelDrawerProgressAnimation()
        let target = min(max(target, 0), 1)
        let from = min(max(drawerProgress, 0), 1)
        let distance = abs(target - from)
        guard distance > 0.001 else {
            setDrawerProgressWithoutAnimation(target)
            isSettlingDrawer = false
            return
        }

        let startedAt = CACurrentMediaTime()
        let duration = 0.18 + 0.18 * Double(distance)
        let linkTarget = DrawerDisplayLinkTarget { link in
            let elapsed = CACurrentMediaTime() - startedAt
            let t = min(1, elapsed / duration)
            let eased = CGFloat(1 - pow(1 - t, 3))
            setDrawerProgressWithoutAnimation(from + (target - from) * eased)

            guard t >= 1 else { return }
            link.invalidate()
            settleLink = nil
            settleLinkTarget = nil
            setDrawerProgressWithoutAnimation(target)
            isSettlingDrawer = false
        }

        let link = CADisplayLink(target: linkTarget, selector: #selector(DrawerDisplayLinkTarget.tick(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        }
        link.add(to: .main, forMode: .common)
        settleLinkTarget = linkTarget
        settleLink = link
    }

    private func cancelDrawerProgressAnimation() {
        settleLink?.invalidate()
        settleLink = nil
        settleLinkTarget = nil
    }

    private func setDrawerProgressWithoutAnimation(_ progress: CGFloat) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            drawerProgress = min(max(progress, 0), 1)
        }
    }

    private func updatePublishedDrawerVisibility(open: Bool, immediate: Bool) {
        visibilityTask?.cancel()
        if open, immediate {
            controller.setDrawerVisible(true)
            return
        }
        let visible = open
        visibilityTask = Task { @MainActor in
            try? await Task.sleep(for: DrawerController.settleDuration)
            guard !Task.isCancelled else { return }
            controller.setDrawerVisible(visible)
        }
    }

    private func suppressContentHitTestingBriefly() {
        suppressContentHitTesting = true
        Task { @MainActor in
            try? await Task.sleep(for: DrawerController.settleDuration)
            suppressContentHitTesting = false
        }
    }
}
