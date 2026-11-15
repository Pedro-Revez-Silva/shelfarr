package railsmsg

import (
	"encoding/json"
	"testing"
)

const (
	secret      = "394255a0455c48267642634e16ff5dad034598261fce426c56bd40e826dea27a4b41bf100c3051f6065d3e957c0948bcc7675c978090284e64d2a0b74f6b19f7"
	purpose     = "consumer-library"
	salt        = "consumer-catalog-v1"
	titleCursor = "eyJfcmFpbHMiOnsiZGF0YSI6eyJrZXkiOiJhYmMiLCJiZWZvcmUiOlsidGkiLDVdfSwicHVyIjoiY29uc3VtZXItbGlicmFyeSJ9fQ=="
	railsSigned = titleCursor + "--945da327219ee570de67c754ea2b56a8a351d398"
)

func titleBoundaryPayload() json.RawMessage {
	return json.RawMessage(`{"key":"abc","before":["ti",5]}`)
}

func newVerifier(t *testing.T, secretKeyBase string) Verifier {
	t.Helper()
	verifier, err := NewVerifier(secretKeyBase, salt)
	if err != nil {
		t.Fatal(err)
	}
	return verifier
}

func TestGeneratedMessagesRoundTripAndKeepTheRailsEnvelope(t *testing.T) {
	verifier := newVerifier(t, secret)
	token, err := verifier.Generate(titleBoundaryPayload(), purpose)
	if err != nil {
		t.Fatal(err)
	}
	if token[:len(titleCursor)] != titleCursor {
		t.Fatalf("envelope differs from the Rails encoding: %s", token)
	}
	data, ok := verifier.Verified(token, purpose)
	if !ok {
		t.Fatal("generated message was not verified")
	}
	var parsed struct {
		Key    string `json:"key"`
		Before []any  `json:"before"`
	}
	if err := json.Unmarshal(data, &parsed); err != nil || parsed.Key != "abc" || len(parsed.Before) != 2 {
		t.Fatalf("unexpected payload %s %v", data, err)
	}
}

func TestRailsSignedMessageIsAccepted(t *testing.T) {
	if _, ok := newVerifier(t, secret).Verified(railsSigned, purpose); !ok {
		t.Fatal("a message signed by Rails was refused")
	}
}

func TestGeneratedMessageEqualsTheRailsOne(t *testing.T) {
	token, err := newVerifier(t, secret).Generate(titleBoundaryPayload(), purpose)
	if err != nil || token != railsSigned {
		t.Fatalf("generated %q, want %q (%v)", token, railsSigned, err)
	}
}

func TestMessagesAreBoundToKeyPurposeAndIntegrity(t *testing.T) {
	verifier := newVerifier(t, secret)
	token, _ := verifier.Generate(json.RawMessage(`{"key":"abc","before":7}`), purpose)
	if _, ok := newVerifier(t, secret+"x").Verified(token, purpose); ok {
		t.Fatal("a different secret verified the message")
	}
	if _, ok := verifier.Verified(token, "other-purpose"); ok {
		t.Fatal("a different purpose verified the message")
	}
	flipped := "0"
	if token[len(token)-1] == '0' {
		flipped = "1"
	}
	for _, tampered := range []string{token + "0", "x" + token, token[:len(token)-1] + flipped, "", "--", "no-separator"} {
		if _, ok := verifier.Verified(tampered, purpose); ok {
			t.Fatalf("tampered message verified: %q", tampered)
		}
	}
}

func TestEmptySecretIsRefused(t *testing.T) {
	if _, err := NewVerifier("", salt); err == nil {
		t.Fatal("an empty secret key base was accepted")
	}
}

func TestQuoteMatchesTheRailsJsonEncoder(t *testing.T) {
	cases := map[string]string{
		"plain":                `"plain"`,
		`say "hi"\`:            `"say \"hi\"\\"`,
		"<b>&amp;</b>":         `"\u003cb\u003e\u0026amp;\u003c/b\u003e"`,
		"tab\there\nline":      `"tab\there\nline"`,
		"\x01\x1f":             `"\u0001\u001f"`,
		"caf\u00e9 \U0001F4DA": "\"caf\u00e9 \U0001F4DA\"",
		"sep\u2028":            "\"sep\u2028\"",
	}
	for input, want := range cases {
		if got := Quote(input); got != want {
			t.Errorf("%q: got %s want %s", input, got, want)
		}
	}
}
