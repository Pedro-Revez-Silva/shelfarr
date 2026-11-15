package strictjson

import (
	"errors"
	"math"
	"strconv"
	"strings"
	"unicode/utf8"
)

const MaxDepth = 100

var ErrSyntax = errors.New("malformed JSON")

type Kind int

const (
	Null Kind = iota
	Bool
	Integer
	Float
	String
	Array
	Object
)

type Value struct {
	Kind    Kind
	Flag    bool
	Text    string
	Items   []Value
	Keys    []string
	Members []Value
}

func (v Value) Finite() bool {
	if v.Kind != Float {
		return true
	}
	parsed, err := strconv.ParseFloat(v.Text, 64)
	return err == nil && !math.IsInf(parsed, 0)
}

func (v Value) Member(key string) (Value, bool) {
	for index, name := range v.Keys {
		if name == key {
			return v.Members[index], true
		}
	}
	return Value{}, false
}

func Parse(data []byte) (Value, error) {
	if !utf8.Valid(data) {
		return Value{}, ErrSyntax
	}
	parser := parser{data: data}
	parser.skipSpace()
	value, err := parser.value(1)
	if err != nil {
		return Value{}, err
	}
	parser.skipSpace()
	if parser.position != len(data) {
		return Value{}, ErrSyntax
	}
	return value, nil
}

type parser struct {
	data     []byte
	position int
}

func (p *parser) skipSpace() {
	for p.position < len(p.data) {
		switch p.data[p.position] {
		case ' ', '\t', '\n', '\r':
			p.position++
		default:
			return
		}
	}
}

func (p *parser) peek() (byte, bool) {
	if p.position >= len(p.data) {
		return 0, false
	}
	return p.data[p.position], true
}

func (p *parser) literal(word string) bool {
	if strings.HasPrefix(string(p.data[p.position:min(p.position+len(word), len(p.data))]), word) {
		p.position += len(word)
		return true
	}
	return false
}

func (p *parser) value(depth int) (Value, error) {
	current, ok := p.peek()
	if !ok {
		return Value{}, ErrSyntax
	}
	switch {
	case current == '{':
		return p.object(depth)
	case current == '[':
		return p.array(depth)
	case current == '"':
		text, err := p.stringValue()
		return Value{Kind: String, Text: text}, err
	case current == 't' && p.literal("true"):
		return Value{Kind: Bool, Flag: true}, nil
	case current == 'f' && p.literal("false"):
		return Value{Kind: Bool}, nil
	case current == 'n' && p.literal("null"):
		return Value{Kind: Null}, nil
	case current == '-' || current >= '0' && current <= '9':
		return p.number()
	}
	return Value{}, ErrSyntax
}

func (p *parser) number() (Value, error) {
	start := p.position
	if p.data[p.position] == '-' {
		p.position++
	}
	if !p.digits(true) {
		return Value{}, ErrSyntax
	}
	kind := Integer
	if current, ok := p.peek(); ok && current == '.' {
		p.position++
		if !p.digits(false) {
			return Value{}, ErrSyntax
		}
		kind = Float
	}
	if current, ok := p.peek(); ok && (current == 'e' || current == 'E') {
		p.position++
		if sign, ok := p.peek(); ok && (sign == '+' || sign == '-') {
			p.position++
		}
		if !p.digits(false) {
			return Value{}, ErrSyntax
		}
		kind = Float
	}
	return Value{Kind: kind, Text: string(p.data[start:p.position])}, nil
}

func (p *parser) digits(leadingZeroEnds bool) bool {
	first, ok := p.peek()
	if !ok || first < '0' || first > '9' {
		return false
	}
	if leadingZeroEnds && first == '0' {
		p.position++
		return true
	}
	for p.position < len(p.data) && p.data[p.position] >= '0' && p.data[p.position] <= '9' {
		p.position++
	}
	return true
}

