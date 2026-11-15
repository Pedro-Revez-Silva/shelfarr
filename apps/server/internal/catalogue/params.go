package catalogue

import (
	"errors"
	"net/url"
	"strings"
	"unicode"
	"unicode/utf8"
)

const (
	maxQueryBytes = 12288
	maxParameters = 1024
)

var ErrBadQuery = errors.New("query string is malformed")

type Param struct {
	Present  bool
	IsString bool
	Value    string
}

func (p Param) Blank() bool {
	if !p.Present {
		return true
	}
	if !p.IsString {
		return false
	}
	return strings.TrimFunc(p.Value, unicode.IsSpace) == ""
}

type Params struct {
	Q, Type, Cursor, Limit, Status, Sort Param
}

func (p *Params) slot(name string) *Param {
	switch name {
	case "q":
		return &p.Q
	case "type":
		return &p.Type
	case "cursor":
		return &p.Cursor
	case "limit":
		return &p.Limit
	case "status":
		return &p.Status
	case "sort":
		return &p.Sort
	}
	return nil
}

func ParseQuery(raw string) (Params, error) {
	var params Params
	if len(raw) > maxQueryBytes {
		return params, ErrBadQuery
	}
	if raw == "" {
		return params, nil
	}
	pairs := strings.Split(raw, "&")
	if len(pairs) > maxParameters {
		return params, ErrBadQuery
	}
	for _, pair := range pairs {
		if pair == "" {
			continue
		}
		name, value, _ := strings.Cut(pair, "=")
		name, err := url.QueryUnescape(name)
		if err != nil || !utf8.ValidString(name) {
			return params, ErrBadQuery
		}
		value, err = url.QueryUnescape(value)
		if err != nil || !utf8.ValidString(value) {
			return params, ErrBadQuery
		}
		base, nested := name, false
		if index := strings.IndexByte(name, '['); index > 0 {
			base, nested = name[:index], true
		}
		slot := params.slot(base)
		if slot == nil {
			continue
		}
		if nested {
			if slot.Present && slot.IsString {
				return params, ErrBadQuery
			}
			*slot = Param{Present: true}
			continue
		}
		if slot.Present && !slot.IsString {
			return params, ErrBadQuery
		}
		*slot = Param{Present: true, IsString: true, Value: value}
	}
	return params, nil
}
