package strictjson

import (
	"math/big"
	"strconv"
	"strings"
)

func (v Value) Encode() string {
	var builder strings.Builder
	v.encodeInto(&builder)
	return builder.String()
}

func (v Value) encodeInto(builder *strings.Builder) {
	switch v.Kind {
	case Null:
		builder.WriteString("null")
	case Bool:
		builder.WriteString(strconv.FormatBool(v.Flag))
	case Integer, Float:
		builder.WriteString(v.Text)
	case String:
		quote(builder, v.Text)
	case Array:
		builder.WriteByte('[')
		for index, item := range v.Items {
			if index > 0 {
				builder.WriteByte(',')
			}
			item.encodeInto(builder)
		}
		builder.WriteByte(']')
	case Object:
		builder.WriteByte('{')
		for index, key := range v.Keys {
			if index > 0 {
				builder.WriteByte(',')
			}
			quote(builder, key)
			builder.WriteByte(':')
			v.Members[index].encodeInto(builder)
		}
		builder.WriteByte('}')
	}
}

func quote(builder *strings.Builder, text string) {
	const hex = "0123456789abcdef"
	builder.WriteByte('"')
	for index := 0; index < len(text); index++ {
		current := text[index]
		switch {
		case current == '"' || current == '\\':
			builder.WriteByte('\\')
			builder.WriteByte(current)
		case current < 0x20:
			builder.WriteString(`\u00`)
			builder.WriteByte(hex[current>>4])
			builder.WriteByte(hex[current&0xf])
		default:
			builder.WriteByte(current)
		}
	}
	builder.WriteByte('"')
}

func Equal(left, right Value) bool {
	if isNumber(left) && isNumber(right) {
		return numbersEqual(left, right)
	}
	if left.Kind != right.Kind {
		return false
	}
	switch left.Kind {
	case Null:
		return true
	case Bool:
		return left.Flag == right.Flag
	case String:
		return left.Text == right.Text
	case Array:
		if len(left.Items) != len(right.Items) {
			return false
		}
		for index := range left.Items {
			if !Equal(left.Items[index], right.Items[index]) {
				return false
			}
		}
		return true
	case Object:
		if len(left.Keys) != len(right.Keys) {
			return false
		}
		for index, key := range left.Keys {
			other, found := right.Member(key)
			if !found || !Equal(left.Members[index], other) {
				return false
			}
		}
		return true
	}
	return false
}

func isNumber(v Value) bool { return v.Kind == Integer || v.Kind == Float }

func numbersEqual(left, right Value) bool {
	if left.Kind == Integer && right.Kind == Integer {
		a, _ := new(big.Int).SetString(left.Text, 10)
		b, _ := new(big.Int).SetString(right.Text, 10)
		return a != nil && b != nil && a.Cmp(b) == 0
	}
	if left.Kind == Float && right.Kind == Float {
		a, errA := strconv.ParseFloat(left.Text, 64)
		b, errB := strconv.ParseFloat(right.Text, 64)
		return errA == nil && errB == nil && a == b
	}
	integer, float := left, right
	if left.Kind == Float {
		integer, float = right, left
	}
	whole, ok := new(big.Int).SetString(integer.Text, 10)
	parsed, err := strconv.ParseFloat(float.Text, 64)
	if !ok || err != nil {
		return false
	}
	exact := new(big.Float).SetFloat64(parsed)
	return exact.Cmp(new(big.Float).SetInt(whole)) == 0
}
