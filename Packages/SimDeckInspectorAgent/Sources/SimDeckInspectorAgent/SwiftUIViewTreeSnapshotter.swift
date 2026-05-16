#if canImport(SwiftUI)
import SwiftUI
import UIKit

@available(iOS 13.0, *)
public extension View {
    func simDeckPublishSwiftUIViewTree(
        _ name: String? = nil,
        id: String? = nil,
        metadata: [String: String] = [:],
        maxDepth: Int = 80
    ) -> some View {
        modifier(
            SimDeckSwiftUIViewTreePublisher(
                rootView: self,
                name: name,
                id: id,
                metadata: metadata,
                maxDepth: maxDepth
            )
        )
    }
}

@available(iOS 13.0, *)
public extension SimDeckInspectorAgent {
    func publishSwiftUIViewTree<Root: View>(
        _ rootView: Root,
        name: String? = nil,
        id: String? = nil,
        metadata: [String: String] = [:],
        maxDepth: Int = 80,
        rootFrameInScreen: CGRect? = nil
    ) throws {
        try publishHierarchySnapshot(
            source: "swiftui",
            snapshotJSON: swiftUIViewTreeSnapshotJSON(
                rootView,
                name: name,
                id: id,
                metadata: metadata,
                maxDepth: maxDepth,
                rootFrameInScreen: rootFrameInScreen
            )
        )
    }

    func swiftUIViewTreeSnapshotJSON<Root: View>(
        _ rootView: Root,
        name: String? = nil,
        id: String? = nil,
        metadata: [String: String] = [:],
        maxDepth: Int = 80,
        rootFrameInScreen: CGRect? = nil
    ) throws -> String {
        try swiftUIViewTreeSnapshotJSON(
            rootView,
            name: name,
            id: id,
            metadata: metadata,
            maxDepth: maxDepth,
            rootFrameInScreen: rootFrameInScreen,
            elementGeometry: swiftUIElementGeometrySnapshot()
        )
    }

    internal func swiftUIViewTreeSnapshotJSON<Root: View>(
        _ rootView: Root,
        name: String?,
        id: String?,
        metadata: [String: String],
        maxDepth: Int,
        rootFrameInScreen: CGRect?,
        elementGeometry: [String: SimDeckInspectorAgent.SwiftUIElementGeometry]
    ) throws -> String {
        let snapshot = SwiftUIViewTreeSnapshotter().snapshot(
            rootView,
            name: name,
            id: id,
            metadata: metadata,
            maxDepth: maxDepth,
            rootFrameInScreen: rootFrameInScreen,
            elementGeometry: elementGeometry
        )
        let data = try JSONEncoder.simDeckInspector.encode(snapshot)
        guard let json = String(data: data, encoding: .utf8) else {
            throw InspectorFailure.actionFailed("Unable to encode SwiftUI hierarchy snapshot.")
        }
        return json
    }
}

@available(iOS 13.0, *)
private struct SimDeckSwiftUIViewTreePublisher<Root: View>: ViewModifier {
    var rootView: Root
    var name: String?
    var id: String?
    var metadata: [String: String]
    var maxDepth: Int

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                SimDeckSwiftUIViewTreePublisherRepresentable(
                    rootView: rootView,
                    name: name,
                    id: id,
                    metadata: metadata,
                    maxDepth: maxDepth,
                    rootFrameInScreen: Self.validFrame(proxy.frame(in: .global))
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
        )
    }

    private static func validFrame(_ frame: CGRect) -> CGRect? {
        guard frame.width > 1, frame.height > 1 else {
            return nil
        }
        return frame
    }
}

@available(iOS 13.0, *)
private struct SimDeckSwiftUIViewTreePublisherRepresentable<Root: View>: UIViewRepresentable {
    var rootView: Root
    var name: String?
    var id: String?
    var metadata: [String: String]
    var maxDepth: Int
    var rootFrameInScreen: CGRect?

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let frameInScreen = Self.nearestMountedFrameInScreen(from: uiView) ?? rootFrameInScreen
        SimDeckInspectorAgent.shared.registerSwiftUIHierarchyPublisher(
            key: Self.publisherKey(name: name, id: id)
        ) { elementGeometry in
            try SimDeckInspectorAgent.shared.swiftUIViewTreeSnapshotJSON(
                rootView,
                name: name,
                id: id,
                metadata: metadata,
                maxDepth: maxDepth,
                rootFrameInScreen: frameInScreen,
                elementGeometry: elementGeometry
            )
        }
    }

    private static func nearestMountedFrameInScreen(from view: UIView) -> CGRect? {
        var current: UIView? = view
        while let candidate = current {
            let frame = candidate.convert(candidate.bounds, to: nil)
            if frame.width > 1, frame.height > 1 {
                return frame
            }
            current = candidate.superview
        }
        return view.window?.bounds
    }

    private static func publisherKey(name: String?, id: String?) -> String {
        if let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return id
        }
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return String(reflecting: Root.self)
    }
}

