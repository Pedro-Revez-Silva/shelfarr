package gohttp

import (
	"net/http"
	"slices"
	"strings"
)

const (
	apiPrefix     = "/api/consumer/v1/"
	previewPrefix = "/preview/api/v1/"
)

type routeKind int

const (
	routeNone routeKind = iota
	routeUp
	routeReady
	routeServer
	routeMe
	routeContinue
	routeLibrary
	routePublication
	routeProgress
	routeReadingStatus
	routeAsset
	routeReadingOrder
	routeTransferGrant
	routeTransfer
	routeExcluded
	routeWrongMethod
	routeBrowserSession
	routeBrowserLibrary
	routeBrowserContinue
	routeBrowserPublication
	routeBrowserStatus
	routeBrowserReader
	routeBrowserProgress
	routeBrowserMedia
	routeBrowserReadingOrder
	routeBrowserAccount
	routeBrowserProfile
	routeBrowserPassword
	routeAuthBootstrap
	routeAuthLogin
	routeAuthLogout
	routeAuthDevice
	routeAuthToken
	routeAuthRevoke
	routeBrowserConnect
	routeBrowserDecide
	routeWebIndex
	routeWebShell
	routeWebAsset
)

type route struct {
	kind    routeKind
	name    string
	id      string
	assetID string
	account string
	allow   string
	web     bool
}

type excludedRoute struct {
	Method  string
	Pattern string
	Reason  string
}

var ExcludedRoutes = []excludedRoute{
	{http.MethodGet, "discover", "requests and acquisition"},
	{http.MethodGet, "requests", "requests and acquisition"},
	{http.MethodPost, "requests", "requests and acquisition"},
	{http.MethodGet, "requests/{id}", "requests and acquisition"},
	{http.MethodDelete, "requests/{id}", "requests and acquisition"},
	{http.MethodGet, "library/{id}/assets/{asset}/read_along", "read-along"},
	{http.MethodGet, "library/{id}/assets/{asset}/read_along/resources/{path...}", "read-along"},
	{http.MethodGet, "library/{id}/assets/{asset}/read_along/audio/{audio}", "read-along"},
}

func segmentOK(segment string) bool {
	return segment != "" && !strings.ContainsAny(segment, ".?")
}

func matchPattern(pattern string, segments []string) bool {
	parts := strings.Split(pattern, "/")
	for index, part := range parts {
		if strings.HasSuffix(part, "...}") {
			return len(segments) > index && segments[index] != ""
		}
		if index >= len(segments) {
			return false
		}
		if strings.HasPrefix(part, "{") {
			if !segmentOK(segments[index]) {
				return false
			}
			continue
		}
		if part != segments[index] {
			return false
		}
	}
	return len(parts) == len(segments)
}

func classify(method, path string) route {
	switch path {
	case "/up":
		return supported(method, route{kind: routeUp, name: "up"})
	case "/readyz":
		return supported(method, route{kind: routeReady, name: "readyz"})
	}
	if found, web := classifyWeb(method, path); web {
		return found
	}
	if strings.HasPrefix(path, previewPrefix) {
		return classifyPreview(method, strings.TrimPrefix(path, previewPrefix))
	}
	if !strings.HasPrefix(path, apiPrefix) {
		return route{kind: routeNone}
	}
	rest := strings.TrimPrefix(path, apiPrefix)
	segments := strings.Split(rest, "/")
	switch {
	case rest == "server.json":
		return supported(method, route{kind: routeServer, name: "server"})
	case rest == "me":
		return supported(method, route{kind: routeMe, name: "me"})
	case rest == "auth/device":
		return posted(method, route{kind: routeAuthDevice, name: "auth_device"})
	case rest == "auth/token":
		return posted(method, route{kind: routeAuthToken, name: "auth_token"})
	case rest == "auth/revoke":
		return posted(method, route{kind: routeAuthRevoke, name: "auth_revoke"})
	case rest == "continue":
		return supported(method, route{kind: routeContinue, name: "continue"})
	case rest == "library":
		return supported(method, route{kind: routeLibrary, name: "library"})
	case len(segments) == 2 && segments[0] == "library" && segmentOK(segments[1]):
		return supported(method, route{kind: routePublication, name: "publication", id: segments[1]})
	case len(segments) == 3 && segments[0] == "library" && segments[2] == "progress" && segmentOK(segments[1]):
		return served(method, route{kind: routeProgress, name: "progress", id: segments[1]}, http.MethodGet, http.MethodHead, http.MethodPut)
	case len(segments) == 3 && segments[0] == "library" && segments[2] == "reading_status" && segmentOK(segments[1]):
		return served(method, route{kind: routeReadingStatus, name: "reading_status", id: segments[1]}, http.MethodPut)
	case len(segments) == 4 && segments[0] == "library" && segments[2] == "assets" && segmentOK(segments[1]) && segmentOK(segments[3]):
		return supported(method, route{kind: routeAsset, name: "asset", id: segments[1], assetID: segments[3]})
	case len(segments) == 5 && segments[0] == "library" && segments[2] == "assets" && segments[4] == "reading_order" && segmentOK(segments[1]) && segmentOK(segments[3]):
		return supported(method, route{kind: routeReadingOrder, name: "reading_order", id: segments[1], assetID: segments[3]})
	case len(segments) == 5 && segments[0] == "library" && segments[2] == "assets" && segments[4] == "transfer_grant" && segmentOK(segments[1]) && segmentOK(segments[3]):
		return posted(method, route{kind: routeTransferGrant, name: "transfer_grant", id: segments[1], assetID: segments[3]})
	case len(segments) == 5 && segments[0] == "library" && segments[2] == "assets" && segments[4] == "transfer" && segmentOK(segments[1]) && segmentOK(segments[3]):
		return fetched(method, route{kind: routeTransfer, name: "transfer", id: segments[1], assetID: segments[3]})
	}
	for _, excluded := range ExcludedRoutes {
		if excluded.Method == method && matchPattern(excluded.Pattern, segments) {
			return route{kind: routeExcluded, name: "excluded"}
		}
	}
	return route{kind: routeNone}
}

