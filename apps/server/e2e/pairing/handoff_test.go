//go:build e2e

package pairing

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestGoContinuesStateRailsCreatedAndLeavesStateRailsCanContinue(t *testing.T) {
	for _, f := range fixtures(t) {
		t.Run(f.name, func(t *testing.T) {
			start, err := time.Parse(time.RFC3339Nano, f.doc.Handoff.At)
			if err != nil {
				t.Fatal(err)
			}
			copied := newRuntimeCopyFrom(t, filepath.Join(f.dir, f.doc.Handoff.Database))
			clock := filepath.Join(copied.dir, "clock")
			setClock(t, clock, start.Format(time.RFC3339Nano))
			instance := startServer(t, f, copied, serverOptions{seam: true, clockFile: clock})
			a := api{t: t, instance: instance, f: f, clock: clock}
			h := f.secrets.Handoff
			a.at(start.Add(time.Second))
			one := a.consenter("pair_one")

			view := one.inspect(h["pending_user"])
			mustStatus(t, "inspect a Rails grant", view, 200)
			if !contains(string(view.body), `"client_name":"Rails pending"`, `"decidable":true`) {
				t.Fatalf("inspect %s", view.body)
			}
			mustStatus(t, "allow a Rails pending grant", one.decide(h["pending_user"], "allow"), 200)
			a.at(start.Add(20 * time.Second))
			got, issued := a.poll(h["pending_device"])
			mustStatus(t, "exchange a pending grant Go approved", got, 200)
			if issued["scope"] != "library:read progress:write" || a.me(str(issued["access_token"])) != 200 {
				t.Fatalf("issued %v", issued)
			}
			got, replay := a.poll(h["pending_device"])
			if got.status != 400 || replay["error"] != "expired_token" {
				t.Fatalf("replay %d %v", got.status, replay)
			}
			a.at(start.Add(30 * time.Second))
			got, approved := a.poll(h["approved_device"])
			mustStatus(t, "exchange a grant Rails approved", got, 200)
			if a.me(str(approved["access_token"])) != 200 {
				t.Fatal("a token for a Rails approved grant does not work")
			}
			if got, denied := a.poll(h["denied_device"]); got.status != 400 || denied["error"] != "access_denied" {
				t.Fatalf("denied %d %v", got.status, denied)
			}

			if a.me(h["upgrade_origin"]) != 200 {
				t.Fatal("the Rails origin credential must work before the replacement is used")
			}
			a.at(start.Add(40 * time.Second))
			got, upgraded := a.poll(h["upgrade_device"])
			mustStatus(t, "exchange a Rails upgrade", got, 200)
			if upgraded["scope"] != "library:read progress:write search:read requests:read requests:write" {
				t.Fatalf("upgrade scopes %v", upgraded["scope"])
			}
			if a.me(h["upgrade_origin"]) != 200 || a.me(str(upgraded["access_token"])) != 200 || a.me(h["upgrade_origin"]) != 401 {
				t.Fatal("the Rails origin must work until the Go-issued replacement is used, then be retired")
			}

			if a.me(h["plain"]) != 200 || a.revoke(h["plain"]) != 204 || a.me(h["plain"]) != 401 {
				t.Fatal("Go must authenticate and revoke a Rails-issued token")
			}
			if a.me(h["chain_second"]) != 200 || a.me(h["chain_first"]) != 401 {
				t.Fatal("Go must adopt a Rails upgrade chain")
			}
			if a.revoke(h["family_a"]) != 204 || a.me(h["family_b"]) != 401 {
				t.Fatal("Go must revoke the Rails connection family")
			}
			got, family := a.poll(h["family_upgrade_device"])
			if got.status != 400 || family["error"] != "access_denied" {
				t.Fatalf("a Rails upgrade of a revoked family: %d %v", got.status, family)
			}

			handoff := map[string]any{"clock": start.Add(2 * time.Minute).Format(time.RFC3339Nano)}
			a.at(start.Add(2 * time.Minute))
			_, pending := a.device(`{"client_name":"Go pending"}`, "")
			handoff["go_pending"] = map[string]any{"device": pending["device_code"], "user": pending["user_code"]}
			_, ready := a.device(`{"client_name":"Go approved","scope":"library:read progress:write search:read requests:read requests:write"}`, "")
			mustStatus(t, "allow a Go grant", one.decide(str(ready["user_code"]), "allow"), 200)
			handoff["go_approved"] = map[string]any{"device": ready["device_code"]}
			_, refused := a.device(`{"client_name":"Go denied"}`, "")
			mustStatus(t, "deny a Go grant", one.decide(str(refused["user_code"]), "deny"), 200)
			handoff["go_denied"] = map[string]any{"device": refused["device_code"]}

			_, first := a.device(`{"client_name":"Go origin"}`, "")
			one.decide(str(first["user_code"]), "allow")
			a.at(start.Add(3 * time.Minute))
			_, origin := a.poll(str(first["device_code"]))
			handoff["go_origin"] = origin["access_token"]
			_, again := a.device(`{"client_name":"Go origin","scope":"library:read progress:write search:read requests:read requests:write"}`, str(origin["access_token"]))
			one.decide(str(again["user_code"]), "allow")
			a.at(start.Add(4 * time.Minute))
			_, replacement := a.poll(str(again["device_code"]))
			handoff["go_replacement"] = replacement["access_token"]
			_, plain := a.device(`{"client_name":"Go plain"}`, "")
			one.decide(str(plain["user_code"]), "allow")
			a.at(start.Add(5 * time.Minute))
			_, token := a.poll(str(plain["device_code"]))
			handoff["go_token"] = token["access_token"]
			handoff["clock"] = start.Add(6 * time.Minute).Format(time.RFC3339Nano)

			if code := instance.stop(); code != 0 {
				t.Fatalf("server exit code %d", code)
			}
			target := os.Getenv("SHELFARR_PAIRING_GO_DIR")
			if target == "" {
				return
			}
			exportRows(t, copied, filepath.Join(target, f.name+".sqlite3"))
			encoded, _ := json.Marshal(handoff)
			if err := os.WriteFile(filepath.Join(target, f.name+".handoff.json"), encoded, 0o600); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func exportRows(t *testing.T, copied runtimeCopy, destination string) {
	t.Helper()
	database := openDatabase(t, copied.database)
	if _, err := database.Exec(`PRAGMA wal_checkpoint(TRUNCATE)`); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(copied.database)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(destination, data, 0o600); err != nil {
		t.Fatal(err)
	}
}
