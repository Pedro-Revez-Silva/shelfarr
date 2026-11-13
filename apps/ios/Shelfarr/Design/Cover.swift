import ShelfarrCore
import SwiftUI
import UIKit

/// Fetches covers through the API client, so a token only reaches the configured
/// server. Anything that fails simply leaves the generated cover showing.
@MainActor
final class CoverLoader: ObservableObject {
    private static let cache = NSCache<NSURL, UIImage>()

    @Published private(set) var image: UIImage?
    private var loaded: URL?

    func load(_ url: URL?, api: ConsumerAPI) async {
        guard let url, url != loaded else { return }
        loaded = url
        if let cached = Self.cache.object(forKey: url as NSURL) {
            image = cached
            return
        }
        guard let data = try? await api.data(from: url), let decoded = UIImage(data: data) else { return }
        Self.cache.setObject(decoded, forKey: url as NSURL)
        image = decoded
    }

    static func clearCache() {
        cache.removeAllObjects()
    }
}

/// A publication's jacket. Audiobooks are square and every cover sits on the same
/// baseline, the way things stand on a shelf.
struct BookCover: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var loader = CoverLoader()

    let publication: ShelfarrCore.Publication
    var corner: CGFloat = 4

    private var url: URL? {
        guard let reference = publication.coverUrl else { return nil }
        return model.session?.server.resolve(reference)
    }

    var body: some View {
        GeneratedCover(publication: publication)
            .overlay {
                if let image = loader.image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .aspectRatio(publication.bookType == .audiobook ? 1 : 2.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            .accessibilityHidden(true)
            .task(id: url) { await loader.load(url, api: model.api) }
    }
}

/// A cover set in type on a muted cloth colour. The colour follows the id, on every client.
struct GeneratedCover: View {
    let publication: ShelfarrCore.Publication

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let unit = width / 12
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(Palette.coverInk.opacity(0.7)).frame(width: unit * 1.6, height: 1)
                Text(publication.title)
                    .font(.custom("NewsreaderDisplay-Medium", fixedSize: min(max(width * 0.125, 10), 34)))
                    .foregroundStyle(Palette.coverInk)
                    .lineLimit(5)
                    .padding(.top, unit * 0.7)
                Spacer(minLength: 0)
                if let author = publication.author, !author.isEmpty {
                    Text(author)
                        .font(.system(size: min(max(width * 0.07, 7), 15), weight: .medium))
                        .foregroundStyle(Palette.coverInk.opacity(0.82))
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, unit)
            .padding(.vertical, unit * 1.1)
            .frame(width: width, height: geometry.size.height, alignment: .topLeading)
        }
        .background(Palette.coverSwatches[coverSwatchIndex(publication.id)])
    }
}

/// One book on a shelf: jacket on the baseline, then title and author.
struct ShelfItem: View {
    let publication: ShelfarrCore.Publication
    var square = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(square ? 1 : 2.0 / 3.0, contentMode: .fit)
                .overlay(alignment: .bottom) {
                    BookCover(publication: publication)
                        .overlay(alignment: .bottomTrailing) {
                            if publication.bookType == .audiobook {
                                Image(systemName: "headphones")
                                    .font(.caption2)
                                    .padding(4)
                                    .background(Palette.background.opacity(0.92), in: RoundedRectangle(cornerRadius: 6))
                                    .foregroundStyle(Palette.ink)
                                    .padding(5)
                            }
                        }
                }
            if let fraction = publication.progressFraction {
                ProgressRule(fraction: fraction).padding(.top, 6)
            }
            Text(publication.title)
                .font(Typeface.serifBold(15))
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
                .padding(.top, 8)
            if let author = publication.author {
                Text(author).font(.footnote).foregroundStyle(Palette.inkMuted).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
