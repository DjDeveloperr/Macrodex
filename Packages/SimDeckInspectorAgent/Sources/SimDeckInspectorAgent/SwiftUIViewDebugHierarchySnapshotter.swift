#if canImport(SwiftUI)
import Darwin
import Foundation
import UIKit

@available(iOS 13.0, *)
final class SwiftUIViewDebugHierarchySnapshotter {
    private let makeViewDebugDataSelector = NSSelectorFromString("makeViewDebugData")
    private let accessibilityDebugDataSelector = NSSelectorFromString("_accessibilitySwiftUIDebugData")

    func diagnostics() -> JSONValue {
        let hosts = swiftUIHostViews()
        let payloads: [JSONValue] = hosts.enumerated().map { hostIndex, hostView in
            let className = NSStringFromClass(type(of: hostView))
            let frame = hostView.convert(hostView.bounds, to: nil)
            var fields: [String: JSONValue] = [
                "hostIndex": .number(Double(hostIndex)),
                "hostViewClass": .string(className),
                "hostViewId": .string(viewId(for: hostView)),
                "frame": rectJSON(frame),
                "respondsToMakeViewDebugData": .bool(hostView.responds(to: makeViewDebugDataSelector)),
                "respondsToAccessibilityDebugData": .bool(hostView.responds(to: accessibilityDebugDataSelector)),
            ]
            if let payload = debugPayload(from: hostView) {
                fields["payload"] = Self.payloadSummary(payload)
            }
            return .object(fields)
        }
        return .object([
            "available": .bool(!payloads.isEmpty),
            "hostCount": .number(Double(payloads.count)),
            "payloads": .array(payloads),
            "viewDebuggerSupport": viewDebuggerSupportDiagnostics(),
        ])
    }

    func snapshot(maxDepth: Int?) -> JSONValue? {
        let hosts = swiftUIHostViews()
        var roots: [JSONValue] = []

        for (hostIndex, hostView) in hosts.enumerated() {
            guard let payload = debugPayload(from: hostView) else {
                continue
            }
            let hostFrame = hostView.convert(hostView.bounds, to: nil)
            let children = nodes(
                from: payload,
                hostView: hostView,
                hostIndex: hostIndex,
                path: "payload",
                depth: 0,
                maxDepth: maxDepth
            )
            guard !children.isEmpty else {
                continue
            }
            roots.append(hostNode(for: hostView, hostIndex: hostIndex, frame: hostFrame, children: children))
        }

        if roots.isEmpty, let viewDebuggerSnapshot = viewDebuggerSupportSnapshot(maxDepth: maxDepth) {
            return viewDebuggerSnapshot
        }

        guard !roots.isEmpty else {
            return nil
        }

        let screen = UIScreen.main
        return .object([
            "protocolVersion": .string(InspectorProtocol.version),
            "capturedAt": .string(Self.iso8601Timestamp()),
            "processIdentifier": .number(Double(ProcessInfo.processInfo.processIdentifier)),
            "bundleIdentifier": .string(Bundle.main.bundleIdentifier ?? ""),
            "displayScale": .number(Double(screen.scale)),
            "coordinateSpace": .string("screen-points"),
            "source": .string("swiftui"),
            "debugBackend": .string("xcode-view-debugger"),
            "roots": .array(roots),
        ])
    }

