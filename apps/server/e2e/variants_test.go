//go:build e2e

package e2e

import (
	"database/sql"
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"
)

func flipFirstPayloadByte(t *testing.T, v *variant, table, column string, id int) {
	t.Helper()
	handle, err := sql.Open("sqlite", v.path("db/primary.sqlite3"))
	if err != nil {
		t.Fatal(err)
	}
	var stored string
	if err := handle.QueryRow("SELECT "+column+" FROM "+table+" WHERE id = ?", id).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	var envelope map[string]any
	if err := json.Unmarshal([]byte(stored), &envelope); err != nil {
		t.Fatal(err)
	}
	payload := []byte(envelope["p"].(string))
	if payload[0] == 'A' {
		payload[0] = 'B'
	} else {
		payload[0] = 'A'
	}
	envelope["p"] = string(payload)
	encoded, _ := json.Marshal(envelope)
	if _, err := handle.Exec("UPDATE "+table+" SET "+column+" = ? WHERE id = ?", string(encoded), id); err != nil {
		t.Fatal(err)
	}
	handle.Exec("PRAGMA wal_checkpoint(TRUNCATE)")
	handle.Close()
}

type expectation struct {
	exit   int
	failed []string
}

func TestCorruptedBundlesAreRejectedByTheRightCheck(t *testing.T) {
	cases := []struct {
		name   string
		change func(*testing.T, *variant)
		want   expectation
	}{
		{"wrong primary key", func(t *testing.T, v *variant) {
			v.editJSON("secrets/credentials.json", func(d map[string]any) {
				d["encryption"].(map[string]any)["primary_key"] = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
			})
		}, expectation{1, []string{"encrypted-columns", "tampered-envelopes"}}},
		{"wrong key derivation salt", func(t *testing.T, v *variant) {
			v.editJSON("secrets/credentials.json", func(d map[string]any) {
				d["encryption"].(map[string]any)["key_derivation_salt"] = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
			})
		}, expectation{1, []string{"encrypted-columns", "tampered-envelopes"}}},
		{"tampered ciphertext", func(t *testing.T, v *variant) { flipFirstPayloadByte(t, v, "users", "otp_secret", 1) },
			expectation{1, []string{"encrypted-columns"}}},
		{"swapped password digests", func(t *testing.T, v *variant) {
			v.editDatabase("UPDATE users SET password_digest = (SELECT password_digest FROM users WHERE username = 'bob') WHERE username = 'alice'")
		}, expectation{1, []string{"passwords"}}},
		{"revived deleted account", func(t *testing.T, v *variant) {
			v.editDatabase("UPDATE users SET deleted_at = NULL WHERE username = 'carol'")
		}, expectation{1, []string{"consumer-projection", "passwords"}}},
		{"changed progress version", func(t *testing.T, v *variant) {
			v.editDatabase("UPDATE consumer_progresses SET version = version + 1 WHERE client_mutation_id = 'alice-quiet-3'")
		}, expectation{1, []string{"consumer-projection"}}},
		{"progress moved to another account", func(t *testing.T, v *variant) {
			v.editDatabase("UPDATE consumer_progresses SET user_id = 2 WHERE client_mutation_id = 'alice-audio-1'")
		}, expectation{1, []string{"consumer-projection"}}},
		{"unknown observation time becomes null", func(t *testing.T, v *variant) {
			v.editDatabase("UPDATE consumer_progresses SET observed_at = NULL WHERE client_mutation_id = 'bob-quiet-7'")
		}, expectation{1, []string{"consumer-projection"}}},
		{"malformed stored timestamp", func(t *testing.T, v *variant) {
			v.editDatabase("UPDATE consumer_progresses SET updated_at = 'not a time' WHERE client_mutation_id = 'alice-quiet-3'")
		}, expectation{1, []string{"consumer-projection"}}},
		{"reading status changed", func(t *testing.T, v *variant) {
			v.editDatabase("UPDATE consumer_reading_states SET status = 1 WHERE status = 2")
		}, expectation{1, []string{"consumer-projection"}}},
		{"book no longer acquired", func(t *testing.T, v *variant) {
			v.editDatabase("UPDATE books SET file_path = NULL WHERE title = 'The Quiet Library'")
		}, expectation{1, []string{"consumer-projection", "library-assets"}}},
		{"title edited", func(t *testing.T, v *variant) {
			v.editDatabase("UPDATE books SET title = title || ' ' WHERE title = 'A Listening Life'")
		}, expectation{1, []string{"consumer-projection"}}},
		{"revoked token reinstated", func(t *testing.T, v *variant) {
			v.editDatabase("UPDATE api_tokens SET revoked_at = NULL WHERE name = 'alice-revoked'")
		}, expectation{1, []string{"consumer-projection"}}},
		{"expired token extended", func(t *testing.T, v *variant) {
			v.editDatabase("UPDATE api_tokens SET expires_at = NULL WHERE name = 'alice-expired'")
		}, expectation{1, []string{"consumer-projection"}}},
		{"scope widened", func(t *testing.T, v *variant) {
			v.editDatabase(`UPDATE api_tokens SET scopes = '["library:read"]' WHERE name = 'alice-progress-only'`)
		}, expectation{1, []string{"consumer-projection"}}},
		{"adoption pointer cleared", func(t *testing.T, v *variant) {
			v.editDatabase("UPDATE api_tokens SET replaces_api_token_id = NULL WHERE name = 'alice-adopting'")
		}, expectation{1, []string{"consumer-projection"}}},
		{"output root setting removed", func(t *testing.T, v *variant) {
			v.editDatabase("DELETE FROM settings WHERE key = 'ebook_output_path'")
		}, expectation{1, []string{"consumer-projection", "library-assets"}}},
		{"output roots redirected", func(t *testing.T, v *variant) {
			v.editDatabase("UPDATE settings SET value = '/nonexistent-root' WHERE key LIKE '%_output_path'")
		}, expectation{1, []string{"consumer-projection", "library-assets"}}},
		{"expected asset identity altered", func(t *testing.T, v *variant) {
			v.editJSON("expected/library-assets.json", func(d map[string]any) {
				for _, book := range d["books"].([]any) {
					if assets := book.(map[string]any)["assets"].([]any); len(assets) > 0 {
						assets[0].(map[string]any)["id"] = strings.Repeat("0", 64)
						return
					}
				}
			})
		}, expectation{1, []string{"library-assets"}}},
		{"expected identity vector altered", func(t *testing.T, v *variant) {
			v.editJSON("expected/identity-vectors.json", func(d map[string]any) {
				d["vectors"].([]any)[0].(map[string]any)["id"] = strings.Repeat("f", 64)
			})
		}, expectation{1, []string{"identity-vectors"}}},
		{"schema revision disagrees", func(t *testing.T, v *variant) {
			v.manifest["schema"].(map[string]any)["revision"] = "1"
		}, expectation{1, []string{"schema-revision"}}},
		{"truncated database", func(t *testing.T, v *variant) {
			if err := os.Truncate(v.path("db/primary.sqlite3"), 4096); err != nil {
				t.Fatal(err)
			}
		}, expectation{2, nil}},
		{"garbage database header", func(t *testing.T, v *variant) {
			data := readFile(t, v.path("db/primary.sqlite3"))
			copy(data, []byte("not a sqlite db!"))
			writeFile(t, v.path("db/primary.sqlite3"), data, 0o640)
		}, expectation{2, nil}},
		{"database file emptied", func(t *testing.T, v *variant) { writeFile(t, v.path("db/primary.sqlite3"), nil, 0o640) }, expectation{2, nil}},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			current := newVariant(t)
			testCase.change(t, current)
			current.seal()
			result := execute(t, binary, current.dir, "--legacy-sha1")
			if result.code != testCase.want.exit || !reflect.DeepEqual(result.failed(), testCase.want.failed) {
				t.Fatalf("exit %d failed %v stderr %q, want %+v", result.code, result.failed(), result.stderr, testCase.want)
			}
			if result.code == 2 && result.stdout != "" {
				t.Fatal("refusal printed a report")
			}
		})
	}
}