func posted(method string, found route) route {
	if method != http.MethodPost {
		return route{kind: routeNone}
	}
	return found
}

func fetched(method string, found route) route {
	if method != http.MethodGet && method != http.MethodHead {
		return route{kind: routeNone}
	}
	return found
}

func supported(method string, found route) route {
	return served(method, found, http.MethodGet, http.MethodHead)
}

func served(method string, found route, allowed ...string) route {
	if !slices.Contains(allowed, method) {
		return route{kind: routeWrongMethod, name: found.name, allow: strings.Join(allowed, ", ")}
	}
	return found
}

func classifyPreview(method, rest string) route {
	segments := strings.Split(rest, "/")
	switch {
	case rest == "session":
		return supported(method, route{kind: routeBrowserSession, name: "browser_session"})
	case rest == "library":
		return supported(method, route{kind: routeBrowserLibrary, name: "browser_library"})
	case rest == "continue":
		return supported(method, route{kind: routeBrowserContinue, name: "browser_continue"})
	case len(segments) == 2 && segments[0] == "library" && segmentOK(segments[1]):
		return supported(method, route{kind: routeBrowserPublication, name: "browser_publication", id: segments[1]})
	case len(segments) == 3 && segments[0] == "library" && segments[2] == "reading_status" && segmentOK(segments[1]):
		return served(method, route{kind: routeBrowserStatus, name: "browser_reading_status", id: segments[1]}, http.MethodPut)
	case len(segments) == 3 && segments[0] == "library" && segments[2] == "reader" && segmentOK(segments[1]):
		return supported(method, route{kind: routeBrowserReader, name: "browser_reader", id: segments[1]})
	case len(segments) == 3 && segments[0] == "library" && segments[2] == "progress" && segmentOK(segments[1]):
		return served(method, route{kind: routeBrowserProgress, name: "browser_progress", id: segments[1]}, http.MethodGet, http.MethodHead, http.MethodPut)
	case len(segments) == 5 && segments[0] == "library" && segments[2] == "assets" && segments[4] == "reading_order" && segmentOK(segments[1]) && segmentOK(segments[3]):
		return supported(method, route{kind: routeBrowserReadingOrder, name: "browser_reading_order", id: segments[1], assetID: segments[3]})
	case len(segments) == 6 && segments[0] == "accounts" && segments[2] == "library" && segments[4] == "assets" && segmentOK(segments[1]) && segmentOK(segments[3]) && segmentOK(segments[5]):
		return supported(method, route{kind: routeBrowserMedia, name: "browser_media", account: segments[1], id: segments[3], assetID: segments[5]})
	case rest == "connect":
		switch method {
		case http.MethodGet, http.MethodHead:
			return route{kind: routeBrowserConnect, name: "browser_connect"}
		case http.MethodPost:
			return route{kind: routeBrowserDecide, name: "browser_decide"}
		}
		return route{kind: routeWrongMethod, name: "browser_connect", allow: "GET, HEAD, POST"}
	case rest == "account":
		return supported(method, route{kind: routeBrowserAccount, name: "browser_account"})
	case rest == "account/profile":
		return served(method, route{kind: routeBrowserProfile, name: "browser_profile"}, http.MethodPut)
	case rest == "account/password":
		return served(method, route{kind: routeBrowserPassword, name: "browser_password"}, http.MethodPost)
	case rest == "auth/bootstrap":
		return served(method, route{kind: routeAuthBootstrap, name: "auth_bootstrap"}, http.MethodGet)
	case rest == "auth/login":
		return served(method, route{kind: routeAuthLogin, name: "auth_login"}, http.MethodPost)
	case rest == "auth/logout":
		return served(method, route{kind: routeAuthLogout, name: "auth_logout"}, http.MethodPost)
	}
	return route{kind: routeNone}
}