private struct InspectorSwiftUIViewHierarchySnapshot: Codable, Equatable {
    var protocolVersion: String
    var capturedAt: String
    var processIdentifier: Int32
    var bundleIdentifier: String?
    var displayScale: Double
    var coordinateSpace: String
    var source: String
    var roots: [InspectorSwiftUIViewNode]
}

private struct InspectorSwiftUIViewNode: Codable, Equatable {
    var id: String
    var type: String
    var title: String
    var role: String
    var AXLabel: String?
    var AXIdentifier: String?
    var AXUniqueId: String
    var source: String
    var frame: InspectorRect?
    var frameInScreen: InspectorRect?
    var swiftUI: InspectorSwiftUIInfo
    var children: [InspectorSwiftUIViewNode]
}

@available(iOS 13.0, *)
private protocol SimDeckSwiftUIExpandable {
    func simDeckSwiftUIChildren(
        parentPath: String,
        depth: Int,
        maxDepth: Int
    ) -> [InspectorSwiftUIViewNode]
}

@available(iOS 13.0, *)
extension ForEach: SimDeckSwiftUIExpandable where Content: View {
    private static var simDeckInspectorMaxExpandedRows: Int { 7 }

    fileprivate func simDeckSwiftUIChildren(
        parentPath: String,
        depth: Int,
        maxDepth: Int
    ) -> [InspectorSwiftUIViewNode] {
        let indexedData = Array(data.enumerated())
        let sampledOffsets = Self.sampledOffsets(
            count: indexedData.count,
            elementType: String(reflecting: Data.Element.self)
        )
        return sampledOffsets.compactMap { offset in
            guard indexedData.indices.contains(offset) else {
                return nil
            }
            let (_, element) = indexedData[offset]
            return SwiftUIViewTreeSnapshotter.makeViewNode(
                content(element),
                metadata: Self.rowMetadata(row: offset, total: indexedData.count),
                path: "\(parentPath).row-\(offset)",
                depth: depth,
                maxDepth: maxDepth
            )
        }
    }

    private static func sampledOffsets(count: Int, elementType: String) -> [Int] {
        guard count > simDeckInspectorMaxExpandedRows else {
            return Array(0..<count)
        }

        if elementType == "Foundation.Date" || elementType.hasSuffix(".Date") {
            return Array((count - simDeckInspectorMaxExpandedRows)..<count)
        }

        let headCount = simDeckInspectorMaxExpandedRows / 2
        let tailCount = simDeckInspectorMaxExpandedRows - headCount
        let head = Array(0..<headCount)
        let tailStart = max(headCount, count - tailCount)
        let tail = Array(tailStart..<count)
        return Array(Set(head + tail)).sorted()
    }

    private static func rowMetadata(row: Int, total: Int) -> [String: String] {
        guard total > simDeckInspectorMaxExpandedRows else {
            return [:]
        }
        return [
            "forEachRow": String(row),
            "forEachCount": String(total),
            "forEachSampled": "true",
        ]
    }
}

@available(iOS 13.0, *)
private struct SwiftUIViewTreeSnapshotter {
    func snapshot<Root: View>(
        _ rootView: Root,
        name: String?,
        id: String?,
        metadata: [String: String],
        maxDepth: Int,
        rootFrameInScreen: CGRect?,
        elementGeometry: [String: SimDeckInspectorAgent.SwiftUIElementGeometry]
    ) -> InspectorSwiftUIViewHierarchySnapshot {
        let rootFrame = rootFrameInScreen.map(InspectorRect.init)
        var root = Self.makeViewNode(
            rootView,
            explicitName: name,
            explicitId: id,
            metadata: metadata,
            path: "root",
            depth: 0,
            maxDepth: max(0, maxDepth)
        )
        root.children = Self.prunedEmptyStructuralNodes(root.children)
        root = Self.withMountedFrame(root, frame: rootFrame, source: "mounted-root")
        root = Self.withElementGeometry(root, elementGeometry: elementGeometry)
        root = Self.withDerivedFrames(root)

        return InspectorSwiftUIViewHierarchySnapshot(
            protocolVersion: InspectorProtocol.version,
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            displayScale: Double(UIScreen.main.scale),
            coordinateSpace: "screen-points",
            source: "swiftui",
            roots: [root]
        )
    }

