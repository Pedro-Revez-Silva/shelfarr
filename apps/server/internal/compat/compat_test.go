package compat

import "testing"

func TestJSONEqual(t *testing.T) {
	cases := []struct {
		name        string
		left, right string
		want        bool
	}{
		{"key order", `{"a":1,"b":[1,2]}`, `{"b":[1,2],"a":1}`, true},
		{"integer and float notation", `{"a":17.0}`, `{"a":17}`, true},
		{"exponent notation", `{"a":1e2}`, `{"a":100}`, true},
		{"fraction", `{"a":0.5}`, `{"a":0.50}`, true},
		{"large integer exactness", `{"a":9007199254740993}`, `{"a":9007199254740992}`, false},
		{"null versus missing", `{"a":null}`, `{}`, false},
		{"null versus empty string", `{"a":null}`, `{"a":""}`, false},
		{"string versus number", `{"a":"1"}`, `{"a":1}`, false},
		{"array order", `[1,2]`, `[2,1]`, false},
		{"array length", `[1]`, `[1,1]`, false},
		{"extra key", `{"a":1}`, `{"a":1,"b":2}`, false},
		{"booleans", `{"a":true}`, `{"a":false}`, false},
		{"nested", `{"a":{"b":[{"c":null}]}}`, `{"a":{"b":[{"c":null}]}}`, true},
		{"string escapes", `{"a":"é"}`, `{"a":"é"}`, true},
	}
	for _, testCase := range cases {
		got, err := JSONEqual([]byte(testCase.left), []byte(testCase.right))
		if err != nil || got != testCase.want {
			t.Errorf("%s: got %v, %v", testCase.name, got, err)
		}
	}
	for _, malformed := range []string{``, `{`, `{} {}`} {
		if _, err := JSONEqual([]byte(malformed), []byte(`{}`)); err == nil {
			t.Errorf("%q accepted", malformed)
		}
	}
}
