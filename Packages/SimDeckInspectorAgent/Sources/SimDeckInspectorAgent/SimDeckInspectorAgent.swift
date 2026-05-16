import Foundation
import UIKit

public final class SimDeckInspectorAgent {
    struct SwiftUIElementGeometry {
        var payload: SimDeckInspectorTagPayload
        var frameInScreen: CGRect
        var capturedAt: String
    }

    public struct Configuration {
        public var port: UInt16
        public var portSearchLimit: UInt16
        public var bindToLocalhostOnly: Bool
        public var authToken: String?
        public var advertiseBonjour: Bool
        public var serviceName: String?

        public init(
            port: UInt16 = 47370,
            portSearchLimit: UInt16 = 32,
            bindToLocalhostOnly: Bool = true,
            authToken: String? = nil,
            advertiseBonjour: Bool = true,
            serviceName: String? = nil
        ) {
            self.port = port
            self.portSearchLimit = portSearchLimit
            self.bindToLocalhostOnly = bindToLocalhostOnly
            self.authToken = authToken
            self.advertiseBonjour = advertiseBonjour
            self.serviceName = serviceName
        }

        public static let debugDefault = Configuration()
    }

    public static let shared = SimDeckInspectorAgent()

    private let snapshotter = ViewHierarchySnapshotter()
    private let interactionPerformer = ViewInteractionPerformer()
    private var configuration = Configuration.debugDefault
    private var publishedHierarchySnapshots: [String: PublishedHierarchySnapshot] = [:]
    private var swiftUIHierarchyPublishers: [String: SwiftUIHierarchyPublisher] = [:]
    private var lastSwiftUIHierarchyRefresh = Date.distantPast
    private let swiftUIHierarchyMinRefreshInterval: TimeInterval = 3.0
    private let swiftUIHierarchyMaxRefreshInterval: TimeInterval = 15.0
    private var swiftUIHierarchyNeedsRefresh = false
    private var swiftUIHierarchyRefreshGeneration: UInt64 = 0
    private var swiftUIHierarchyRefreshInFlight = false
    private var swiftUIElementGeometryByKey: [String: SwiftUIElementGeometry] = [:]
    private var cachedSwiftUIViewDebugSnapshot: (maxDepth: Int?, capturedAt: Date, value: JSONValue)?
    private let swiftUIViewDebugSnapshotCacheTTL: TimeInterval = 1.0
    private var server: InspectorTCPServer?
    private var activePort: UInt16?

    private init() {}

    @discardableResult
    public func start(configuration: Configuration = .debugDefault) throws -> UInt16 {
        if let activePort {
            return activePort
        }

        self.configuration = configuration
        let server = InspectorTCPServer(configuration: configuration) { [weak self] data, respond in
            self?.handle(data, respond: respond)
        }
        let port = try server.start()
        self.server = server
        self.activePort = port
        NSLog("SimDeckInspectorAgent listening on TCP port \(port)")
        return port
    }

    public func stop() {
        server?.stop()
        server = nil
        activePort = nil
    }

    public func snapshot(includeHidden: Bool = false, maxDepth: Int? = nil) -> InspectorHierarchySnapshot {
        dispatchPrecondition(condition: .onQueue(.main))
        return snapshotter.snapshot(includeHidden: includeHidden, maxDepth: maxDepth)
    }