    fileprivate static func makeViewNode<V: View>(
        _ view: V,
        explicitName: String? = nil,
        explicitId: String? = nil,
        metadata: [String: String] = [:],
        path: String,
        depth: Int,
        maxDepth: Int
    ) -> InspectorSwiftUIViewNode {
        if let collapsed = modifiedContentNode(
            view,
            explicitName: explicitName,
            explicitId: explicitId,
            metadata: metadata,
            path: path,
            depth: depth,
            maxDepth: maxDepth
        ) {
            return collapsed
        }

        let rawType = String(reflecting: V.self)
        let displayType = displayTypeName(rawType)
        var children: [InspectorSwiftUIViewNode]
        if depth >= maxDepth {
            children = []
        } else if let expandable = view as? SimDeckSwiftUIExpandable {
            children = expandable.simDeckSwiftUIChildren(
                parentPath: path,
                depth: depth + 1,
                maxDepth: maxDepth
            )
        } else if let reflected = reflectedStructuralChildren(
            of: view,
            parentPath: path,
            depth: depth + 1,
            maxDepth: maxDepth
        ) {
            children = reflected
        } else if let labeledChildren = reflectedLabeledControlChildren(
            of: view,
            rawType: rawType,
            parentPath: path,
            depth: depth + 1,
            maxDepth: maxDepth
        ) {
            children = labeledChildren
        } else if isPrimitiveSwiftUILeaf(rawType) {
            children = []
        } else if V.Body.self != Never.self {
            if shouldUseTypeSkeletonInsteadOfBody(for: view) {
                children = typeSkeletonChildren(
                    from: String(reflecting: V.Body.self),
                    parentPath: "\(path).bodyType",
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    metadata: ["derivedFrom": "bodyType", "bodyEvaluation": "skipped"]
                )
            } else {
                children = [
                    makeAnyNode(
                        view.body,
                        label: "body",
                        path: "\(path).body",
                        depth: depth + 1,
                        maxDepth: maxDepth
                    ),
                ].compactMap { $0 }
                if children.isEmpty {
                    children = typeSkeletonChildren(
                        from: String(reflecting: V.Body.self),
                        parentPath: "\(path).bodyType",
                        depth: depth + 1,
                        maxDepth: maxDepth,
                        metadata: ["derivedFrom": "bodyType", "bodyEvaluation": "empty-body"]
                    )
                }
            }
        } else {
            let reflected = reflectedChildren(
                of: view,
                parentPath: path,
                depth: depth + 1,
                maxDepth: maxDepth
            )
            children = reflected.isEmpty
                ? typeSkeletonChildren(
                    from: rawType,
                    parentPath: "\(path).type",
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    metadata: ["derivedFrom": "valueType", "bodyEvaluation": "body-never"]
                )
                : reflected
        }
        if children.isEmpty, depth < maxDepth, shouldUseStructuralTypeFallback(rawType) {
            children = typeSkeletonChildren(
                from: rawType,
                parentPath: "\(path).type",
                depth: depth + 1,
                maxDepth: maxDepth,
                metadata: ["derivedFrom": "valueType", "bodyEvaluation": "structural-fallback"]
            )
        }

        let directText = extractedSemanticText(from: view, rawType: rawType)
        let semanticText = directText ?? childSemanticText(children)
        let title = clean(explicitName)
            ?? semanticText
            ?? genericDisplayTitle(rawType: rawType, displayType: displayType)
            ?? displayType
        let nodeId = "swiftui:\(clean(explicitId) ?? path)"

        return InspectorSwiftUIViewNode(
            id: nodeId,
            type: displayType,
            title: title,
            role: "SwiftUI View",
            AXLabel: semanticText,
            AXIdentifier: clean(explicitId),
            AXUniqueId: nodeId,
            source: "swiftui",
            frame: nil,
            frameInScreen: nil,
            swiftUI: InspectorSwiftUIInfo(
                isHost: false,
                isProbe: false,
                tag: clean(explicitName),
                tagId: clean(explicitId),
                metadata: metadata,
                isViewTreeNode: true,
                valueType: rawType,
                bodyType: String(reflecting: V.Body.self),
                path: path,
                modifiers: nil
            ),
            children: children
        )
    }

