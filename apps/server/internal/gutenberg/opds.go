package gutenberg

import (
	"bytes"
	"encoding/xml"
	"errors"
	"io"
	"strings"
	"unicode/utf8"
)

const (
	maxElements = 20_000
	maxDepth    = 32
	maxEntries  = 100
	atomSpace   = "http://www.w3.org/2005/Atom"
	termsSpace  = "http://purl.org/dc/terms/"
)

var errMalformed = errors.New("malformed catalogue document")

type element struct {
	name     string
	attrs    map[string]string
	children []*element
	parts    []part
}

type part struct {
	text  string
	child *element
}

func parseDocument(body []byte) (*element, error) {
	if !utf8.Valid(body) {
		return nil, errMalformed
	}
	body = bytes.TrimPrefix(body, []byte("\xef\xbb\xbf"))
	decoder := xml.NewDecoder(bytes.NewReader(body))
	decoder.Strict = true
	var root *element
	var stack []*element
	count := 0
	for {
		start := decoder.InputOffset()
		token, err := decoder.Token()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, errMalformed
		}
		switch token := token.(type) {
		case xml.StartElement:
			count++
			if count > maxElements || len(stack) >= maxDepth {
				return nil, errMalformed
			}
			node := &element{name: qualified(token.Name), attrs: map[string]string{}}
			if err := node.readAttributes(token.Attr); err != nil {
				return nil, err
			}
			if len(stack) == 0 {
				if root != nil {
					return nil, errMalformed
				}
				root = node
			} else {
				parent := stack[len(stack)-1]
				parent.children = append(parent.children, node)
				parent.parts = append(parent.parts, part{child: node})
			}
			stack = append(stack, node)
		case xml.EndElement:
			stack = stack[:len(stack)-1]
		case xml.CharData:
			if len(stack) == 0 {
				if len(bytes.Trim(body[start:decoder.InputOffset()], " \t\r\n")) > 0 {
					return nil, errMalformed
				}
				continue
			}
			current := stack[len(stack)-1]
			current.parts = append(current.parts, part{text: string(token)})
		}
	}
	if root == nil || len(stack) != 0 {
		return nil, errMalformed
	}
	return root, nil
}

func (e *element) readAttributes(attributes []xml.Attr) error {
	seen := map[xml.Name]bool{}
	for _, attribute := range attributes {
		if seen[attribute.Name] || (attribute.Name.Space == "xmlns" && attribute.Value == "") {
			return errMalformed
		}
		seen[attribute.Name] = true
		if attribute.Name.Space == "" {
			e.attrs[attribute.Name.Local] = attribute.Value
		}
	}
	return nil
}

func qualified(name xml.Name) string {
	switch name.Space {
	case atomSpace:
		return name.Local
	case termsSpace:
		return "dcterms:" + name.Local
	}
	return "{" + name.Space + "}" + name.Local
}

func (e *element) content() string {
	var builder strings.Builder
	e.writeContent(&builder)
	return builder.String()
}

func (e *element) writeContent(builder *strings.Builder) {
	for _, piece := range e.parts {
		if piece.child != nil {
			piece.child.writeContent(builder)
		} else {
			builder.WriteString(piece.text)
		}
	}
}

func (e *element) child(name string) *element {
	for _, candidate := range e.children {
		if candidate.name == name {
			return candidate
		}
	}
	return nil
}

func (e *element) childText(path ...string) (string, bool) {
	node := e
	for _, name := range path {
		if node = node.child(name); node == nil {
			return "", false
		}
	}
	return node.content(), true
}

func (e *element) descendants(name string) []*element {
	var found []*element
	var walk func(node *element)
	walk = func(node *element) {
		for _, candidate := range node.children {
			if candidate.name == name {
				found = append(found, candidate)
			}
			walk(candidate)
		}
	}
	if e.name == name {
		found = append(found, e)
	}
	walk(e)
	return found
}

func entries(root *element) ([]*element, error) {
	if root.name != "feed" {
		return nil, errMalformed
	}
	found := root.descendants("entry")
	if len(found) > maxEntries {
		return nil, errMalformed
	}
	return found, nil
}

func hasNextPage(root *element) bool {
	for _, link := range root.children {
		if link.name == "link" && link.attrs["rel"] == "next" {
			return true
		}
	}
	return false
}