    private func viewDebuggerSupportSnapshot(maxDepth: Int?) -> JSONValue? {
        guard let payload = viewDebuggerSupportPayload(),
              let data = Self.dataValue(payload),
              let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = propertyList as? NSDictionary,
              let views = dictionary["views"] as? NSArray
        else {
            return nil
        }

        let roots = views.enumerated().compactMap { index, value -> JSONValue? in
            guard let view = value as? NSDictionary else {
                return nil
            }
            return viewDebuggerNode(
                from: view,
                path: "view.\(index)",
                depth: 0,
                maxDepth: maxDepth,
                parentOrigin: .zero
            )
        }
        guard !roots.isEmpty else {
            return nil
        }

        let screen = UIScreen.main
        return .object([
            "protocolVersion": .string(InspectorProtocol.version),
            "capturedAt": .string(Self.iso8601Timestamp()),
            "processIdentifier": .number(Double(ProcessInfo.processInfo.processIdentifier)),
            "bundleIdentifier": .string(Bundle.main.bundleIdentifier ?? ""),
            "displayScale": .number(Double(screen.scale)),
            "coordinateSpace": .string("screen-points"),
            "source": .string("swiftui"),
            "debugBackend": .string("xcode-view-debugger-uikit"),
            "roots": .array(roots),
        ])
    }

    private func viewDebuggerNode(
        from view: NSDictionary,
        path: String,
        depth: Int,
        maxDepth: Int?,
        parentOrigin: CGPoint
    ) -> JSONValue? {
        if let maxDepth, depth > maxDepth {
            return nil
        }

        let className = string(from: view["class"]) ?? "UIView"
        let displayName = Self.cleanDisplayName(className)
        let localFrame = Self.rect(fromPropertyListValue: view["frame"] as Any)
            ?? Self.rect(fromPropertyListValue: view["bounds"] as Any)
            ?? .zero
        let frame = localFrame.offsetBy(dx: parentOrigin.x, dy: parentOrigin.y)
        let children: [JSONValue]
        if let maxDepth, depth >= maxDepth {
            children = []
        } else {
            let childValues = view["subviews"] as? NSArray ?? []
            children = childValues.enumerated().compactMap { index, value -> JSONValue? in
                guard let child = value as? NSDictionary else {
                    return nil
                }
                return viewDebuggerNode(
                    from: child,
                    path: "\(path).\(index)",
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    parentOrigin: frame.origin
                )
            }
        }

        let address = string(from: view["address"]) ?? path
        let id = "xcode-view-debugger:\(address)"
        var metadata: [String: JSONValue] = [
            "debugBackend": .string("xcode-view-debugger-uikit"),
            "path": .string(path),
            "address": .string(address),
            "frameSource": .string(depth == 0 ? "xcode-view-debugger-root" : "xcode-view-debugger-uikit"),
        ]
        if let layerClass = string(from: view["layerClass"]) {
            metadata["layerClass"] = .string(layerClass)
        }
        if let hidden = bool(from: view["hidden"]) {
            metadata["hidden"] = .string(hidden ? "true" : "false")
        }

        return .object([
            "id": .string(id),
            "type": .string(displayName),
            "className": .string(className),
            "displayName": .string(displayName),
            "title": .string(displayName),
            "role": .string("Xcode View Debugger"),
            "AXLabel": .string(displayName),
            "AXIdentifier": .string(id),
            "AXUniqueId": .string(id),
            "source": .string("swiftui"),
            "frame": rectJSON(frame),
            "frameInScreen": rectJSON(frame),
            "swiftUI": .object([
                "isHost": .bool(className.contains("SwiftUI") || className.contains("UIHosting")),
                "isProbe": .bool(className.contains("SimDeckInspectorProbe")),
                "isViewTreeNode": .bool(true),
                "valueType": .string(className),
                "path": .string(path),
                "metadata": .object(metadata),
            ]),
            "children": .array(children),
        ])
    }

    private func debugPayload(from view: UIView) -> Any? {
        if view.responds(to: makeViewDebugDataSelector),
           let value = view.perform(makeViewDebugDataSelector)?.takeUnretainedValue()
        {
            return value
        }
        if view.responds(to: accessibilityDebugDataSelector),
           let value = view.perform(accessibilityDebugDataSelector)?.takeUnretainedValue()
        {
            return value
        }
        return nil
    }

    private func viewDebuggerSupportDiagnostics() -> JSONValue {
        guard let payload = viewDebuggerSupportPayload() else {
            return .object(["available": .bool(false)])
        }
        return .object([
            "available": .bool(true),
            "payload": Self.payloadSummary(payload),
        ])
    }