    private static func modifiedContentNode<V: View>(
        _ view: V,
        explicitName: String?,
        explicitId: String?,
        metadata: [String: String],
        path: String,
        depth: Int,
        maxDepth: Int
    ) -> InspectorSwiftUIViewNode? {
        guard String(reflecting: V.self).contains("ModifiedContent<") else {
            return nil
        }

        let mirror = Mirror(reflecting: view)
        let content = mirror.children.first { $0.label == "content" }?.value
        let modifier = mirror.children.first { $0.label == "modifier" }?.value
        guard var node = content.flatMap({
            makeAnyNode(
                $0,
                label: "content",
                path: path,
                depth: depth,
                maxDepth: maxDepth
            )
        }) else {
            return nil
        }

        if let explicitName = clean(explicitName) {
            node.title = explicitName
            node.swiftUI.tag = explicitName
        }
        if let explicitId = clean(explicitId) {
            node.id = "swiftui:\(explicitId)"
            node.AXIdentifier = explicitId
            node.AXUniqueId = node.id
            node.swiftUI.tagId = explicitId
        }
        if !metadata.isEmpty {
            node.swiftUI.metadata = metadata
        }
        if let modifier {
            node.swiftUI.modifiers = (node.swiftUI.modifiers ?? []) + [
                displayTypeName(String(reflecting: type(of: modifier))),
            ]
            if let payload = extractedInspectorPayload(from: modifier) {
                applyInspectorPayload(payload, to: &node)
            }
            if let label = extractedAccessibilityLabel(from: modifier) {
                node.AXLabel = label
                if isGeneratedStructuralTitle(node.title) || node.title == node.type {
                    node.title = label
                }
            }
        }
        return node
    }

    private static func applyInspectorPayload(
        _ payload: SimDeckInspectorTagPayload,
        to node: inout InspectorSwiftUIViewNode
    ) {
        if let id = clean(payload.id) {
            node.id = "swiftui:\(id)"
            node.AXIdentifier = id
            node.AXUniqueId = node.id
            node.swiftUI.tagId = id
        }
        if let name = clean(payload.name) {
            node.title = name
            node.AXLabel = name
            node.swiftUI.tag = name
        }
        if !payload.metadata.isEmpty {
            node.swiftUI.metadata.merge(payload.metadata) { _, new in new }
        }
    }

    private static func extractedInspectorPayload(from value: Any) -> SimDeckInspectorTagPayload? {
        let mirror = Mirror(reflecting: value)
        for child in mirror.children {
            if let payload = child.value as? SimDeckInspectorTagPayload {
                return payload
            }
            if child.label == "payload",
               let payload = child.value as? SimDeckInspectorTagPayload
            {
                return payload
            }
        }
        return nil
    }

    private static func reflectedChildren(
        of value: Any,
        parentPath: String,
        depth: Int,
        maxDepth: Int
    ) -> [InspectorSwiftUIViewNode] {
        Mirror(reflecting: value).children.enumerated().flatMap { index, child in
            let label = child.label ?? String(index)
            return nodesFromReflectedValue(
                child.value,
                label: label,
                path: "\(parentPath).\(pathComponent(label, fallback: index))",
                depth: depth,
                maxDepth: maxDepth
            )
        }
    }

    private static func reflectedStructuralChildren(
        of value: Any,
        parentPath: String,
        depth: Int,
        maxDepth: Int
    ) -> [InspectorSwiftUIViewNode]? {
        let rawType = String(reflecting: type(of: value))
        let isStructural = rawType.contains("TupleView<")
            || rawType.contains("Group<")
            || rawType.contains("ZStack<")
            || rawType.contains("VStack<")
            || rawType.contains("HStack<")
            || rawType.contains("LazyVStack<")
            || rawType.contains("LazyHStack<")
            || rawType.contains("ScrollView<")
            || rawType.contains("NavigationStack<")
            || rawType.contains("ModifiedContent<")
        guard isStructural else {
            return nil
        }
        let children = reflectedChildren(
            of: value,
            parentPath: parentPath,
            depth: depth,
            maxDepth: maxDepth
        )
        return children.isEmpty ? nil : children
    }

    private static func reflectedLabeledControlChildren(
        of value: Any,
        rawType: String,
        parentPath: String,
        depth: Int,
        maxDepth: Int
    ) -> [InspectorSwiftUIViewNode]? {
        let type = displayTypeName(rawType)
        guard Set([
            "Button",
            "DatePicker",
            "Link",
            "Menu",
            "Picker",
            "SecureField",
            "Stepper",
            "TextField",
            "Toggle",
        ]).contains(type) else {
            return nil
        }

        let labels = Set(["label", "prompt", "title", "titleKey"])
        let children = Mirror(reflecting: value).children.enumerated().flatMap { index, child in
            guard let label = child.label, labels.contains(label) else {
                return [InspectorSwiftUIViewNode]()
            }
            return nodesFromReflectedValue(
                child.value,
                label: label,
                path: "\(parentPath).\(pathComponent(label, fallback: index))",
                depth: depth,
                maxDepth: maxDepth
            )
        }

        return children.isEmpty ? nil : children
    }

