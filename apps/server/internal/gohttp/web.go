package gohttp

import (
	"encoding/json"
	"html"
	"net/http"
	"strconv"
	"strings"

	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/webassets"
)

const (
	webMount         = "/preview"
	webAPI           = "/preview/api/v1"
	webLibraryPath   = "/preview/library"
	webAssetsPrefix  = "/preview/assets/"
	webConnectPath   = "/consumer/connect"
	webBootVersion   = 1
	webContentPolicy = "default-src 'none'; script-src 'self'; style-src 'self'; font-src 'self'; img-src 'self' https:; connect-src 'self'; manifest-src 'none'; form-action 'none'; base-uri 'none'; frame-ancestors 'self'; object-src 'none'"
	readerPolicy     = "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline' blob:; font-src 'self' blob: data:; img-src 'self' https: blob: data:; media-src 'self'; connect-src 'self'; frame-src 'self'; manifest-src 'none'; form-action 'none'; base-uri 'self'; frame-ancestors 'self'; object-src 'none'"
	readerSuffix     = "/read"
)

type webView string

const (
	viewLibrary webView = "library"
	viewDetails webView = "details"
	viewConnect webView = "connect"
	viewReader  webView = "reader"
)

var webTitles = map[webView]string{
	viewLibrary: "Library · Shelfarr",
	viewDetails: "Book · Shelfarr",
	viewConnect: "Connect an app · Shelfarr",
	viewReader:  "Reader · Shelfarr",
}

type webUI struct {
	bundle *webassets.Bundle
	shells map[webView][]byte
}

type webBoot struct {
	Version       int             `json:"version"`
	Runtime       string          `json:"runtime"`
	View          string          `json:"view"`
	Mount         string          `json:"mount"`
	API           string          `json:"api"`
	ReaderEngine  string          `json:"reader_engine,omitempty"`
	ReaderFormats []string        `json:"reader_formats,omitempty"`
	PageEngine    *pageEngineBoot `json:"page_engine,omitempty"`
}

type pageEngineBoot struct {
	Engine string                       `json:"engine"`
	Worker string                       `json:"worker"`
	Files  map[string]map[string]string `json:"files"`
}

func describePageEngine(engine *webassets.PageEngine) *pageEngineBoot {
	files := make(map[string]map[string]string, len(engine.Resources))
	for kind, names := range engine.Resources {
		files[kind] = make(map[string]string, len(names))
		for logical, stored := range names {
			files[kind][logical] = webAssetsPrefix + stored
		}
	}
	return &pageEngineBoot{Engine: webAssetsPrefix + engine.Engine, Worker: webAssetsPrefix + engine.Worker, Files: files}
}

func newWebUI(bundle *webassets.Bundle) (*webUI, error) {
	ui := &webUI{bundle: bundle, shells: map[webView][]byte{}}
	formats := []string(nil)
	if bundle.ReaderEngine() != "" {
		formats = textReaderFormats
		if bundle.PageEngine() != nil {
			formats = pageReaderFormats
		}
	}
	for view, title := range webTitles {
		described := webBoot{Version: webBootVersion, Runtime: "go", View: string(view), Mount: webMount, API: webAPI, ReaderFormats: formats}
		if view == viewReader {
			if bundle.ReaderEngine() == "" {
				continue
			}
			described.ReaderEngine = webAssetsPrefix + bundle.ReaderEngine()
			if engine := bundle.PageEngine(); engine != nil {
				described.PageEngine = describePageEngine(engine)
			}
		}
		boot, err := json.Marshal(described)
		if err != nil {
			return nil, err
		}
		ui.shells[view] = []byte(shellDocument(title, bundle, string(boot)))
	}
	return ui, nil
}