func TestUnsealedTamperingIsRefusedBeforeAnyCheck(t *testing.T) {
	cases := map[string]func(*testing.T, *variant){
		"flipped database byte": func(t *testing.T, v *variant) {
			data := readFile(t, v.path("db/primary.sqlite3"))
			data[len(data)/2] ^= 0xff
			writeFile(t, v.path("db/primary.sqlite3"), data, 0o640)
		},
		"edited expectation": func(t *testing.T, v *variant) {
			data := readFile(t, v.path("expected/responses.json"))
			writeFile(t, v.path("expected/responses.json"), append(data, ' '), 0o640)
		},
		"stray wal sidecar":   func(t *testing.T, v *variant) { writeFile(t, v.path("db/primary.sqlite3-wal"), nil, 0o640) },
		"stray shm sidecar":   func(t *testing.T, v *variant) { writeFile(t, v.path("db/primary.sqlite3-shm"), nil, 0o640) },
		"stray extra file":    func(t *testing.T, v *variant) { writeFile(t, v.path("db/notes.txt"), []byte("x"), 0o640) },
		"group readable keys": func(t *testing.T, v *variant) { os.Chmod(v.path("secrets/credentials.json"), 0o640) },
		"open secrets folder": func(t *testing.T, v *variant) { os.Chmod(v.path("secrets"), 0o755) },
		"missing manifest":    func(t *testing.T, v *variant) { os.Remove(v.path("manifest.json")) },
	}
	for name, change := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			current := newVariant(t)
			change(t, current)
			result := execute(t, binary, current.dir, "--legacy-sha1")
			if result.code != 2 || result.stdout != "" || !strings.HasPrefix(result.stderr, "refused:") {
				t.Fatalf("exit %d stdout %q stderr %q", result.code, result.stdout, result.stderr)
			}
		})
	}
}