    private func viewDebuggerSupportPayload() -> Any? {
        _ = dlopen("/usr/lib/libViewDebuggerSupport.dylib", RTLD_NOW)
        let supportClass = (NSClassFromString("DBGViewDebuggerSupport_iOS") ?? NSClassFromString("DBGViewDebuggerSupport")) as? NSObject.Type
        guard let supportClass else {
            return nil
        }
        let selector = NSSelectorFromString("fetchViewHierarchy")
        if supportClass.responds(to: selector),
           let value = supportClass.perform(selector)?.takeUnretainedValue()
        {
            return value
        }

        let optionsSelector = NSSelectorFromString("fetchViewHierarchyWithOptions:")
        return supportClass.responds(to: optionsSelector)
            ? supportClass.perform(optionsSelector, with: NSDictionary())?.takeUnretainedValue()
            : nil
    }

    private func swiftUIHostViews() -> [UIView] {
        var seen = Set<ObjectIdentifier>()
        var matches: [UIView] = []

        for window in windows() where !window.isHidden && window.alpha > 0 {
            collectSwiftUIHostViews(from: window, seen: &seen, matches: &matches)
        }

        return matches
    }

    private func collectSwiftUIHostViews(from view: UIView, seen: inout Set<ObjectIdentifier>, matches: inout [UIView]) {
        let identifier = ObjectIdentifier(view)
        guard !seen.contains(identifier) else {
            return
        }
        seen.insert(identifier)

        if isSwiftUIHost(view) {
            matches.append(view)
        }

        for subview in view.subviews {
            collectSwiftUIHostViews(from: subview, seen: &seen, matches: &matches)
        }
    }

    private func isSwiftUIHost(_ view: UIView) -> Bool {
        if view.responds(to: makeViewDebugDataSelector) || view.responds(to: accessibilityDebugDataSelector) {
            return true
        }
        let className = NSStringFromClass(type(of: view))
        return className.contains("SwiftUI") || className.contains("UIHosting")
    }

