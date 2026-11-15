package gohttp

import (
	"net/http"
	"slices"
	"strings"
)

const apiPrefix = "/api/consumer/v1/"

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
	routeExcluded
	routeWrongMethod
)

type route struct {
	kind    routeKind
	name    string
	id      string
	assetID string
	allow   string
}

type excludedRoute struct {
	Method  string
	Pattern string
	Reason  string
}

var ExcludedRoutes = []excludedRoute{
	{http.MethodPost, "auth/device", "pairing and token creation"},
	{http.MethodPost, "auth/token", "pairing and token creation"},
	{http.MethodPost, "auth/revoke", "token revocation writes"},
	{http.MethodGet, "discover", "requests and acquisition"},
	{http.MethodGet, "requests", "requests and acquisition"},
	{http.MethodPost, "requests", "requests and acquisition"},
	{http.MethodGet, "requests/{id}", "requests and acquisition"},
	{http.MethodDelete, "requests/{id}", "requests and acquisition"},
	{http.MethodGet, "library/{id}/assets/{asset}/reading_order", "CBZ reading order"},
	{http.MethodGet, "library/{id}/assets/{asset}/read_along", "read-along"},
	{http.MethodGet, "library/{id}/assets/{asset}/read_along/resources/{path...}", "read-along"},
	{http.MethodGet, "library/{id}/assets/{asset}/read_along/audio/{audio}", "read-along"},
	{http.MethodPost, "library/{id}/assets/{asset}/transfer_grant", "transfer grants"},
	{http.MethodGet, "library/{id}/assets/{asset}/transfer", "transfer grants"},
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
	}
	for _, excluded := range ExcludedRoutes {
		if excluded.Method == method && matchPattern(excluded.Pattern, segments) {
			return route{kind: routeExcluded, name: "excluded"}
		}
	}
	return route{kind: routeNone}
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