func addBoundsCases(v *variant) {
	credentials := v.credentials()["encryption"].(map[string]any)
	primary, salt := credentials["primary_key"].(string), credentials["key_derivation_salt"].(string)
	v.editJSON("expected/encryption.json", func(d map[string]any) {
		bomb := map[string]any{"name": "decompression-bomb", "envelope": envelopeFor(primary, salt, make([]byte, 2<<20+1), true), "outcome": "error", "category": "limit"}
		huge := map[string]any{"name": "oversized-envelope", "envelope": strings.Repeat(" ", 1<<20+1), "outcome": "error", "category": "limit"}
		d["tampered"] = append(d["tampered"].([]any), bomb, huge)
	})
	v.seal()
}

func TestEnvelopeBoundsAreEnforcedEndToEnd(t *testing.T) {
	current := newVariant(t)
	addBoundsCases(current)
	result := execute(t, binary, current.dir, "--legacy-sha1")
	if result.code != 0 {
		t.Fatalf("exit %d failed %v", result.code, result.failed())
	}
}

func TestPlaintextNeverAppearsEvenWhenTheEnvelopeIsTampered(t *testing.T) {
	var document struct {
		Columns []struct {
			Table, Column, ID string
		} `json:"columns"`
	}
	if err := json.Unmarshal(readFile(t, pristine+"/expected/encryption.json"), &document); err != nil {
		t.Fatal(err)
	}
	handle, err := sql.Open("sqlite", "file:"+pristine+"/db/primary.sqlite3?mode=ro&immutable=1")
	if err != nil {
		t.Fatal(err)
	}
	defer handle.Close()
	var envelope string
	if err := handle.QueryRow("SELECT otp_secret FROM users WHERE id = 1").Scan(&envelope); err != nil {
		t.Fatal(err)
	}
	credentials := (&variant{t: t, dir: pristine}).credentials()["encryption"].(map[string]any)
	plaintext, err := independentDecrypt(credentials["primary_key"].(string), credentials["key_derivation_salt"].(string), envelope)
	if err != nil || len(plaintext) < 16 {
		t.Fatalf("independent decryption failed: %v", err)
	}
	current := newVariant(t)
	flipFirstPayloadByte(t, current, "users", "otp_secret", 1)
	current.seal()
	for _, result := range []outcome{execute(t, binary, pristine, "--legacy-sha1"), execute(t, binary, current.dir, "--legacy-sha1")} {
		if strings.Contains(result.stdout+result.stderr, string(plaintext)) {
			t.Fatal("plaintext appeared in the output")
		}
	}
}
