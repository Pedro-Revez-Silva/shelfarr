package gohttp

import (
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strconv"
	"time"
)

//go:embed offline_worker.js
var offlineWorkerSource string

const (
	offlineWorkerPath  = "/preview/offline-worker.js"
	offlineScope       = webLibraryPath + "/"
	webDownloadsPath   = webLibraryPath + "/downloads"
	offlineWindowLimit = 30 * 24 * time.Hour
	workerPolicy       = "default-src 'none'; connect-src 'self'"
)

type offlineBoot struct {
	Worker    string `json:"worker"`
	Scope     string `json:"scope"`
	Downloads string `json:"downloads"`
}

type workerShell struct {
	Body    string            `json:"body"`
	Headers map[string]string `json:"headers"`
}

type workerAsset struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
}

type workerConfig struct {
	Version   string                 `json:"version"`
	Library   string                 `json:"library"`
	Downloads string                 `json:"downloads"`
	Assets    []workerAsset          `json:"assets"`
	Shells    map[string]workerShell `json:"shells"`
}

func (a *App) offlineEnabled() bool { return a.web != nil && a.web.worker != nil }

func offlineWindow(expires, now time.Time) int {
	return int(min(max(expires.Sub(now), 0), offlineWindowLimit) / time.Second)
}

func shellHeaders(view webView) map[string]string {
	headers := map[string]string{
		"Content-Type":               "text/html; charset=utf-8",
		"Content-Security-Policy":    webContentPolicy,
		"Cross-Origin-Opener-Policy": "same-origin",
		"Permissions-Policy":         "camera=(), microphone=(), geolocation=(), payment=()",
	}
	if view == viewReader {
		headers["Content-Security-Policy"] = readerPolicy
	}
	if view == viewConnect {
		headers["Referrer-Policy"] = "no-referrer"
	}
	return headers
}

func offlineShell(ui *webUI, view webView) workerShell {
	headers := shellHeaders(view)
	headers["Cache-Control"] = "private, no-store"
	headers["X-Content-Type-Options"] = "nosniff"
	headers["X-Frame-Options"] = "SAMEORIGIN"
	if _, set := headers["Referrer-Policy"]; !set {
		headers["Referrer-Policy"] = "same-origin"
	}
	return workerShell{Body: string(ui.shells[view]), Headers: headers}
}

func offlineWorker(ui *webUI) ([]byte, error) {
	config := workerConfig{
		Library: webLibraryPath, Downloads: webDownloadsPath, Assets: []workerAsset{},
		Shells: map[string]workerShell{"downloads": offlineShell(ui, viewDownloads), "reader": offlineShell(ui, viewReader)},
	}
	for _, file := range ui.bundle.Listed() {
		config.Assets = append(config.Assets, workerAsset{Path: webAssetsPrefix + file.Name, SHA256: file.SHA256})
	}
	described, err := json.Marshal(config)
	if err != nil {
		return nil, err
	}
	digest := sha256.Sum256(append(described, offlineWorkerSource...))
	config.Version = hex.EncodeToString(digest[:])[:24]
	if described, err = json.Marshal(config); err != nil {
		return nil, err
	}
	return []byte("self.SHELFARR_GO_OFFLINE = " + string(described) + ";\n" + offlineWorkerSource), nil
}

func (a *App) serveOfflineWorker(w http.ResponseWriter, r *http.Request, result *outcome) {
	if !a.offlineEnabled() {
		w.Header().Set("Cache-Control", "private, no-store")
		problem(w, result, http.StatusNotFound, "not_found")
		return
	}
	header := w.Header()
	header.Set("Content-Type", "text/javascript; charset=utf-8")
	header.Set("Cache-Control", "no-cache")
	header.Set("Content-Security-Policy", workerPolicy)
	header.Set("Cross-Origin-Resource-Policy", "same-origin")
	header.Set("Content-Length", strconv.Itoa(len(a.web.worker)))
	result.set(http.StatusOK, "")
	w.WriteHeader(http.StatusOK)
	if r.Method != http.MethodHead {
		w.Write(a.web.worker)
	}
}