    private static func nodesFromReflectedValue(
        _ value: Any,
        label: String,
        path: String,
        depth: Int,
        maxDepth: Int
    ) -> [InspectorSwiftUIViewNode] {
        if label == "action" || label == "modifier" || label == "root" {
            return []
        }

        if let node = makeAnyNode(value, label: label, path: path, depth: depth, maxDepth: maxDepth) {
            return [node]
        }

        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .tuple
            || mirror.displayStyle == .optional
            || mirror.displayStyle == .enum
            || label == "_tree"
        {
            return mirror.children.enumerated().flatMap { index, child in
                nodesFromReflectedValue(
                    child.value,
                    label: child.label ?? String(index),
                    path: "\(path).\(pathComponent(child.label, fallback: index))",
                    depth: depth,
                    maxDepth: maxDepth
                )
            }
        }

        let rawType = String(reflecting: type(of: value))
        if rawType.contains("TupleView<") || rawType.contains("Tree<") {
            return mirror.children.enumerated().flatMap { index, child in
                nodesFromReflectedValue(
                    child.value,
                    label: child.label ?? String(index),
                    path: "\(path).\(pathComponent(child.label, fallback: index))",
                    depth: depth,
                    maxDepth: maxDepth
                )
            }
        }

        if label == "content" || label == "label" || label == "value" || label.hasPrefix(".") {
            return mirror.children.enumerated().flatMap { index, child in
                nodesFromReflectedValue(
                    child.value,
                    label: child.label ?? String(index),
                    path: "\(path).\(pathComponent(child.label, fallback: index))",
                    depth: depth,
                    maxDepth: maxDepth
                )
            }
        }

        return []
    }

    private static func shouldUseTypeSkeletonInsteadOfBody(for value: Any) -> Bool {
        containsBodyEvaluationFatalDynamicProperty(value, depth: 0)
    }

    private static func isPrimitiveSwiftUILeaf(_ rawType: String) -> Bool {
        let type = displayTypeName(rawType)
        return Set([
            "Button",
            "Capsule",
            "Circle",
            "Color",
            "DatePicker",
            "Divider",
            "EmptyView",
            "Image",
            "ProgressView",
            "Rectangle",
            "RoundedRectangle",
            "SecureField",
            "Slider",
            "Spacer",
            "Stepper",
            "Text",
            "TextField",
            "Toggle",
        ]).contains(type)
    }

    private static func shouldUseStructuralTypeFallback(_ rawType: String) -> Bool {
        rawType.contains("TupleView<")
            || rawType.contains("Tree<")
            || rawType.contains("Group<")
            || rawType.contains("LazyVStack<")
            || rawType.contains("LazyHStack<")
            || rawType.contains("Optional<")
            || rawType.contains("_ConditionalContent<")
            || rawType.contains("ConditionalContent<")
            || rawType.contains("ModifiedContent<")
    }

    private static func containsBodyEvaluationFatalDynamicProperty(_ value: Any, depth: Int) -> Bool {
        if depth > 4 {
            return false
        }
        let mirror = Mirror(reflecting: value)
        for child in mirror.children {
            let typeName = String(reflecting: type(of: child.value))
            if typeName.contains("SwiftUI.Environment<")
                || typeName.contains("SwiftUI.EnvironmentObject<")
                || typeName.contains("SwiftUI.AppStorage<")
                || typeName.contains("SwiftUI.SceneStorage<")
                || typeName.contains("SwiftUI.StateObject<")
            {
                return true
            }
            if let label = child.label,
               label.hasPrefix("_"),
               containsBodyEvaluationFatalDynamicProperty(child.value, depth: depth + 1)
            {
                return true
            }
        }
        return false
    }

    private static func makeAnyNode(
        _ value: Any,
        label: String?,
        path: String,
        depth: Int,
        maxDepth: Int
    ) -> InspectorSwiftUIViewNode? {
        guard let view = value as? any View else {
            return nil
        }
        return view.simDeckSwiftUIViewTreeNode(
            path: path,
            depth: depth,
            maxDepth: maxDepth
        )
    }

    private static func typeSkeletonChildren(
        from rawType: String,
        parentPath: String,
        depth: Int,
        maxDepth: Int,
        metadata: [String: String] = ["derivedFrom": "bodyType"]
    ) -> [InspectorSwiftUIViewNode] {
        var parser = SwiftUITypeSkeletonParser(rawType)
        guard depth <= maxDepth, let type = parser.parse() else {
            return []
        }
        return type.children.enumerated().map { index, child in
            typeSkeletonNode(
                child,
                path: "\(parentPath).\(pathComponent(displayTypeName(child.name), fallback: index))",
                depth: depth,
                maxDepth: maxDepth,
                metadata: metadata
            )
        }
    }

