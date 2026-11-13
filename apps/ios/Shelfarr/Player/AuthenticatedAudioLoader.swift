import AVFoundation
import Foundation
import ShelfarrCore
import UniformTypeIdentifiers

/// Streams an authenticated file into AVFoundation.
///
/// AVPlayer has no supported way to add a bearer header, so the asset uses a private
/// URL scheme and every byte range is fetched here through the API client. That keeps
/// the token in a request header and behind the same redirect checks as everything else.
final class AuthenticatedAudioLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "shelfarr-audio"
    private static let chunkSize: Int64 = 1 << 20

    private let source: URL
    private let api: ConsumerAPI
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var totalLength: Int64?
    private var contentType: String?

    let queue = DispatchQueue(label: "org.shelfarr.audio-loader")

    init(source: URL, api: ConsumerAPI) {
        self.source = source
        self.api = api
    }

    /// The URL to hand to `AVURLAsset`. It carries no credential.
    var assetURL: URL {
        var components = URLComponents(url: source, resolvingAgainstBaseURL: false)
        components?.scheme = Self.scheme
        return components?.url ?? source
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let key = ObjectIdentifier(loadingRequest)
        let task = Task { [weak self] in
            await self?.serve(loadingRequest)
            self?.lock.withLock { self?.tasks[key] = nil }
        }
        lock.withLock { tasks[key] = task }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        lock.withLock { tasks.removeValue(forKey: ObjectIdentifier(loadingRequest)) }?.cancel()
    }

    func cancelAll() {
        lock.withLock {
            tasks.values.forEach { $0.cancel() }
            tasks.removeAll()
        }
    }

    private func serve(_ request: AVAssetResourceLoadingRequest) async {
        do {
            if let information = request.contentInformationRequest {
                try await fillInformation(information)
            }
            if let data = request.dataRequest {
                try await stream(data)
            }
            if !Task.isCancelled { request.finishLoading() }
        } catch {
            if !Task.isCancelled { request.finishLoading(with: error) }
        }
    }

    private func fillInformation(_ information: AVAssetResourceLoadingContentInformationRequest) async throws {
        if totalLength == nil { _ = try await fetch(0 ... 1) }
        information.isByteRangeAccessSupported = true
        information.contentLength = totalLength ?? 0
        information.contentType = contentType
    }

    private func stream(_ request: AVAssetResourceLoadingDataRequest) async throws {
        var offset = request.currentOffset
        if totalLength == nil { _ = try await fetch(0 ... 1) }
        let total = totalLength ?? 0
        let end = request.requestsAllDataToEndOfResource
            ? total
            : min(request.requestedOffset + Int64(request.requestedLength), total)

        while offset < end {
            try Task.checkCancellation()
            let last = min(offset + Self.chunkSize, end) - 1
            let data = try await fetch(offset ... last)
            if data.isEmpty { break }
            request.respond(with: data)
            offset += Int64(data.count)
        }
    }

    private func fetch(_ range: ClosedRange<Int64>) async throws -> Data {
        let (data, response) = try await api.bytes(at: source, range: range)
        if totalLength == nil {
            if let header = response.value(forHTTPHeaderField: "Content-Range"),
               let total = header.split(separator: "/").last.flatMap({ Int64($0) }) {
                totalLength = total
            } else {
                totalLength = Int64(data.count)
            }
            let mime = response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first.map(String.init)
            contentType = mime.flatMap { UTType(mimeType: $0)?.identifier } ?? UTType.audio.identifier
        }
        return data
    }
}
