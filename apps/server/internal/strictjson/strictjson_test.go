package strictjson

import (
	"strings"
	"testing"
)

func TestValidDocumentsKeepTheirShapeAndOrder(t *testing.T) {
	cases := map[string]string{
		`{"b":1,"a":[true,null,"x",1.50,1e2,-0,12345678901234567890]}`: `{"b":1,"a":[true,null,"x",1.50,1e2,-0,12345678901234567890]}`,
		"  {\n\t\"k\" : \"v\"\r}  ":                                    `{"k":"v"}`,
		`{"a":1,"a":2,"b":3}`:                                          `{"a":2,"b":3}`,
		`{"s":"é😀\n\"\\/"}`:                                            "{\"s\":\"é😀\\u000a\\\"\\\\/\"}",
		`[]`:                                                           `[]`,
		`{}`:                                                           `{}`,
	}
	for input, want := range cases {
		parsed, err := Parse([]byte(input))
		if err != nil {
			t.Errorf("%q: %v", input, err)
			continue
		}
		if got := parsed.Encode(); got != want {
			t.Errorf("%q: got %s want %s", input, got, want)
		}
	}
}

func TestMalformedDocumentsAreRefused(t *testing.T) {
	deep := strings.Repeat("[", MaxDepth+1) + strings.Repeat("]", MaxDepth+1)
	cases := []string{
		``, `{`, `}`, `[1,]`, `{"a":1,}`, `{"a"}`, `{a:1}`, `{'a':1}`, `01`, `1.`, `.5`, `+1`, `-`, `1e`, `1e+`, `NaN`, `Infinity`, `-Infinity`, `nul`, `tru`,
		`"unterminated`, "\"raw\ttab\"", `"\x41"`, `"\ud800"`, `"\udc00"`, `"\ud800A"`, `"\u12"`, `"\u+123"`, `{"a":1} x`, `[1] [2]`, `/* c */ {}`, `// c` + "\n{}",
		"\"\xff\"", "{\"a\":\"\xc3\"}", deep,
	}
	for _, input := range cases {
		if _, err := Parse([]byte(input)); err == nil {
			t.Errorf("%q was accepted", input)
		}
	}
	if _, err := Parse([]byte(strings.Repeat("[", MaxDepth) + strings.Repeat("]", MaxDepth))); err != nil {
		t.Errorf("the deepest accepted nesting was refused: %v", err)
	}
}

func TestIntegerAndFloatLiteralsAreDistinguished(t *testing.T) {
	for literal, kind := range map[string]Kind{"0": Integer, "-0": Integer, "10": Integer, "1.0": Float, "1e0": Float, "1E+2": Float, "-1.5e-3": Float} {
		parsed, err := Parse([]byte(literal))
		if err != nil || parsed.Kind != kind {
			t.Errorf("%s: %v %v", literal, parsed.Kind, err)
		}
	}
	if parsed, _ := Parse([]byte(`1e400`)); parsed.Finite() {
		t.Error("an overflowing float is finite")
	}
	if parsed, _ := Parse([]byte(`1e-400`)); !parsed.Finite() {
		t.Error("an underflowing float is not finite")
	}
}

func TestEqualityFollowsRubyNumericComparison(t *testing.T) {
	equal := [][2]string{{`1`, `1.0`}, {`{"a":1,"b":[2]}`, `{"b":[2.0],"a":1.00}`}, {`100`, `1e2`}, {`0.1`, `0.10`}, {`12345678901234567890`, `12345678901234567890`}, {`null`, `null`}, {`"x"`, `"x"`}}
	different := [][2]string{{`1`, `"1"`}, {`{"a":1}`, `{"a":1,"b":null}`}, {`[1,2]`, `[2,1]`}, {`true`, `1`}, {`9007199254740993`, `9007199254740992.0`}, {`null`, `false`}, {`{"a":1}`, `{"b":1}`}}
	for _, pair := range equal {
		left, _ := Parse([]byte(pair[0]))
		right, _ := Parse([]byte(pair[1]))
		if !Equal(left, right) || !Equal(right, left) {
			t.Errorf("%s should equal %s", pair[0], pair[1])
		}
	}
	for _, pair := range different {
		left, _ := Parse([]byte(pair[0]))
		right, _ := Parse([]byte(pair[1]))
		if Equal(left, right) || Equal(right, left) {
			t.Errorf("%s should differ from %s", pair[0], pair[1])
		}
	}
}
