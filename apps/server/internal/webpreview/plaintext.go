package webpreview

import (
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/net/html"
	"golang.org/x/net/html/atom"
)

const maxMarkupDepth = 256

var (
	runs       = regexp.MustCompile(`[ \t]+`)
	lineEdges  = regexp.MustCompile(` ?\n ?`)
	blankLines = regexp.MustCompile(`\n{3,}`)

	foreignElement = regexp.MustCompile(`(?i)<(svg|math)`)
)

func PlainText(value string) (string, error) {
	for _, character := range value {
		if character == '\r' || character == 0 || character < 0x20 && character != '\n' && character != '\t' {
			return "", ErrUnsupported
		}
	}
	if strings.Contains(value, "<![CDATA[") && foreignElement.MatchString(value) {
		return "", ErrUnsupported
	}
	text, err := visibleText(lineBreaks(withoutRawTextElements(value)))
	if err != nil {
		return "", err
	}
	text = strings.ReplaceAll(text, " ", "&nbsp;")
	text = runs.ReplaceAllString(text, " ")
	text = lineEdges.ReplaceAllString(text, "\n")
	text = blankLines.ReplaceAllString(text, "\n\n")
	return strings.Trim(text, " \t\n\v\f\r"), nil
}

func isWordRune(character rune) bool {
	return character == '_' || unicode.IsLetter(character) || unicode.IsMark(character) || unicode.IsDigit(character) || unicode.Is(unicode.Pc, character)
}

func atBoundary(value string, index int) bool {
	if index >= len(value) {
		return true
	}
	next, _ := utf8.DecodeRuneInString(value[index:])
	return !isWordRune(next)
}

func asciiSpace(character byte) bool {
	return character == ' ' || character == '\t' || character == '\n' || character == '\v' || character == '\f' || character == '\r'
}

func hasFold(value string, index int, name string) bool {
	return len(value)-index >= len(name) && strings.EqualFold(value[index:index+len(name)], name)
}

func withoutRawTextElements(value string) string {
	var out strings.Builder
	for index := 0; index < len(value); {
		end := rawElementEnd(value, index)
		if end < 0 {
			out.WriteByte(value[index])
			index++
			continue
		}
		index = end
	}
	return out.String()
}

func rawElementEnd(value string, index int) int {
	if value[index] != '<' {
		return -1
	}
	for _, name := range []string{"script", "style"} {
		if !hasFold(value, index+1, name) || !atBoundary(value, index+1+len(name)) {
			continue
		}
		for cursor := index + 1 + len(name); cursor < len(value); cursor++ {
			if value[cursor] != '<' || cursor+1 >= len(value) || value[cursor+1] != '/' || !hasFold(value, cursor+2, name) {
				continue
			}
			tail := cursor + 2 + len(name)
			for tail < len(value) && asciiSpace(value[tail]) {
				tail++
			}
			if tail < len(value) && value[tail] == '>' {
				return tail + 1
			}
		}
	}
	return -1
}

var blockNames = []string{"p", "div", "li", "br", "h1", "h2", "h3", "h4", "h5", "h6", "tr"}

func lineBreaks(value string) string {
	var out strings.Builder
	for index := 0; index < len(value); {
		end := blockTagEnd(value, index)
		if end < 0 {
			out.WriteByte(value[index])
			index++
			continue
		}
		out.WriteByte('\n')
		index = end
	}
	return out.String()
}

func blockTagEnd(value string, index int) int {
	if value[index] != '<' {
		return -1
	}
	start := index + 1
	if start < len(value) && value[start] == '/' {
		start++
	}
	for _, name := range blockNames {
		if !hasFold(value, start, name) || !atBoundary(value, start+len(name)) {
			continue
		}
		if closing := strings.IndexByte(value[start+len(name):], '>'); closing >= 0 {
			return start + len(name) + closing + 1
		}
	}
	return -1
}

func visibleText(markup string) (string, error) {
	if markup == "" {
		return "", nil
	}
	context := &html.Node{Type: html.ElementNode, DataAtom: atom.Body, Data: "body"}
	roots, err := html.ParseFragmentWithOptions(strings.NewReader(markup), context, html.ParseOptionEnableScripting(false))
	if err != nil {
		return "", ErrUnsupported
	}
	var text strings.Builder
	type frame struct {
		node  *html.Node
		depth int
	}
	stack := make([]frame, 0, len(roots))
	for index := len(roots) - 1; index >= 0; index-- {
		stack = append(stack, frame{roots[index], 1})
	}
	for len(stack) > 0 {
		current := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if current.depth > maxMarkupDepth {
			return "", ErrUnsupported
		}
		if current.node.Type == html.TextNode {
			text.WriteString(current.node.Data)
			continue
		}
		for child := current.node.LastChild; child != nil; child = child.PrevSibling {
			stack = append(stack, frame{child, current.depth + 1})
		}
	}
	return text.String(), nil
}