    public func publishHierarchySnapshot(source: String, snapshotJSON: String) throws {
        let published = try Self.makePublishedHierarchySnapshot(source: source, snapshotJSON: snapshotJSON)

        if Thread.isMainThread {
            publishedHierarchySnapshots[published.key] = published
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.publishedHierarchySnapshots[published.key] = published
            }
        }
    }

    public func clearPublishedHierarchySnapshot(source: String? = nil) {
        let clear = { [weak self] in
            guard let self else {
                return
            }
            if let source {
                publishedHierarchySnapshots = publishedHierarchySnapshots.filter { _, snapshot in
                    snapshot.source != source
                }
            } else {
                publishedHierarchySnapshots.removeAll()
            }
        }

        if Thread.isMainThread {
            clear()
        } else {
            DispatchQueue.main.async(execute: clear)
        }
    }

    func registerSwiftUIHierarchyPublisher(
        source: String = "swiftui",
        key: String,
        snapshotProvider: @escaping ([String: SwiftUIElementGeometry]) throws -> String
    ) {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSource = source.isEmpty ? "swiftui" : source
        let publisher = SwiftUIHierarchyPublisher(
            source: normalizedSource,
            key: "\(normalizedSource):\(key)",
            snapshotProvider: snapshotProvider,
            registeredAt: Self.iso8601Timestamp()
        )
        let register: () -> Void = { [weak self] in
            guard let self else {
                return
            }
            swiftUIHierarchyPublishers[publisher.key] = publisher
            markSwiftUIHierarchyNeedsRefresh()
        }

        if Thread.isMainThread {
            register()
        } else {
            DispatchQueue.main.async(execute: register)
        }
    }

    public func publishSwiftUIElementGeometry(
        payload: SimDeckInspectorTagPayload,
        frameInScreen: CGRect
    ) {
        guard let key = Self.swiftUIElementGeometryKey(for: payload) else {
            return
        }
        let publish: () -> Void = { [weak self] in
            guard let self else {
                return
            }
            if let existing = swiftUIElementGeometryByKey[key],
               existing.payload == payload,
               Self.geometryFrame(existing.frameInScreen, isApproximatelyEqualTo: frameInScreen)
            {
                return
            }
            swiftUIElementGeometryByKey[key] = SwiftUIElementGeometry(
                payload: payload,
                frameInScreen: frameInScreen,
                capturedAt: Self.iso8601Timestamp()
            )
            markSwiftUIHierarchyNeedsRefresh()
        }

        if Thread.isMainThread {
            publish()
        } else {
            DispatchQueue.main.async {
                publish()
            }
        }
    }

    func swiftUIElementGeometrySnapshot() -> [String: SwiftUIElementGeometry] {
        dispatchPrecondition(condition: .onQueue(.main))
        return swiftUIElementGeometryByKey
    }

    private func handle(_ data: Data, respond: @escaping (Data) -> Void) {
        let request: InspectorRequest
        do {
            request = try JSONDecoder.simDeckInspector.decode(InspectorRequest.self, from: data)
        } catch {
            respond(InspectorProtocol.failure(id: nil, InspectorFailure.invalidRequest("Request must be a JSON object with id, method, and optional params.")))
            return
        }

        DispatchQueue.main.async {
            do {
                if let token = self.configuration.authToken, request.token != token {
                    throw InspectorFailure.unauthorized
                }
                let result = try self.dispatch(request)
                respond(try InspectorProtocol.success(id: request.id, result: result))
            } catch {
                respond(InspectorProtocol.failure(id: request.id, error))
            }
        }
    }

    private func dispatch(_ request: InspectorRequest) throws -> JSONValue {
        let params = request.params?.objectValue ?? [:]

        switch request.method {
        case "Runtime.ping":
            return .object([
                "ok": .bool(true),
                "protocolVersion": .string(InspectorProtocol.version),
            ])

        case "Inspector.getInfo":
            return try info()

        case "View.getHierarchy":
            let includeHidden = params.bool("includeHidden") ?? false
            let maxDepth = params.int("maxDepth")
            let requestedSource = params.string("source")?.trimmingCharacters(in: .whitespacesAndNewlines)
            if requestedSource != "uikit" {
                if requestedSource == nil || requestedSource?.isEmpty == true || requestedSource == "swiftui" {
                    if let swiftUIViewDebugSnapshot = swiftUIViewDebugHierarchySnapshot(maxDepth: maxDepth) {
                        return swiftUIViewDebugSnapshot
                    }
                }
                try refreshSwiftUIHierarchySnapshotsIfNeeded(source: requestedSource)
                if let publishedHierarchySnapshot = publishedHierarchySnapshot(source: requestedSource) {
                    return try enrichPublishedHierarchySnapshot(publishedHierarchySnapshot)
                }
                if let requestedSource, !requestedSource.isEmpty {
                    return try emptyPublishedHierarchySnapshot(source: requestedSource)
                }
            }
            return try simDeckJSONValue(snapshotter.snapshot(includeHidden: includeHidden, maxDepth: maxDepth))

        case "View.get":
            let id = try requiredString("id", in: params)
            guard let view = snapshotter.view(withId: id) else {
                throw InspectorFailure.targetNotFound(id)
            }
            return try simDeckJSONValue(snapshotter.node(for: view, includeHidden: true, maxDepth: params.int("maxDepth"), depth: 0))

        case "View.hitTest":
            let point = try point(in: params)
            guard let view = snapshotter.hitTest(screenPoint: point, windowId: params.string("windowId")) else {
                return .object(["view": .null])
            }
            return .object([
                "view": try simDeckJSONValue(snapshotter.node(for: view, includeHidden: true, maxDepth: params.int("maxDepth") ?? 2, depth: 0)),
            ])

        case "View.describeAtPoint":
            let point = try point(in: params)
            guard let view = snapshotter.hitTest(screenPoint: point, windowId: params.string("windowId")) else {
                return .object(["view": .null, "ancestors": .array([])])
            }
            return try describe(view: view)

        case "View.listActions":
            let id = try requiredString("id", in: params)
            guard let view = snapshotter.view(withId: id) else {
                throw InspectorFailure.targetNotFound(id)
            }
            return .object([
                "id": .string(ViewHierarchySnapshotter.id(for: view)),
                "actions": .array(ViewInteractionPerformer.actions(for: view).map(JSONValue.string)),
            ])

        case "View.perform":
            let id = try requiredString("id", in: params)
            let action = try requiredString("action", in: params)
            guard let view = snapshotter.view(withId: id) else {
                throw InspectorFailure.targetNotFound(id)
            }
            return try interactionPerformer.perform(action: action, on: view, params: params)

        case "SwiftUI.debugPayloads":
            return swiftUIViewDebugPayloadDiagnostics()

        default:
            throw InspectorFailure.methodNotFound(request.method)
        }
    }

    private func info() throws -> JSONValue {
        let screen = UIScreen.main
        let bundle = Bundle.main
        return .object([
            "protocolVersion": .string(InspectorProtocol.version),
            "transport": .string("tcp+ndjson"),
            "host": .string("127.0.0.1"),
            "port": .number(Double(activePort ?? configuration.port)),
            "processIdentifier": .number(Double(ProcessInfo.processInfo.processIdentifier)),
            "bundleIdentifier": .string(bundle.bundleIdentifier ?? ""),
            "bundleName": .string(bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ""),
            "displayScale": .number(Double(screen.scale)),
            "screenBounds": try simDeckJSONValue(InspectorRect(screen.bounds)),
            "coordinateSpace": .string("screen-points"),
            "methods": .array(InspectorProtocol.methods.map(JSONValue.string)),
            "appHierarchy": .object([
                "source": .string(latestPublishedHierarchySnapshot?.source ?? ""),
                "available": .bool(!publishedHierarchySnapshots.isEmpty),
                "publishedAt": .string(latestPublishedHierarchySnapshot?.publishedAt ?? ""),
            ]),
            "swiftUI": .object([
                "automaticHostDetection": .bool(true),
                "tagModifier": .string("View.simDeckInspectorTag(_:id:metadata:)"),
                "debugBackend": .string("xcode-view-debugger"),
            ]),
        ])
    }

    private func swiftUIViewDebugHierarchySnapshot(maxDepth: Int?) -> JSONValue? {
        dispatchPrecondition(condition: .onQueue(.main))
        if let cached = cachedSwiftUIViewDebugSnapshot,
           cached.maxDepth == maxDepth,
           Date().timeIntervalSince(cached.capturedAt) < swiftUIViewDebugSnapshotCacheTTL
        {
            return cached.value
        }

        #if canImport(SwiftUI)
        if #available(iOS 13.0, *) {
            guard let snapshot = SwiftUIViewDebugHierarchySnapshotter().snapshot(maxDepth: maxDepth) else {
                return nil
            }
            cachedSwiftUIViewDebugSnapshot = (maxDepth, Date(), snapshot)
            return snapshot
        }
        #endif
        return nil
    }

    private func swiftUIViewDebugPayloadDiagnostics() -> JSONValue {
        #if canImport(SwiftUI)
        if #available(iOS 13.0, *) {
            return SwiftUIViewDebugHierarchySnapshotter().diagnostics()
        }
        #endif
        return .object(["available": .bool(false)])
    }

    private var latestPublishedHierarchySnapshot: PublishedHierarchySnapshot? {
        publishedHierarchySnapshots.values.sorted { lhs, rhs in
            lhs.publishedAt < rhs.publishedAt
        }.last
    }

    private func publishedHierarchySnapshot(source: String?) -> PublishedHierarchySnapshot? {
        let snapshots = publishedHierarchySnapshots.values
            .filter { published in
                guard let source, !source.isEmpty else {
                    return true
                }
                return published.source == source
            }
            .sorted { lhs, rhs in
                lhs.publishedAt < rhs.publishedAt
            }
        guard !snapshots.isEmpty else {
            return nil
        }
        if snapshots.count == 1 {
            return snapshots[0]
        }
        return Self.mergedPublishedHierarchySnapshots(snapshots)
    }

    private static func mergedPublishedHierarchySnapshots(_ snapshots: [PublishedHierarchySnapshot]) -> PublishedHierarchySnapshot? {
        guard let newest = snapshots.last else {
            return nil
        }
        var merged = newest.snapshot.objectValue ?? ["roots": newest.snapshot]
        let roots = snapshots.flatMap { snapshot -> [JSONValue] in
            snapshot.snapshot.objectValue?["roots"]?.arrayValue ?? [snapshot.snapshot]
        }
        merged["roots"] = .array(roots)
        merged["source"] = .string(newest.source)
        merged["capturedAt"] = .string(newest.publishedAt)
        return PublishedHierarchySnapshot(
            source: newest.source,
            snapshot: .object(merged),
            key: "\(newest.source):merged",
            publishedAt: newest.publishedAt
        )
    }

    private static func publishedHierarchyKey(source: String, snapshot: JSONValue) -> String {
        if let rootId = snapshot.objectValue?["roots"]?.arrayValue?.first?.objectValue?["id"]?.stringValue,
           !rootId.isEmpty
        {
            return "\(source):\(rootId)"
        }
        return "\(source):default"
    }

    private static func makePublishedHierarchySnapshot(
        source: String,
        snapshotJSON: String
    ) throws -> PublishedHierarchySnapshot {
        let data = Data(snapshotJSON.utf8)
        let snapshot = try JSONDecoder.simDeckInspector.decode(JSONValue.self, from: data)
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSource = source.isEmpty ? "app" : source
        return PublishedHierarchySnapshot(
            source: normalizedSource,
            snapshot: snapshot,
            key: publishedHierarchyKey(source: normalizedSource, snapshot: snapshot),
            publishedAt: iso8601Timestamp()
        )
    }

    private func refreshSwiftUIHierarchySnapshotsIfNeeded(source: String?) throws {
        let requestedSource = source?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard requestedSource == nil || requestedSource?.isEmpty == true || requestedSource == "swiftui" else {
            return
        }
        guard !swiftUIHierarchyPublishers.isEmpty else {
            return
        }

        let hasSwiftUISnapshot = publishedHierarchySnapshots.values.contains { $0.source == "swiftui" }
        let now = Date()
        if hasSwiftUISnapshot {
            let age = now.timeIntervalSince(lastSwiftUIHierarchyRefresh)
            let shouldRefresh = swiftUIHierarchyNeedsRefresh || age >= swiftUIHierarchyMaxRefreshInterval
            guard shouldRefresh, age >= swiftUIHierarchyMinRefreshInterval else {
                return
            }
            startBackgroundSwiftUIHierarchyRefresh()
            return
        }
        lastSwiftUIHierarchyRefresh = now

        let elementGeometry = swiftUIElementGeometrySnapshot()
        for publisher in swiftUIHierarchyPublishers.values.sorted(by: { $0.key < $1.key }) {
            let snapshotJSON = try publisher.snapshotProvider(elementGeometry)
            try publishHierarchySnapshot(source: publisher.source, snapshotJSON: snapshotJSON)
        }
        swiftUIHierarchyNeedsRefresh = false
    }

    private func startBackgroundSwiftUIHierarchyRefresh() {
        guard !swiftUIHierarchyRefreshInFlight else {
            return
        }
        swiftUIHierarchyRefreshInFlight = true
        let publishers = swiftUIHierarchyPublishers.values.sorted(by: { $0.key < $1.key })
        let elementGeometry = swiftUIElementGeometrySnapshot()
        let refreshGeneration = swiftUIHierarchyRefreshGeneration

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            defer {
                swiftUIHierarchyRefreshInFlight = false
            }
            do {
                let snapshots = try publishers.map { publisher in
                    try Self.makePublishedHierarchySnapshot(
                        source: publisher.source,
                        snapshotJSON: publisher.snapshotProvider(elementGeometry)
                    )
                }
                for snapshot in snapshots {
                    publishedHierarchySnapshots[snapshot.key] = snapshot
                }
                if swiftUIHierarchyRefreshGeneration == refreshGeneration {
                    swiftUIHierarchyNeedsRefresh = false
                }
                lastSwiftUIHierarchyRefresh = Date()
            } catch {
                NSLog("SimDeck SwiftUI hierarchy refresh failed: \(error)")
            }
        }
    }

    private func markSwiftUIHierarchyNeedsRefresh() {
        swiftUIHierarchyNeedsRefresh = true
        swiftUIHierarchyRefreshGeneration &+= 1
    }

    private static func swiftUIElementGeometryKey(for payload: SimDeckInspectorTagPayload) -> String? {
        let id = payload.id?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id, !id.isEmpty {
            return id
        }
        let name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private static func geometryFrame(_ lhs: CGRect, isApproximatelyEqualTo rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 0.5
            && abs(lhs.origin.y - rhs.origin.y) < 0.5
            && abs(lhs.size.width - rhs.size.width) < 0.5
            && abs(lhs.size.height - rhs.size.height) < 0.5
    }

    private static func iso8601Timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func enrichPublishedHierarchySnapshot(_ published: PublishedHierarchySnapshot) throws -> JSONValue {
        let screen = UIScreen.main
        let bundle = Bundle.main
        var object = published.snapshot.objectValue ?? [
            "roots": published.snapshot,
        ]
        object["source"] = object["source"] ?? .string(published.source)
        object["protocolVersion"] = object["protocolVersion"] ?? .string(InspectorProtocol.version)
        object["capturedAt"] = object["capturedAt"] ?? .string(published.publishedAt)
        object["processIdentifier"] = object["processIdentifier"] ?? .number(Double(ProcessInfo.processInfo.processIdentifier))
        object["bundleIdentifier"] = object["bundleIdentifier"] ?? .string(bundle.bundleIdentifier ?? "")
        object["displayScale"] = object["displayScale"] ?? .number(Double(screen.scale))
        object["coordinateSpace"] = object["coordinateSpace"] ?? .string("screen-points")
        return .object(object)
    }

    private func emptyPublishedHierarchySnapshot(source: String) throws -> JSONValue {
        let screen = UIScreen.main
        let bundle = Bundle.main
        return .object([
            "protocolVersion": .string(InspectorProtocol.version),
            "capturedAt": .string(Self.iso8601Timestamp()),
            "processIdentifier": .number(Double(ProcessInfo.processInfo.processIdentifier)),
            "bundleIdentifier": .string(bundle.bundleIdentifier ?? ""),
            "displayScale": .number(Double(screen.scale)),
            "coordinateSpace": .string("screen-points"),
            "source": .string(source),
            "roots": .array([]),
        ])
    }

    private func describe(view: UIView) throws -> JSONValue {
        var ancestors: [JSONValue] = []
        var current: UIView? = view
        while let item = current {
            ancestors.append(try simDeckJSONValue(snapshotter.node(for: item, includeHidden: true, maxDepth: 0, depth: 0)))
            current = item.superview
        }

        return .object([
            "view": try simDeckJSONValue(snapshotter.node(for: view, includeHidden: true, maxDepth: 2, depth: 0)),
            "ancestors": .array(ancestors),
        ])
    }

    private func point(in params: [String: JSONValue]) throws -> CGPoint {
        guard let x = params.double("x"), let y = params.double("y") else {
            throw InspectorFailure.invalidRequest("Point requests require numeric params.x and params.y in screen points.")
        }
        return CGPoint(x: x, y: y)
    }

    private func requiredString(_ key: String, in params: [String: JSONValue]) throws -> String {
        guard let value = params.string(key), !value.isEmpty else {
            throw InspectorFailure.invalidRequest("Request params.\(key) must be a non-empty string.")
        }
        return value
    }
}

private struct PublishedHierarchySnapshot {
    var source: String
    var snapshot: JSONValue
    var key: String
    var publishedAt: String
}

private struct SwiftUIHierarchyPublisher {
    var source: String
    var key: String
    var snapshotProvider: ([String: SimDeckInspectorAgent.SwiftUIElementGeometry]) throws -> String
    var registeredAt: String
}