    private static func typeSkeletonNode(
        _ type: SwiftUITypeSkeleton,
        path: String,
        depth: Int,
        maxDepth: Int,
        metadata: [String: String]
    ) -> InspectorSwiftUIViewNode {
        let displayType = displayTypeName(type.name)
        let children: [InspectorSwiftUIViewNode]
        if depth >= maxDepth {
            children = []
        } else {
            children = type.children.enumerated().map { index, child in
                typeSkeletonNode(
                    child,
                    path: "\(path).\(pathComponent(displayTypeName(child.name), fallback: index))",
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    metadata: metadata
                )
            }.filter { !isInternalStyleSkeletonNode($0.type) }
        }
        let nodeId = "swiftui:\(path)"
        return InspectorSwiftUIViewNode(
            id: nodeId,
            type: displayType,
            title: displayType,
            role: "SwiftUI Type",
            AXLabel: nil,
            AXIdentifier: nil,
            AXUniqueId: nodeId,
            source: "swiftui",
            frame: nil,
            frameInScreen: nil,
            swiftUI: InspectorSwiftUIInfo(
                isHost: false,
                isProbe: false,
                metadata: metadata,
                isViewTreeNode: true,
                valueType: type.name,
                bodyType: nil,
                path: path,
                modifiers: nil
            ),
            children: children
        )
    }

    private static func isInternalStyleSkeletonNode(_ value: String) -> Bool {
        value == "ResolvedButtonStyle" || value == "StaticIf"
    }

    private static func prunedEmptyStructuralNodes(
        _ nodes: [InspectorSwiftUIViewNode]
    ) -> [InspectorSwiftUIViewNode] {
        nodes.compactMap { node in
            var next = node
            next.children = prunedEmptyStructuralNodes(node.children)
            if next.children.isEmpty,
               next.frame == nil,
               next.AXIdentifier == nil,
               next.swiftUI.tag == nil,
               (isGeneratedStructuralTitle(next.title) || isGeneratedStructuralTitle(next.type))
            {
                return nil
            }
            return next
        }
    }

    private static func withMountedFrame(
        _ node: InspectorSwiftUIViewNode,
        frame: InspectorRect?,
        source: String
    ) -> InspectorSwiftUIViewNode {
        guard let frame else {
            return node
        }
        var next = node
        next.frame = next.frame ?? frame
        next.frameInScreen = next.frameInScreen ?? frame
        if next.swiftUI.metadata["frameSource"] == nil {
            next.swiftUI.metadata["frameSource"] = source
        }
        return next
    }

    private static func withElementGeometry(
        _ node: InspectorSwiftUIViewNode,
        elementGeometry: [String: SimDeckInspectorAgent.SwiftUIElementGeometry]
    ) -> InspectorSwiftUIViewNode {
        var next = node
        next.children = node.children.map {
            withElementGeometry($0, elementGeometry: elementGeometry)
        }
        let key = clean(next.swiftUI.tagId) ?? clean(next.swiftUI.tag)
        if let key, let geometry = elementGeometry[key] {
            let frame = InspectorRect(geometry.frameInScreen)
            next.frame = frame
            next.frameInScreen = frame
            next.swiftUI.metadata.merge(geometry.payload.metadata) { _, new in new }
            next.swiftUI.metadata["frameSource"] = "swiftui-geometry"
            next.swiftUI.metadata["frameCapturedAt"] = geometry.capturedAt
        }
        return next
    }

    private static func withDerivedFrames(
        _ node: InspectorSwiftUIViewNode
    ) -> InspectorSwiftUIViewNode {
        var next = node
        next.children = node.children.map(withDerivedFrames)
        if next.frame == nil, let childBounds = childFrameBounds(next.children) {
            next.frame = childBounds
            next.frameInScreen = childBounds
            if next.swiftUI.metadata["frameSource"] == nil {
                next.swiftUI.metadata["frameSource"] = "derived-child-bounds"
            }
        }
        return next
    }

    private static func childFrameBounds(
        _ children: [InspectorSwiftUIViewNode]
    ) -> InspectorRect? {
        let frames = children.compactMap { validFrame($0.frameInScreen ?? $0.frame) }
        guard var bounds = frames.first else {
            return nil
        }
        for frame in frames.dropFirst() {
            let minX = min(bounds.x, frame.x)
            let minY = min(bounds.y, frame.y)
            let maxX = max(bounds.x + bounds.width, frame.x + frame.width)
            let maxY = max(bounds.y + bounds.height, frame.y + frame.height)
            bounds = InspectorRect(
                x: minX,
                y: minY,
                width: maxX - minX,
                height: maxY - minY
            )
        }
        return bounds
    }