func (p *parser) array(depth int) (Value, error) {
	if depth > MaxDepth {
		return Value{}, ErrSyntax
	}
	p.position++
	result := Value{Kind: Array}
	p.skipSpace()
	if current, ok := p.peek(); ok && current == ']' {
		p.position++
		return result, nil
	}
	for {
		p.skipSpace()
		item, err := p.value(depth + 1)
		if err != nil {
			return Value{}, err
		}
		result.Items = append(result.Items, item)
		p.skipSpace()
		current, ok := p.peek()
		if !ok {
			return Value{}, ErrSyntax
		}
		p.position++
		if current == ']' {
			return result, nil
		}
		if current != ',' {
			return Value{}, ErrSyntax
		}
	}
}

func (p *parser) object(depth int) (Value, error) {
	if depth > MaxDepth {
		return Value{}, ErrSyntax
	}
	p.position++
	result := Value{Kind: Object}
	p.skipSpace()
	if current, ok := p.peek(); ok && current == '}' {
		p.position++
		return result, nil
	}
	for {
		p.skipSpace()
		if current, ok := p.peek(); !ok || current != '"' {
			return Value{}, ErrSyntax
		}
		key, err := p.stringValue()
		if err != nil {
			return Value{}, err
		}
		p.skipSpace()
		if current, ok := p.peek(); !ok || current != ':' {
			return Value{}, ErrSyntax
		}
		p.position++
		p.skipSpace()
		member, err := p.value(depth + 1)
		if err != nil {
			return Value{}, err
		}
		result.set(key, member)
		p.skipSpace()
		current, ok := p.peek()
		if !ok {
			return Value{}, ErrSyntax
		}
		p.position++
		if current == '}' {
			return result, nil
		}
		if current != ',' {
			return Value{}, ErrSyntax
		}
	}
}

func (v *Value) set(key string, member Value) {
	for index, name := range v.Keys {
		if name == key {
			v.Members[index] = member
			return
		}
	}
	v.Keys = append(v.Keys, key)
	v.Members = append(v.Members, member)
}

func (p *parser) stringValue() (string, error) {
	p.position++
	var builder strings.Builder
	for {
		if p.position >= len(p.data) {
			return "", ErrSyntax
		}
		current := p.data[p.position]
		switch {
		case current == '"':
			p.position++
			return builder.String(), nil
		case current < 0x20:
			return "", ErrSyntax
		case current == '\\':
			if err := p.escape(&builder); err != nil {
				return "", err
			}
		default:
			builder.WriteByte(current)
			p.position++
		}
	}
}

func (p *parser) escape(builder *strings.Builder) error {
	p.position++
	if p.position >= len(p.data) {
		return ErrSyntax
	}
	current := p.data[p.position]
	p.position++
	switch current {
	case '"', '\\', '/':
		builder.WriteByte(current)
	case 'b':
		builder.WriteByte('\b')
	case 'f':
		builder.WriteByte('\f')
	case 'n':
		builder.WriteByte('\n')
	case 'r':
		builder.WriteByte('\r')
	case 't':
		builder.WriteByte('\t')
	case 'u':
		return p.unicode(builder)
	default:
		return ErrSyntax
	}
	return nil
}

func (p *parser) hexQuad() (rune, bool) {
	if p.position+4 > len(p.data) {
		return 0, false
	}
	value, err := strconv.ParseUint(string(p.data[p.position:p.position+4]), 16, 32)
	if err != nil || strings.ContainsAny(string(p.data[p.position:p.position+4]), "+-_") {
		return 0, false
	}
	p.position += 4
	return rune(value), true
}

func (p *parser) unicode(builder *strings.Builder) error {
	first, ok := p.hexQuad()
	if !ok {
		return ErrSyntax
	}
	switch {
	case first >= 0xDC00 && first <= 0xDFFF:
		return ErrSyntax
	case first >= 0xD800 && first <= 0xDBFF:
		if p.position+2 > len(p.data) || p.data[p.position] != '\\' || p.data[p.position+1] != 'u' {
			return ErrSyntax
		}
		p.position += 2
		second, ok := p.hexQuad()
		if !ok || second < 0xDC00 || second > 0xDFFF {
			return ErrSyntax
		}
		builder.WriteRune(0x10000 + (first-0xD800)<<10 + (second - 0xDC00))
	default:
		builder.WriteRune(first)
	}
	return nil
}
