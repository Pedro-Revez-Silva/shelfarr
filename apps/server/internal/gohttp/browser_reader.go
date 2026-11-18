package gohttp

import (
	"net/http"
	"slices"
	"strings"
	"unicode"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/consumer"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/live"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/media"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

var (
	textReaderFormats = []string{"epub"}
	pageReaderFormats = []string{"cbz", "epub", "pdf"}
)

type readerAsset struct {
	ID              string `json:"id"`
	Filename        string `json:"filename"`
	Format          string `json:"format"`
	MediaType       string `json:"media_type"`
	SizeBytes       int64  `json:"size_bytes"`
	Position        int    `json:"position"`
	URL             string `json:"url"`
	PageCount       *int   `json:"page_count,omitempty"`
	ReadingOrderURL string `json:"reading_order_url,omitempty"`
}

type readerPublication struct {
	ID            string             `json:"id"`
	Title         string             `json:"title"`
	Author        *string            `json:"author"`
	BookType      string             `json:"book_type"`
	ContentKind   string             `json:"content_kind"`
	ReadingStatus string             `json:"reading_status"`
	Assets        []readerAsset      `json:"assets"`
	OtherFormats  []string           `json:"other_formats"`
	Progress      *consumer.Progress `json:"progress"`
}

func (a *App) readerInstalled() bool {
	return a.web != nil && a.web.bundle.ReaderEngine() != ""
}

func (a *App) pagesInstalled() bool {
	return a.readerInstalled() && a.web.bundle.PageEngine() != nil
}

func (a *App) browserFormats() []string {
	if a.pagesInstalled() {
		return pageReaderFormats
	}
	return textReaderFormats
}

func setBrowserMediaPrivacy(header http.Header) {
	header.Set("Cache-Control", "private, no-store")
	header.Set("Cross-Origin-Resource-Policy", "same-origin")
	header.Set("Referrer-Policy", "no-referrer")
}

func sameOriginFetch(r *http.Request) bool {
	sites := r.Header.Values("Sec-Fetch-Site")
	if len(sites) == 0 {
		return true
	}
	return len(sites) == 1 && (sites[0] == "same-origin" || sites[0] == "none")
}

func browserReadable(formats []string, format, mediaType string) bool {
	return slices.Contains(formats, format) || strings.HasPrefix(mediaType, "audio/")
}

func browserMediaPath(account, bookID, assetID string) string {
	return webAPI + "/accounts/" + account + "/library/" + bookID + "/assets/" + assetID
}

func browserReadingOrderPath(bookID, assetID string) string {
	return webAPI + "/library/" + bookID + "/assets/" + assetID + "/reading_order"
}

func readerView(item consumer.Publication, account string, formats []string) readerPublication {
	kind := "book"
	if item.ContentKind != nil {
		kind = *item.ContentKind
	}
	author := item.Author
	if author != nil && strings.TrimFunc(*author, unicode.IsSpace) == "" {
		author = nil
	}
	view := readerPublication{
		ID: item.ID, Title: item.Title, Author: author, BookType: item.BookType, ContentKind: kind, ReadingStatus: item.ReadingStatus,
		Assets: []readerAsset{}, OtherFormats: []string{}, Progress: item.Progress,
	}
	for _, asset := range item.Assets {
		if !browserReadable(formats, asset.Format, asset.MediaType) {
			if !slices.Contains(view.OtherFormats, asset.Format) {
				view.OtherFormats = append(view.OtherFormats, asset.Format)
			}
			continue
		}
		described := readerAsset{
			ID: asset.ID, Filename: asset.Filename, Format: asset.Format, MediaType: asset.MediaType, SizeBytes: asset.SizeBytes,
			Position: asset.Position, URL: browserMediaPath(account, item.ID, asset.ID),
		}
		if asset.Format == "cbz" {
			described.PageCount, described.ReadingOrderURL = asset.PageCount, browserReadingOrderPath(item.ID, asset.ID)
		}
		view.Assets = append(view.Assets, described)
	}
	slices.Sort(view.OtherFormats)
	return view
}

func (a *App) webReader(w http.ResponseWriter, r *http.Request, session browserSession, rawID string, result *outcome) {
	book, ok := a.webBook(w, r, rawID, result)
	if !ok {
		return
	}
	items, err := a.webPublications(r, session.user.ID, []store.Book{*book})
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, map[string]any{"account": session.account(), "publication": readerView(items[0], session.account(), a.browserFormats())})
}

func (a *App) webProgress(w http.ResponseWriter, r *http.Request, session browserSession, rawID string, result *outcome) {
	if r.Method == http.MethodPut {
		saved, ok := a.saveCheckpoint(w, r, session.user.ID, rawID, result)
		if !ok {
			return
		}
		if saved.Outcome == live.ProgressConflict {
			a.respondStoredFor(w, result, http.StatusConflict, "progress_conflict", saved.Progress, session.account())
			return
		}
		a.respondStoredFor(w, result, http.StatusOK, "", saved.Progress, session.account())
		return
	}
	book, ok := a.webBook(w, r, rawID, result)
	if !ok {
		return
	}
	stored, err := a.db.ProgressFor(r.Context(), session.user.ID, []int64{book.ID})
	if err != nil {
		mapFailure(w, result, err)
		return
	}
	var current *store.Progress
	if progress, present := stored[book.ID]; present {
		current = &progress
	}
	a.respondStoredFor(w, result, http.StatusOK, "", current, session.account())
}

func (a *App) webMedia(w http.ResponseWriter, r *http.Request, found route, result *outcome) {
	formats := a.browserFormats()
	book, chosen, ok := a.findAsset(w, r, found, formats, result)
	if !ok {
		return
	}
	if !browserReadable(formats, chosen.Format, chosen.MediaType) {
		problem(w, result, http.StatusGone, "asset_unavailable")
		return
	}
	file, ok := a.openAsset(w, result, *book, *chosen)
	if !ok {
		return
	}
	defer file.Close()
	disposition := "inline"
	if fixedLayout(chosen.Format) {
		disposition = "attachment"
	}
	result.set(http.StatusOK, "")
	media.Serve(w, r, file, media.Asset{ID: chosen.ID, Filename: chosen.Filename, MediaType: chosen.MediaType, Size: chosen.SizeBytes, Disposition: disposition, ContentSecurityPolicy: documentPolicy}, a.config.StreamWriteStall)
}

type browserReadingOrder struct {
	Account string `json:"account"`
	readingOrderBody
}

func (a *App) webReadingOrder(w http.ResponseWriter, r *http.Request, session browserSession, found route, result *outcome) {
	order, ok := a.comicOrder(w, r, found, result)
	if !ok {
		return
	}
	result.set(http.StatusOK, "")
	writeJSON(w, http.StatusOK, browserReadingOrder{Account: session.account(), readingOrderBody: order})
}
