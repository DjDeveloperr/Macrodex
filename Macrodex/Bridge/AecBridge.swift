import Foundation

final class AecBridge: @unchecked Sendable {
    private let processorLock = NSLock()
    private var renderTail: [Float] = []
    private var captureTail: [Float] = []
    private var hasRenderReference = false

    let frameSize: Int

    init?(sampleRate: UInt32) {
        self.frameSize = max(Int(sampleRate / 100), 1)
    }

    func analyzeRender(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        processorLock.lock()
        defer { processorLock.unlock() }

        var pending = renderTail
        pending.append(contentsOf: samples)

        let processCount = pending.count / frameSize * frameSize
        if processCount > 0 {
            hasRenderReference = true
        }

        renderTail = processCount == pending.count ? [] : Array(pending[processCount...])
    }

    func processCapture(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }

        processorLock.lock()
        defer { processorLock.unlock() }

        var pending = captureTail
        pending.append(contentsOf: samples)

        let processCount = pending.count / frameSize * frameSize
        captureTail = processCount == pending.count ? [] : Array(pending[processCount...])

        guard processCount > 0 else {
            return []
        }

        let processBuffer = Array(pending[..<processCount])
        guard hasRenderReference else {
            return processBuffer
        }

        return processBuffer
    }
}