func shellDocument(title string, bundle *webassets.Bundle, boot string) string {
	var document strings.Builder
	document.WriteString("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>")
	document.WriteString(html.EscapeString(title))
	document.WriteString("</title>\n<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,viewport-fit=cover\">\n")
	document.WriteString("<meta name=\"color-scheme\" content=\"light dark\">\n<meta name=\"robots\" content=\"noindex\">\n")
	document.WriteString("<meta name=\"theme-color\" media=\"(prefers-color-scheme: light)\" content=\"#FBF7F0\">\n")
	document.WriteString("<meta name=\"theme-color\" media=\"(prefers-color-scheme: dark)\" content=\"#16130F\">\n")
	document.WriteString("<link rel=\"stylesheet\" href=\"" + webAssetsPrefix + html.EscapeString(bundle.Style()) + "\">\n")
	document.WriteString("<script type=\"module\" src=\"" + webAssetsPrefix + html.EscapeString(bundle.Script()) + "\"></script>\n</head>\n")
	document.WriteString("<body class=\"web-preview\">\n<div id=\"root\"><p class=\"boot-message\" role=\"status\">Loading Shelfarr…</p></div>\n")
	document.WriteString("<noscript><p class=\"boot-message\">Shelfarr's browser screens need JavaScript. Turn it on for this site and reload; nothing has been changed.</p></noscript>\n")
	document.WriteString("<script type=\"application/json\" id=\"shelfarr-boot\">" + boot + "</script>\n</body>\n</html>\n")
	return document.String()
}

func classifyWeb(method, path string) (route, bool) {
	var found route
	switch {
	case path == webMount:
		found = route{kind: routeWebIndex, name: "web_index"}
	case path == webLibraryPath:
		found = route{kind: routeWebShell, name: "web_library", id: string(viewLibrary)}
	case strings.HasPrefix(path, webLibraryPath+"/") && bookID.MatchString(strings.TrimPrefix(path, webLibraryPath+"/")):
		found = route{kind: routeWebShell, name: "web_details", id: string(viewDetails)}
	case strings.HasPrefix(path, webLibraryPath+"/") && strings.HasSuffix(path, readerSuffix) && bookID.MatchString(strings.TrimSuffix(strings.TrimPrefix(path, webLibraryPath+"/"), readerSuffix)):
		found = route{kind: routeWebShell, name: "web_reader", id: string(viewReader)}
	case path == webConnectPath:
		found = route{kind: routeWebShell, name: "web_connect", id: string(viewConnect)}
	case strings.HasPrefix(path, webAssetsPrefix) && !strings.Contains(strings.TrimPrefix(path, webAssetsPrefix), "/"):
		found = route{kind: routeWebAsset, name: "web_asset", id: strings.TrimPrefix(path, webAssetsPrefix)}
	default:
		return route{}, false
	}
	found.web = true
	if method != http.MethodGet && method != http.MethodHead {
		return route{kind: routeWrongMethod, name: found.name, allow: "GET, HEAD", web: true}, true
	}
	return found, true
}

func (a *App) serveWeb(w http.ResponseWriter, r *http.Request, found route, result *outcome) {
	if found.kind == routeWebAsset && !a.web.bundle.Has(found.id) {
		w.Header().Set("Cache-Control", "private, no-store")
		problem(w, result, http.StatusNotFound, "not_found")
		return
	}
	switch found.kind {
	case routeWebIndex:
		w.Header().Set("Cache-Control", "private, no-store")
		w.Header().Set("Location", webLibraryPath)
		result.set(http.StatusSeeOther, "")
		w.WriteHeader(http.StatusSeeOther)
	case routeWebAsset:
		result.set(http.StatusOK, "")
		a.web.bundle.Serve(w, r, found.id)
	case routeWebShell:
		w.Header().Set("Cache-Control", "private, no-store")
		if _, served := a.web.shells[webView(found.id)]; !served {
			problem(w, result, http.StatusNotFound, "not_found")
			return
		}
		a.writeShell(w, r, webView(found.id), result)
	}
}

func (a *App) writeShell(w http.ResponseWriter, r *http.Request, view webView, result *outcome) {
	header := w.Header()
	header.Set("Content-Type", "text/html; charset=utf-8")
	policy := webContentPolicy
	if view == viewReader {
		policy = readerPolicy
	}
	header.Set("Content-Security-Policy", policy)
	header.Set("Cross-Origin-Opener-Policy", "same-origin")
	header.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=()")
	if view == viewConnect {
		header.Set("Referrer-Policy", "no-referrer")
	}
	body := a.web.shells[view]
	header.Set("Content-Length", strconv.Itoa(len(body)))
	result.set(http.StatusOK, "")
	w.WriteHeader(http.StatusOK)
	if r.Method != http.MethodHead {
		w.Write(body)
	}
}
