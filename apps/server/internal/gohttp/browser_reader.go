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

var browserReadableFormats = []string{"epub"}

type readerAsset struct {
	ID        string `json:"id"`
	Filename  string `json:"filename"`
	Format    string `json:"format"`
	MediaType string `json:"media_type"`
	SizeBytes int64  `json:"size_bytes"`
	Position  int    `json:"position"`
	URL       string `json:"url"`
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

func browserReadable(format, mediaType string) bool {
	return slices.Contains(browserReadableFormats, format) || strings.HasPrefix(mediaType, "audio/")
}

func browserMediaPath(account, bookID, assetID string) string {
	return webAPI + "/accounts/" + account + "/library/" + bookID + "/assets/" + assetID
}

func readerView(item consumer.Publication, account string) readerPublication {
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
		if !browserReadable(asset.Format, asset.MediaType) {
			if !slices.Contains(view.OtherFormats, asset.Format) {
				view.OtherFormats = append(view.OtherFormats, asset.Format)
			}
			continue
		}
		view.Assets = append(view.Assets, readerAsset{
			ID: asset.ID, Filename: asset.Filename, Format: asset.Format, MediaType: asset.MediaType, SizeBytes: asset.SizeBytes,
			Position: asset.Position, URL: browserMediaPath(account, item.ID, asset.ID),
		})
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
	writeJSON(w, http.StatusOK, map[string]any{"account": session.account(), "publication": readerView(items[0], session.account())})
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
	book, chosen, ok := a.findAsset(w, r, found, browserReadableFormats, result)
	if !ok {
		return
	}
	if !browserReadable(chosen.Format, chosen.MediaType) {
		problem(w, result, http.StatusGone, "asset_unavailable")
		return
	}
	file, ok := a.openAsset(w, result, *book, *chosen)
	if !ok {
		return
	}
	defer file.Close()
	result.set(http.StatusOK, "")
	media.Serve(w, r, file, media.Asset{ID: chosen.ID, Filename: chosen.Filename, MediaType: chosen.MediaType, Size: chosen.SizeBytes, Disposition: "inline", ContentSecurityPolicy: documentPolicy}, a.config.StreamWriteStall)
}