    private static func validFrame(_ frame: InspectorRect?) -> InspectorRect? {
        guard let frame,
              frame.x.isFinite,
              frame.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 1,
              frame.height > 1
        else {
            return nil
        }
        return frame
    }

    private static func childSemanticText(_ children: [InspectorSwiftUIViewNode]) -> String? {
        let labels = children
            .compactMap { clean($0.AXLabel ?? $0.title) }
            .filter { !isGeneratedStructuralTitle($0) }
        guard labels.count == 1 else {
            return nil
        }
        return labels.first
    }

    private static func isGeneratedStructuralTitle(_ value: String) -> Bool {
        Set([
            "AnyView",
            "ConditionalContent",
            "ForEach",
            "Group",
            "HStack",
            "LazyHStack",
            "LazyVStack",
            "ModifiedContent",
            "Optional",
            "ResolvedButtonStyle",
            "StaticIf",
            "Tree",
            "TupleView",
            "VStack",
            "ZStack",
        ]).contains(value)
    }

    private static func extractedSemanticText(from value: Any, rawType: String) -> String? {
        let type = displayTypeName(rawType)
        if type == "Text" {
            return firstStringValue(in: value, preferredLabels: ["verbatim", "key"], depth: 0)
        }
        if Set([
            "Button",
            "DatePicker",
            "Link",
            "Menu",
            "Picker",
            "SecureField",
            "Slider",
            "Stepper",
            "TextField",
            "Toggle",
        ]).contains(type) {
            return firstStringValue(
                in: value,
                preferredLabels: [
                    "label",
                    "title",
                    "titleKey",
                    "placeholder",
                    "prompt",
                    "verbatim",
                    "key",
                ],
                depth: 0
            )
        }
        return nil
    }

    private static func extractedAccessibilityLabel(from value: Any) -> String? {
        accessibilityLabelText(in: value, insideAccessibilityType: false, depth: 0)
    }

    private static func accessibilityLabelText(
        in value: Any,
        insideAccessibilityType: Bool,
        depth: Int
    ) -> String? {
        if depth > 10 {
            return nil
        }
        let rawType = String(reflecting: type(of: value))
        let isAccessibilityType = insideAccessibilityType || rawType.contains("Accessibility")
        let mirror = Mirror(reflecting: value)

        for child in mirror.children {
            guard let label = child.label, label == "label" || label == "identifier" else {
                continue
            }
            if let text = child.value as? String, isAccessibilityType {
                return clean(text)
            }
            if isAccessibilityType,
               let text = firstStringValue(
                   in: child.value,
                   preferredLabels: ["verbatim", "key", "label", "identifier"],
                   depth: 0
               )
            {
                return text
            }
        }

        for child in mirror.children {
            if let text = accessibilityLabelText(
                in: child.value,
                insideAccessibilityType: isAccessibilityType,
                depth: depth + 1
            ) {
                return text
            }
        }
        return nil
    }

    private static func firstStringValue(
        in value: Any,
        preferredLabels: Set<String>,
        depth: Int
    ) -> String? {
        if depth > 8 {
            return nil
        }
        let mirror = Mirror(reflecting: value)
        for child in mirror.children {
            if let label = child.label, preferredLabels.contains(label), let text = child.value as? String {
                return clean(text)
            }
        }
        for child in mirror.children {
            if let text = firstStringValue(
                in: child.value,
                preferredLabels: preferredLabels,
                depth: depth + 1
            ) {
                return text
            }
        }
        return nil
    }

    private static func pathComponent(_ label: String?, fallback: Int) -> String {
        let raw = label ?? String(fallback)
        let filtered = raw.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let value = String(filtered).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return value.isEmpty ? String(fallback) : value
    }

    private static func displayTypeName(_ rawType: String) -> String {
        var value = SwiftNameDemangler.demangle(rawType) ?? rawType
        value = value.replacingOccurrences(
            of: #"\(unknown context at \$[0-9a-fA-F]+\)\."#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\.\(unknown context at \$[0-9a-fA-F]+\)"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"--unknown-context-at--[0-9a-fA-F]+--"#,
            with: "-",
            options: .regularExpression
        )
        let base = value.split(separator: "<", maxSplits: 1).first.map(String.init) ?? value
        let name = base.split(separator: ".").last.map(String.init) ?? base
        return name.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
    }