    private func windows() -> [UIWindow] {
        let sceneWindows: [UIWindow]
        if #available(iOS 13.0, *) {
            sceneWindows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
        } else {
            sceneWindows = []
        }
        return sceneWindows.isEmpty ? UIApplication.shared.windows : sceneWindows
    }

    private func hostNode(for view: UIView, hostIndex: Int, frame: CGRect, children: [JSONValue]) -> JSONValue {
        let className = NSStringFromClass(type(of: view))
        let id = "swiftui:viewdebug:host-\(hostIndex)"
        return .object([
            "id": .string(id),
            "type": .string(Self.unqualifiedTypeName(className)),
            "title": .string("SwiftUI Host"),
            "role": .string("SwiftUI Host View"),
            "AXLabel": .string("SwiftUI Host"),
            "AXIdentifier": .string(id),
            "AXUniqueId": .string(id),
            "source": .string("swiftui"),
            "frame": rectJSON(frame),
            "frameInScreen": rectJSON(frame),
            "swiftUI": .object([
                "isHost": .bool(true),
                "isProbe": .bool(false),
                "isViewTreeNode": .bool(true),
                "valueType": .string(className),
                "path": .string("host-\(hostIndex)"),
                "metadata": .object([
                    "debugBackend": .string("xcode-view-debugger"),
                    "frameSource": .string("view-debugger-host"),
                    "hostViewId": .string(viewId(for: view)),
                    "hostViewClass": .string(className),
                ]),
            ]),
            "children": .array(children),
        ])
    }

    private func nodes(
        from payload: Any,
        hostView: UIView,
        hostIndex: Int,
        path: String,
        depth: Int,
        maxDepth: Int?
    ) -> [JSONValue] {
        let payload = Self.unwrapOptional(payload)
        if let data = Self.dataValue(payload) {
            guard let decoded = Self.decodedObject(from: data) else {
                return []
            }
            return nodes(
                from: decoded,
                hostView: hostView,
                hostIndex: hostIndex,
                path: path,
                depth: depth,
                maxDepth: maxDepth
            )
        }
        if let elements = Self.arrayElements(payload) {
            return elements.enumerated().compactMap { index, element in
                node(
                    from: element,
                    hostView: hostView,
                    hostIndex: hostIndex,
                    path: "\(path).\(index)",
                    depth: depth,
                    maxDepth: maxDepth
                )
            }
        }

        guard let node = node(
            from: payload,
            hostView: hostView,
            hostIndex: hostIndex,
            path: path,
            depth: depth,
            maxDepth: maxDepth
        ) else {
            return []
        }
        return [node]
    }

    private func node(
        from value: Any,
        hostView: UIView,
        hostIndex: Int,
        path: String,
        depth: Int,
        maxDepth: Int?
    ) -> JSONValue? {
        if let maxDepth, depth > maxDepth {
            return nil
        }

        let value = Self.unwrapOptional(value)
        if let data = Self.dataValue(value), let decoded = Self.decodedObject(from: data) {
            return node(
                from: decoded,
                hostView: hostView,
                hostIndex: hostIndex,
                path: path,
                depth: depth,
                maxDepth: maxDepth
            )
        }
        guard !Self.isPrimitive(value) else {
            return nil
        }

        let hostFrame = hostView.convert(hostView.bounds, to: nil)
        let rawFrame = Self.findRect(in: value, maxDepth: 4)
        let normalizedFrame = rawFrame.flatMap { Self.normalizeFrame($0, hostFrame: hostFrame, hostBounds: hostView.bounds) }
        let childValues = childDebugValues(from: value)
        let childNodes: [JSONValue]
        if let maxDepth, depth >= maxDepth {
            childNodes = []
        } else {
            childNodes = childValues.enumerated().compactMap { index, child in
                node(
                    from: child,
                    hostView: hostView,
                    hostIndex: hostIndex,
                    path: "\(path).children.\(index)",
                    depth: depth + 1,
                    maxDepth: maxDepth
                )
            }
        }

        let typeName = displayTypeName(for: value)
        let title = displayTitle(for: value, fallback: typeName)
        let id = "swiftui:viewdebug:\(hostIndex):\(path)"
        var fields: [String: JSONValue] = [
            "id": .string(id),
            "type": .string(typeName),
            "title": .string(title),
            "role": .string("SwiftUI View"),
            "AXLabel": .string(title),
            "AXIdentifier": .string(id),
            "AXUniqueId": .string(id),
            "source": .string("swiftui"),
            "swiftUI": swiftUIInfo(
                value: value,
                path: path,
                depth: depth,
                frame: normalizedFrame,
                hostFrame: hostFrame,
                hasChildren: !childNodes.isEmpty
            ),
            "children": .array(childNodes),
        ]
        if let normalizedFrame {
            fields["frame"] = rectJSON(normalizedFrame)
            fields["frameInScreen"] = rectJSON(normalizedFrame)
        }
        return .object(fields)
    }

    private func swiftUIInfo(
        value: Any,
        path: String,
        depth: Int,
        frame: CGRect?,
        hostFrame: CGRect,
        hasChildren: Bool
    ) -> JSONValue {
        var metadata: [String: JSONValue] = [
            "debugBackend": .string("xcode-view-debugger"),
            "path": .string(path),
            "mirrorType": .string(String(reflecting: Swift.type(of: value))),
        ]

        let frameSource: String
        if let frame {
            if depth == 0 && hasChildren && Self.rect(frame, approximatelyEquals: hostFrame) {
                frameSource = "xcode-view-debugger-root"
            } else {
                frameSource = "xcode-view-debugger"
            }
        } else {
            frameSource = "none"
        }
        metadata["frameSource"] = .string(frameSource)

        let labels = Self.fieldLabels(value).prefix(12)
        if !labels.isEmpty {
            metadata["fieldLabels"] = .string(labels.joined(separator: ","))
        }

        return .object([
            "isHost": .bool(false),
            "isProbe": .bool(false),
            "isViewTreeNode": .bool(true),
            "valueType": .string(String(reflecting: Swift.type(of: value))),
            "path": .string(path),
            "metadata": .object(metadata),
        ])
    }

    private func childDebugValues(from value: Any) -> [Any] {
        let value = Self.unwrapOptional(value)
        var children: [Any] = []
        for field in Self.fields(value) {
            let label = field.label.lowercased()
            guard label.contains("child")
                || label.contains("children")
                || label.contains("subview")
                || label.contains("content")
                || label.contains("items")
                || label.contains("nodes")
                || label.contains("outputs")
            else {
                continue
            }

            if let elements = Self.arrayElements(field.value) {
                children.append(contentsOf: elements.filter { !Self.isPrimitive(Self.unwrapOptional($0)) })
            } else if !Self.isPrimitive(Self.unwrapOptional(field.value)) {
                children.append(field.value)
            }
        }
        return children
    }

    private func displayTypeName(for value: Any) -> String {
        if let string = Self.preferredString(in: value, labels: ["type", "viewType", "valueType", "name", "kind"]) {
            return Self.cleanDisplayName(string)
        }
        return Self.cleanDisplayName(String(reflecting: Swift.type(of: value)))
    }

    private func displayTitle(for value: Any, fallback: String) -> String {
        if let string = Self.preferredString(in: value, labels: ["title", "label", "name", "text", "type", "viewType"]) {
            return Self.cleanDisplayName(string)
        }
        return fallback
    }

    private func rectJSON(_ rect: CGRect) -> JSONValue {
        .object([
            "x": .number(Double(rect.origin.x)),
            "y": .number(Double(rect.origin.y)),
            "width": .number(Double(rect.size.width)),
            "height": .number(Double(rect.size.height)),
        ])
    }

    private func viewId(for view: UIView) -> String {
        let address = UInt(bitPattern: Unmanaged.passUnretained(view).toOpaque())
        return String(format: "view:0x%llx", UInt64(address))
    }

    private static func preferredString(in value: Any, labels: [String]) -> String? {
        let preferredLabels = labels.map { $0.lowercased() }
        for preferred in preferredLabels {
            for field in fields(value) where field.label.lowercased() == preferred {
                if let string = stringValue(field.value), !string.isEmpty {
                    return string
                }
            }
        }
        for preferred in preferredLabels {
            for field in fields(value) where field.label.lowercased().contains(preferred) {
                if let string = stringValue(field.value), !string.isEmpty {
                    return string
                }
            }
        }
        return nil
    }

    private static func stringValue(_ value: Any) -> String? {
        let value = unwrapOptional(value)
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let string = value as? NSString {
            return String(string).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if isPrimitive(value) {
            return nil
        }
        let description = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty, description.count < 160 else {
            return nil
        }
        return description
    }

    private static func arrayElements(_ value: Any) -> [Any]? {
        let value = unwrapOptional(value)
        if let array = value as? [Any] {
            return array
        }
        if let array = value as? NSArray {
            return array.map { $0 }
        }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .collection || mirror.displayStyle == .set else {
            return nil
        }
        return mirror.children.map(\.value)
    }

    private static func dataValue(_ value: Any) -> Data? {
        let value = unwrapOptional(value)
        if let data = value as? Data {
            return data
        }
        if let data = value as? NSData {
            return data as Data
        }
        return nil
    }

    private static func payloadSummary(_ payload: Any) -> JSONValue {
        let payload = unwrapOptional(payload)
        var fields: [String: JSONValue] = [
            "mirrorType": .string(String(reflecting: Swift.type(of: payload))),
            "displayType": .string(cleanDisplayName(String(reflecting: Swift.type(of: payload)))),
        ]

        if let data = dataValue(payload) {
            let prefix = data.prefix(48)
            fields["dataLength"] = .number(Double(data.count))
            fields["prefixHex"] = .string(prefix.map { String(format: "%02x", $0) }.joined(separator: " "))
            fields["prefixASCII"] = .string(String(decoding: prefix, as: UTF8.self))
            fields["decode"] = decodeSummary(from: data)
        } else if let array = arrayElements(payload) {
            fields["arrayCount"] = .number(Double(array.count))
            fields["firstElementType"] = .string(array.first.map { String(reflecting: Swift.type(of: unwrapOptional($0))) } ?? "")
        } else {
            let labels = fieldLabels(payload)
            fields["fieldLabels"] = .string(labels.prefix(20).joined(separator: ","))
        }

        return .object(fields)
    }

    private static func decodeSummary(from data: Data) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        do {
            let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            fields["propertyList"] = .string(String(reflecting: Swift.type(of: object)))
            if let dictionary = object as? NSDictionary {
                fields["propertyListKeys"] = .string(dictionary.allKeys.map { String(describing: $0) }.prefix(20).joined(separator: ","))
                if let exceptions = dictionary["exceptions"] {
                    fields["exceptions"] = .string(String(String(describing: exceptions).prefix(1200)))
                }
                if let views = dictionary["views"] as? NSArray {
                    fields["viewsCount"] = .number(Double(views.count))
                    if let first = views.firstObject as? NSDictionary {
                        fields["firstViewKeys"] = .string(first.allKeys.map { String(describing: $0) }.prefix(40).joined(separator: ","))
                        fields["firstView"] = .string(String(describing: first).prefixJSONDescription(1600))
                    }
                }
                if let classMap = dictionary["classmap"] as? NSDictionary {
                    fields["classMapCount"] = .number(Double(classMap.count))
                    fields["classMapSample"] = .string(String(describing: classMap).prefixJSONDescription(1000))
                }
            }
        } catch {
            fields["propertyListError"] = .string(String(describing: error))
        }

        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [])
            fields["json"] = .string(String(reflecting: Swift.type(of: object)))
        } catch {
            fields["jsonError"] = .string(String(describing: error))
        }

        if #available(iOS 11.0, *) {
            do {
                let object = try NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data)
                fields["keyedArchive"] = .string(String(reflecting: Swift.type(of: object as Any)))
            } catch {
                fields["keyedArchiveError"] = .string(String(describing: error))
            }
        }
        return .object(fields)
    }

    private static func decodedObject(from data: Data) -> Any? {
        if let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            return propertyList
        }

        if let json = try? JSONSerialization.jsonObject(with: data, options: []) {
            return json
        }

        if #available(iOS 11.0, *) {
            if let object = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) {
                return object
            }
        } else {
            return NSKeyedUnarchiver.unarchiveObject(with: data)
        }

        return nil
    }

    private static func fields(_ value: Any) -> [(label: String, value: Any)] {
        let value = unwrapOptional(value)
        return Mirror(reflecting: value).children.compactMap { child in
            guard let label = child.label, !label.isEmpty else {
                return nil
            }
            return (label, child.value)
        }
    }

    private static func fieldLabels(_ value: Any) -> [String] {
        fields(value).map(\.label)
    }

    private static func findRect(in value: Any, maxDepth: Int) -> CGRect? {
        findRect(in: value, remainingDepth: maxDepth, labelHint: "")
    }

    private static func findRect(in value: Any, remainingDepth: Int, labelHint: String) -> CGRect? {
        guard remainingDepth >= 0 else {
            return nil
        }
        let value = unwrapOptional(value)
        if let rect = value as? CGRect, valid(rect) {
            return rect
        }
        if let value = value as? NSValue {
            let objCType = String(cString: value.objCType)
            if objCType.contains("CGRect"), valid(value.cgRectValue) {
                return value.cgRectValue
            }
        }
        if let dictionary = value as? NSDictionary, let rect = rect(from: dictionary), valid(rect) {
            return rect
        }

        let fields = fields(value)
        if let rect = rect(fromFields: fields), valid(rect) {
            return rect
        }

        let frameLabels = ["globalframe", "screenframe", "frameinscreen", "absolute", "frame", "bounds", "rect"]
        for field in fields {
            let label = field.label.lowercased()
            guard frameLabels.contains(where: { label.contains($0) }) || labelHint.contains("frame") else {
                continue
            }
            if let rect = findRect(in: field.value, remainingDepth: remainingDepth - 1, labelHint: label), valid(rect) {
                return rect
            }
        }

        for field in fields {
            if let rect = findRect(in: field.value, remainingDepth: remainingDepth - 1, labelHint: field.label.lowercased()), valid(rect) {
                return rect
            }
        }
        return nil
    }

    private static func rect(from dictionary: NSDictionary) -> CGRect? {
        let keys = dictionary.allKeys.compactMap { $0 as? String }
        let lower = Dictionary(uniqueKeysWithValues: keys.map { ($0.lowercased(), $0) })
        if let xKey = lower["x"],
           let yKey = lower["y"],
           let widthKey = lower["width"],
           let heightKey = lower["height"],
           let x = number(dictionary[xKey] as Any),
           let y = number(dictionary[yKey] as Any),
           let width = number(dictionary[widthKey] as Any),
           let height = number(dictionary[heightKey] as Any)
        {
            return CGRect(x: x, y: y, width: width, height: height)
        }
        return nil
    }

    private static func rect(fromPropertyListValue value: Any) -> CGRect? {
        let value = unwrapOptional(value)
        if let rect = value as? CGRect {
            return rect
        }
        if let array = value as? NSArray, array.count >= 4,
           let x = number(array[0]),
           let y = number(array[1]),
           let width = number(array[2]),
           let height = number(array[3])
        {
            return CGRect(x: x, y: y, width: width, height: height)
        }
        if let dictionary = value as? NSDictionary {
            return rect(from: dictionary)
        }
        return nil
    }

    private static func rect(fromFields fields: [(label: String, value: Any)]) -> CGRect? {
        let keyed = Dictionary(uniqueKeysWithValues: fields.map { ($0.label.lowercased(), $0.value) })
        if let x = number(keyed["x"] as Any),
           let y = number(keyed["y"] as Any),
           let width = number(keyed["width"] as Any),
           let height = number(keyed["height"] as Any)
        {
            return CGRect(x: x, y: y, width: width, height: height)
        }

        let origin = point(from: keyed["origin"] as Any) ?? point(from: keyed["position"] as Any)
        let size = size(from: keyed["size"] as Any) ?? size(from: keyed["dimensions"] as Any)
        if let origin, let size {
            return CGRect(origin: origin, size: size)
        }
        return nil
    }

    private static func point(from value: Any) -> CGPoint? {
        let value = unwrapOptional(value)
        if let point = value as? CGPoint {
            return point
        }
        let fields = fields(value)
        let keyed = Dictionary(uniqueKeysWithValues: fields.map { ($0.label.lowercased(), $0.value) })
        if let x = number(keyed["x"] as Any), let y = number(keyed["y"] as Any) {
            return CGPoint(x: x, y: y)
        }
        return nil
    }

    private static func size(from value: Any) -> CGSize? {
        let value = unwrapOptional(value)
        if let size = value as? CGSize {
            return size
        }
        let fields = fields(value)
        let keyed = Dictionary(uniqueKeysWithValues: fields.map { ($0.label.lowercased(), $0.value) })
        if let width = number(keyed["width"] as Any), let height = number(keyed["height"] as Any) {
            return CGSize(width: width, height: height)
        }
        return nil
    }

    private static func number(_ value: Any) -> CGFloat? {
        let value = unwrapOptional(value)
        if let number = value as? NSNumber {
            return CGFloat(truncating: number)
        }
        if let value = value as? CGFloat {
            return value
        }
        if let value = value as? Double {
            return CGFloat(value)
        }
        if let value = value as? Float {
            return CGFloat(value)
        }
        if let value = value as? Int {
            return CGFloat(value)
        }
        if let value = value as? UInt {
            return CGFloat(value)
        }
        if let value = value as? String, let number = Double(value) {
            return CGFloat(number)
        }
        if let value = value as? NSString, let number = Double(value as String) {
            return CGFloat(number)
        }
        return nil
    }

    private func string(from value: Any?) -> String? {
        guard let value else {
            return nil
        }
        let unwrapped = Self.unwrapOptional(value)
        if let string = unwrapped as? String {
            return string
        }
        if let string = unwrapped as? NSString {
            return string as String
        }
        if let number = unwrapped as? NSNumber {
            return String(describing: number)
        }
        return nil
    }

    private func bool(from value: Any?) -> Bool? {
        guard let value else {
            return nil
        }
        let unwrapped = Self.unwrapOptional(value)
        if let bool = unwrapped as? Bool {
            return bool
        }
        if let number = unwrapped as? NSNumber {
            return number.boolValue
        }
        if let string = unwrapped as? String {
            switch string.lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private static func normalizeFrame(_ frame: CGRect, hostFrame: CGRect, hostBounds: CGRect) -> CGRect? {
        guard valid(frame) else {
            return nil
        }

        let screenBounds = UIScreen.main.bounds.insetBy(dx: -2, dy: -2)
        if screenBounds.intersects(frame) && frame.maxX <= screenBounds.maxX + 2 && frame.maxY <= screenBounds.maxY + 2 {
            return frame
        }

        let localBounds = hostBounds.insetBy(dx: -2, dy: -2)
        if localBounds.intersects(frame) && frame.maxX <= localBounds.maxX + 2 && frame.maxY <= localBounds.maxY + 2 {
            return frame.offsetBy(dx: hostFrame.origin.x, dy: hostFrame.origin.y)
        }

        let offset = frame.offsetBy(dx: hostFrame.origin.x, dy: hostFrame.origin.y)
        return screenBounds.intersects(offset) ? offset : frame
    }

    private static func valid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.size.width.isFinite
            && rect.size.height.isFinite
            && rect.size.width > 0.5
            && rect.size.height > 0.5
    }

    private static func rect(_ lhs: CGRect, approximatelyEquals rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 1
            && abs(lhs.origin.y - rhs.origin.y) < 1
            && abs(lhs.size.width - rhs.size.width) < 1
            && abs(lhs.size.height - rhs.size.height) < 1
    }

    private static func isPrimitive(_ value: Any) -> Bool {
        let value = unwrapOptional(value)
        return value is String
            || value is NSString
            || value is NSNumber
            || value is Bool
            || value is Int
            || value is UInt
            || value is Double
            || value is Float
            || value is CGFloat
            || value is CGRect
            || value is CGPoint
            || value is CGSize
            || value is Data
            || value is NSData
            || value is NSNull
    }

    private static func unwrapOptional(_ value: Any) -> Any {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else {
            return value
        }
        guard let child = mirror.children.first else {
            return NSNull()
        }
        return unwrapOptional(child.value)
    }

    private static func cleanDisplayName(_ value: String) -> String {
        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = cleaned.split(separator: ".").last {
            cleaned = String(last)
        }
        for prefix in ["Optional<", "SwiftUI."] where cleaned.hasPrefix(prefix) {
            cleaned.removeFirst(prefix.count)
        }
        if cleaned.hasSuffix(">") {
            cleaned.removeLast()
        }
        return cleaned.isEmpty ? "SwiftUI View" : cleaned
    }

    private static func unqualifiedTypeName(_ value: String) -> String {
        value.split(separator: ".").last.map(String.init) ?? value
    }

    private static func iso8601Timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

private extension String {
    func prefixJSONDescription(_ maxLength: Int) -> String {
        String(prefix(maxLength))
    }
}
#endif
