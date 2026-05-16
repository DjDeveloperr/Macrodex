#if canImport(SwiftUI)
import SwiftUI
import UIKit

@available(iOS 13.0, *)
public extension View {
    func simDeckSwiftUIElement(
        _ name: String,
        id: String? = nil,
        metadata: [String: String] = [:]
    ) -> some View {
        modifier(
            SimDeckSwiftUIElementModifier(
                payload: SimDeckInspectorTagPayload(
                    id: id,
                    name: name,
                    metadata: metadata
                )
            )
        )
    }

    func simDeckInspectorTag(
        _ name: String,
        id: String? = nil,
        metadata: [String: String] = [:]
    ) -> some View {
        background(
            SimDeckInspectorTagRepresentable(
                payload: SimDeckInspectorTagPayload(
                    id: id,
                    name: name,
                    metadata: metadata
                )
            )
        )
    }
}

@available(iOS 13.0, *)
private struct SimDeckSwiftUIElementModifier: ViewModifier {
    var payload: SimDeckInspectorTagPayload

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                SimDeckSwiftUIElementGeometryRepresentable(
                    payload: payload,
                    frameInScreen: validFrame(proxy.frame(in: .global))
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
        )
    }

    private func validFrame(_ frame: CGRect) -> CGRect? {
        guard frame.width > 1, frame.height > 1 else {
            return nil
        }
        return frame
    }
}

@available(iOS 13.0, *)
private struct SimDeckSwiftUIElementGeometryRepresentable: UIViewRepresentable {
    var payload: SimDeckInspectorTagPayload
    var frameInScreen: CGRect?

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let frameInScreen else {
            return
        }
        SimDeckInspectorAgent.shared.publishSwiftUIElementGeometry(
            payload: payload,
            frameInScreen: frameInScreen
        )
    }
}

@available(iOS 13.0, *)
private struct SimDeckInspectorTagRepresentable: UIViewRepresentable {
    var payload: SimDeckInspectorTagPayload

    func makeUIView(context: Context) -> SimDeckInspectorProbeUIView {
        SimDeckInspectorProbeUIView(payload: payload)
    }

    func updateUIView(_ uiView: SimDeckInspectorProbeUIView, context: Context) {
        uiView.payload = payload
    }
}
#endif