    private static func genericDisplayTitle(rawType: String, displayType: String) -> String? {
        var parser = SwiftUITypeSkeletonParser(rawType)
        guard let parsed = parser.parse(), let firstChild = parsed.children.first else {
            return nil
        }
        let childType = displayTypeName(firstChild.name)
        guard !childType.isEmpty, childType != displayType else {
            return nil
        }
        if displayType == "Button" || displayType == "TextField" || displayType == "Toggle" {
            return "\(displayType)<\(childType)>"
        }
        return nil
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

private struct SwiftUITypeSkeleton: Equatable {
    var name: String
    var children: [SwiftUITypeSkeleton]
}

private struct SwiftUITypeSkeletonParser {
    private let scalars: [UnicodeScalar]
    private var index = 0

    init(_ raw: String) {
        scalars = Array(raw.unicodeScalars)
    }

    mutating func parse() -> SwiftUITypeSkeleton? {
        skipTrivia()
        return parseType()
    }

    private mutating func parseType() -> SwiftUITypeSkeleton? {
        skipTrivia()
        if peek == "(" {
            return parseTuple(named: "Tuple")
        }

        let name = parseName()
        guard !name.isEmpty else {
            return nil
        }

        var children: [SwiftUITypeSkeleton] = []
        skipTrivia()
        if peek == "<" {
            advance()
            children = parseTypeList(until: ">")
        }
        return SwiftUITypeSkeleton(name: name, children: normalized(children))
    }

    private mutating func parseTuple(named name: String) -> SwiftUITypeSkeleton {
        advance()
        let children = parseTypeList(until: ")")
        return SwiftUITypeSkeleton(name: name, children: normalized(children))
    }

    private mutating func parseTypeList(until terminator: UnicodeScalar) -> [SwiftUITypeSkeleton] {
        var result: [SwiftUITypeSkeleton] = []
        while index < scalars.count {
            skipTrivia()
            if peek == terminator {
                advance()
                break
            }
            if peek == "," {
                advance()
                continue
            }
            if let type = parseType() {
                result.append(type)
            } else {
                advance()
            }
            skipTrivia()
            if peek == "," {
                advance()
            }
        }
        return result
    }

    private mutating func parseName() -> String {
        let start = index
        var parenDepth = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if parenDepth == 0, (scalar == "<" || scalar == "," || scalar == ">" || scalar == ")") {
                break
            }
            if scalar == "(" {
                parenDepth += 1
            } else if scalar == ")" {
                parenDepth = max(0, parenDepth - 1)
            }
            index += 1
        }
        return String(String.UnicodeScalarView(scalars[start..<index]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalized(_ children: [SwiftUITypeSkeleton]) -> [SwiftUITypeSkeleton] {
        children.flatMap { child -> [SwiftUITypeSkeleton] in
            let display = simpleDisplayTypeName(child.name)
            if display == "Optional" {
                return normalized(child.children)
            }
            if display == "TupleView" || display == "Tuple" || display == "Group" || display == "AnyView" {
                return normalized(child.children)
            }
            if display == "ModifiedContent" {
                return child.children.first.map { normalized([$0]) } ?? []
            }
            if display == "StaticIf" || display == "ResolvedButtonStyle" || display == "Tree" {
                return normalized(child.children)
            }
            return [child]
        }
    }

    private func simpleDisplayTypeName(_ rawType: String) -> String {
        var value = SwiftNameDemangler.demangle(rawType) ?? rawType
        value = value.replacingOccurrences(
            of: #"\(unknown context at \$[0-9a-fA-F]+\)\."#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\.\(unknown context at \$[0-9a-fA-F]+\)"#,
            with: "",
            options: .regularExpression
        )
        let base = value.split(separator: "<", maxSplits: 1).first.map(String.init) ?? value
        let name = base.split(separator: ".").last.map(String.init) ?? base
        return name.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
    }

    private mutating func skipTrivia() {
        while index < scalars.count, CharacterSet.whitespacesAndNewlines.contains(scalars[index]) {
            index += 1
        }
    }

    private var peek: UnicodeScalar? {
        index < scalars.count ? scalars[index] : nil
    }

    private mutating func advance() {
        index += 1
    }
}

@available(iOS 13.0, *)
private extension View {
    func simDeckSwiftUIViewTreeNode(
        path: String,
        depth: Int,
        maxDepth: Int
    ) -> InspectorSwiftUIViewNode {
        SwiftUIViewTreeSnapshotter.makeViewNode(
            self,
            path: path,
            depth: depth,
            maxDepth: maxDepth
        )
    }
}
#endif
