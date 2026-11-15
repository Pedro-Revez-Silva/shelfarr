//go:build e2e

package pairing

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
)

func normaliseJSON(value any) any {
	switch typed := value.(type) {
	case map[string]any:
		result := map[string]any{}
		for key, item := range typed {
			result[key] = normaliseJSON(item)
		}
		return result
	case []any:
		result := make([]any, len(typed))
		for index, item := range typed {
			result[index] = normaliseJSON(item)
		}
		return result
	case json.Number:
		rational, ok := new(big.Rat).SetString(typed.String())
		if !ok {
			return typed.String()
		}
		return rational.RatString()
	case int64:
		return strconv.FormatInt(typed, 10)
	}
	return value
}

func canonical(value any) any {
	encoded, _ := json.Marshal(value)
	decoded, _ := decodeJSON(encoded)
	return decoded
}

func decodeJSON(data []byte) (any, error) {
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	return normaliseJSON(value), nil
}

func firstDifference(path string, got, want any) string {
	switch expected := want.(type) {
	case map[string]any:
		actual, ok := got.(map[string]any)
		if !ok {
			return path + " (type)"
		}
		for key, value := range expected {
			if difference := firstDifference(path+"."+key, actual[key], value); difference != "" {
				return difference
			}
		}
		for key := range actual {
			if _, present := expected[key]; !present {
				return path + "." + key + " (unexpected)"
			}
		}
		return ""
	case []any:
		actual, ok := got.([]any)
		if !ok || len(actual) != len(expected) {
			return fmt.Sprintf("%s (length)", path)
		}
		for index, value := range expected {
			if difference := firstDifference(fmt.Sprintf("%s[%d]", path, index), actual[index], value); difference != "" {
				return difference
			}
		}
		return ""
	}
	if !reflect.DeepEqual(got, want) {
		return fmt.Sprintf("%s (got %v want %v)", path, got, want)
	}
	return ""
}

var (
	templatePattern = regexp.MustCompile(`\$\{([A-Za-z0-9:_-]+)(?:\|(\w+))?\}`)
	deviceShape     = regexp.MustCompile(`^[0-9a-f]{64}$`)
	userShape       = regexp.MustCompile(`^[BCDFGHJKLMNPQRSTVWXYZ23456789]{4}-[BCDFGHJKLMNPQRSTVWXYZ23456789]{4}$`)
	tokenShape      = regexp.MustCompile(`^shf_[1-9A-HJ-NP-Za-km-z]{40}$`)
	complete        = regexp.MustCompile(`user_code=([A-Z0-9]{4}-[A-Z0-9]{4})$`)
)

func digestOf(text string) string {
	sum := sha256.Sum256([]byte(text))
	return hex.EncodeToString(sum[:])
}

type replay struct {
	t        *testing.T
	f        fixture
	instance *server
	copied   runtimeCopy
	clock    string
	vars     map[string]string
	names    map[string]string
	previous map[string]map[string]map[string]any
	actors   map[string]*actor
}

type actor struct {
	client  *browser
	account string
}

func newReplay(t *testing.T, f fixture, instance *server, copied runtimeCopy, clock string) *replay {
	r := &replay{t: t, f: f, instance: instance, copied: copied, clock: clock, vars: map[string]string{}, names: map[string]string{}, actors: map[string]*actor{}}
	for name, raw := range f.secrets.Tokens {
		r.names[digestOf(raw)] = name
	}
	r.previous = r.snapshot()
	return r
}

func (r *replay) value(name string) string {
	if value, ok := r.vars[name]; ok {
		return value
	}
	value, ok := r.f.secrets.Tokens[name]
	if !ok {
		r.t.Fatalf("no value for %s", name)
	}
	return value
}

func (r *replay) resolve(text string) string {
	return templatePattern.ReplaceAllStringFunc(text, func(match string) string {
		parts := templatePattern.FindStringSubmatch(match)
		value := r.value(parts[1])
		switch parts[2] {
		case "":
			return value
		case "lower":
			return strings.ToLower(value)
		case "nohyphen":
			return strings.ReplaceAll(value, "-", "")
		case "digest":
			return digestOf(value)
		case "spaced":
			return strings.Replace(value, "-", " ", 1)
		}
		r.t.Fatalf("unknown transform %s", parts[2])
		return ""
	})
}

func (r *replay) resolveDeep(value any) any {
	switch typed := value.(type) {
	case string:
		return r.resolve(typed)
	case []any:
		out := make([]any, len(typed))
		for index, item := range typed {
			out[index] = r.resolveDeep(item)
		}
		return out
	case map[string]any:
		out := map[string]any{}
		for key, item := range typed {
			out[key] = r.resolveDeep(item)
		}
		return out
	}
	return value
}

func (r *replay) scrub(text string) string {
	secrets := []string{}
	for _, value := range r.vars {
		secrets = append(secrets, value)
	}
	for _, value := range r.f.secrets.Tokens {
		secrets = append(secrets, value)
	}
	for _, value := range r.f.secrets.Passwords {
		secrets = append(secrets, value)
	}
	for _, secret := range secrets {
		if len(secret) > 6 {
			text = strings.ReplaceAll(text, secret, "<redacted>")
		}
	}
	return regexp.MustCompile(`[0-9a-f]{64}`).ReplaceAllString(text, "<hex64>")
}

func (r *replay) register(field, name, value string) {
	r.vars[name] = value
	source := value
	if field == "user_code" {
		source = strings.ReplaceAll(value, "-", "")
	}
	r.names[digestOf(source)] = name
}

func (r *replay) normaliseResponse(document map[string]any) (map[string]any, []string) {
	var problems []string
	out := map[string]any{}
	var code string
	if value, ok := document["user_code"].(string); ok {
		code = value
	}
	for key, value := range document {
		text, isText := value.(string)
		switch {
		case key == "device_code" && isText:
			if !deviceShape.MatchString(text) {
				problems = append(problems, "device_code shape")
			}
			out[key] = "<device_code>"
		case key == "user_code" && isText:
			if !userShape.MatchString(text) {
				problems = append(problems, "user_code shape")
			}
			out[key] = "<user_code>"
		case key == "access_token" && isText:
			if !tokenShape.MatchString(text) {
				problems = append(problems, "access_token shape")
			}
			out[key] = "<access_token>"
		case (key == "verification_uri" || key == "verification_uri_complete") && isText:
			replaced := strings.Replace(text, r.instance.origin, "<origin>", 1)
			if match := complete.FindStringSubmatch(replaced); match != nil {
				if match[1] != code {
					problems = append(problems, "verification_uri_complete carries a different code")
				}
				replaced = complete.ReplaceAllString(replaced, "user_code=<user_code>")
			}
			out[key] = replaced
		default:
			out[key] = value
		}
	}
	return out, problems
}

func (r *replay) snapshot() map[string]map[string]map[string]any {
	grants := map[string]map[string]any{}
	for _, row := range rows(r.t, r.copied.database, `SELECT id, user_id, client_name, CAST(expires_at AS TEXT) AS expires_at, CAST(approved_at AS TEXT) AS approved_at, CAST(denied_at AS TEXT) AS denied_at, CAST(consumed_at AS TEXT) AS consumed_at, CAST(last_polled_at AS TEXT) AS last_polled_at, poll_interval, scopes, replaces_api_token_id, CAST(created_at AS TEXT) AS created_at, CAST(updated_at AS TEXT) AS updated_at, device_code_digest, user_code_digest FROM consumer_device_grants ORDER BY id`) {
		device, user := row["device_code_digest"].(string), row["user_code_digest"].(string)
		delete(row, "device_code_digest")
		delete(row, "user_code_digest")
		row["device_var"], row["user_var"] = nilIfEmpty(r.names[device]), nilIfEmpty(r.names[user])
		grants[fmt.Sprint(row["id"])] = row
	}
	tokens := map[string]map[string]any{}
	labels := map[string]string{}
	for _, row := range rows(r.t, r.copied.database, `SELECT id, user_id, name, scopes, token_prefix, CAST(expires_at AS TEXT) AS expires_at, issued_via, replaces_api_token_id, CAST(revoked_at AS TEXT) AS revoked_at, CAST(last_used_at AS TEXT) AS last_used_at, CAST(created_at AS TEXT) AS created_at, CAST(updated_at AS TEXT) AS updated_at, token_digest, connection_key FROM api_tokens ORDER BY id`) {
		digest := row["token_digest"].(string)
		delete(row, "token_digest")
		key := row["connection_key"]
		delete(row, "connection_key")
		name := r.names[digest]
		row["token_var"] = nilIfEmpty(name)
		row["prefix_matches"] = nil
		if known := r.knownRaw(name); known != "" {
			row["prefix_matches"] = known[:12] == row["token_prefix"]
			delete(row, "token_prefix")
		}
		row["connection"] = nil
		if text, ok := key.(string); ok {
			if _, seen := labels[text]; !seen {
				labels[text] = fmt.Sprintf("key-%d", len(labels)+1)
			}
			row["connection"] = labels[text]
		}
		tokens[fmt.Sprint(row["id"])] = row
	}
	return map[string]map[string]map[string]any{"grants": grants, "tokens": tokens}
}

func nilIfEmpty(text string) any {
	if text == "" {
		return nil
	}
	return text
}

func (r *replay) knownRaw(name string) string {
	if name == "" {
		return ""
	}
	if value, ok := r.vars[name]; ok {
		return value
	}
	return r.f.secrets.Tokens[name]
}

func (r *replay) delta() map[string]any {
	current := r.snapshot()
	result := map[string]any{}
	for _, table := range []string{"grants", "tokens"} {
		changed := map[string]any{}
		for id, row := range current[table] {
			if !reflect.DeepEqual(canonical(row), canonical(r.previous[table][id])) {
				changed[id] = row
			}
		}
		var deleted []any
		var gone []string
		for id := range r.previous[table] {
			if _, present := current[table][id]; !present {
				gone = append(gone, id)
			}
		}
		sort.Slice(gone, func(i, j int) bool { a, _ := strconv.Atoi(gone[i]); b, _ := strconv.Atoi(gone[j]); return a < b })
		for _, id := range gone {
			deleted = append(deleted, id)
		}
		if deleted == nil {
			deleted = []any{}
		}
		result[table] = map[string]any{"changed": changed, "deleted": deleted}
	}
	r.previous = current
	return result
}

func (r *replay) checkRows(s step) []string {
	got := r.delta()
	if difference := firstDifference("rows", canonical(got), canonical(s.Rows)); difference != "" {
		return []string{s.Name + ": database effects differ from Rails at " + difference}
	}
	return nil
}

func (r *replay) request(s step) []string {
	setClock(r.t, r.clock, s.At)
	headers := map[string]string{"Accept": "application/json"}
	if s.Authorization != nil {
		headers["Authorization"] = r.resolve(*s.Authorization)
	}
	for name, value := range s.Headers {
		headers[name] = r.resolve(value)
	}
	var body []byte
	switch {
	case s.Raw != nil:
		body = []byte(r.resolve(*s.Raw))
	case s.Body != nil:
		body, _ = json.Marshal(r.resolveDeep(s.Body))
	}
	got := r.instance.bare().do(s.Method, s.Path, headers, body)
	problems := r.compare(s, got)
	if got.status == http.StatusOK && len(s.Save) > 0 {
		var document map[string]any
		json.Unmarshal(got.body, &document)
		for field, name := range s.Save {
			if value, ok := document[field].(string); ok {
				r.register(field, name, value)
			}
		}
	}
	for index := range problems {
		problems[index] = s.Name + ": " + problems[index]
	}
	return append(problems, r.checkRows(s)...)
}

func (r *replay) compare(s step, got result) []string {
	if s.Go != nil {
		var problems []string
		if got.status != s.Go.Status {
			problems = append(problems, fmt.Sprintf("status %d want %d", got.status, s.Go.Status))
		}
		var body struct {
			Error string `json:"error"`
		}
		json.Unmarshal(got.body, &body)
		if body.Error != s.Go.Code {
			problems = append(problems, fmt.Sprintf("error code %q want %q", body.Error, s.Go.Code))
		}
		return problems
	}
	var problems []string
	if got.status != s.Status {
		return []string{fmt.Sprintf("status %d want %d (%s)", got.status, s.Status, got.body)}
	}
	for name, expected := range s.ResponseHeaders {
		if name == "content-type" && s.JSON == nil {
			continue
		}
		if value := got.headers.Get(name); value != expected {
			problems = append(problems, fmt.Sprintf("header %s: got %q want %q", name, value, expected))
		}
	}
	if s.BodyEmpty {
		if len(got.body) != 0 {
			problems = append(problems, "body present")
		}
		return problems
	}
	var document map[string]any
	if err := json.Unmarshal(got.body, &document); err != nil {
		return append(problems, "body is not a JSON object")
	}
	normalised, shape := r.normaliseResponse(document)
	problems = append(problems, shape...)
	encoded, _ := json.Marshal(normalised)
	actual, _ := decodeJSON(encoded)
	expected := canonical(s.JSON)
	if difference := firstDifference("$", actual, expected); difference != "" {
		problems = append(problems, "json body differs at "+difference)
	}
	return problems
}

func (r *replay) signIn(name string) *actor {
	if found, ok := r.actors[name]; ok {
		return found
	}
	client := r.instance.browser()
	account, _ := client.signIn(name, r.f.secrets.Passwords[name])
	found := &actor{client: client, account: account}
	r.actors[name] = found
	return found
}

func (r *replay) connect(s step) []string {
	setClock(r.t, r.clock, s.At)
	person := r.signIn(s.Actor)
	code := r.resolve(s.UserCode)
	var got result
	if s.Kind == "inspect" {
		got = person.client.do("GET", "/preview/api/v1/connect?user_code="+urlEscape(code), map[string]string{"X-Shelfarr-Account": person.account, "Accept": "application/json"}, nil)
	} else {
		token, _ := person.client.bootstrap()
		payload, _ := json.Marshal(map[string]string{"user_code": code, "decision": s.Decision})
		got = person.client.do("POST", "/preview/api/v1/connect", map[string]string{"X-Shelfarr-Account": person.account, "Origin": r.instance.origin, "X-CSRF-Token": token, "Accept": "application/json"}, payload)
	}
	var problems []string
	if got.status != s.Status {
		problems = append(problems, fmt.Sprintf("%s: Go answered %d, Rails %d (%s)", s.Name, got.status, s.Status, got.body))
	}
	return append(problems, r.checkRows(s)...)
}

func urlEscape(text string) string {
	return strings.NewReplacer("%", "%25", " ", "%20", "&", "%26", "#", "%23", "+", "%2B").Replace(text)
}

func (r *replay) burst(s step) []string {
	setClock(r.t, r.clock, s.At)
	client := r.instance.bare()
	var statuses []int
	var last result
	body, _ := json.Marshal(s.Body)
	for index := 0; index < s.Count; index++ {
		last = client.do("POST", s.Path, map[string]string{"Accept": "application/json"}, body)
		statuses = append(statuses, last.status)
	}
	var problems []string
	if fmt.Sprint(statuses) != fmt.Sprint(s.Statuses) {
		problems = append(problems, fmt.Sprintf("%s: statuses differ from Rails: %v", s.Name, statuses))
	}
	if difference := firstDifference("$", canonical(last.json(r.t)), canonical(s.Limited)); difference != "" {
		problems = append(problems, s.Name+": limited answer differs at "+difference)
	}
	return append(problems, r.checkRows(s)...)
}

func (r *replay) sql(s step) []string {
	exec1(r.t, r.copied.database, r.resolve(s.Statement))
	return r.checkRows(s)
}

func (r *replay) define(s step) {
	r.vars[s.Var] = s.Value
	r.names[digestOf(s.Value)] = s.Var
}

func TestPairingDifferentialAgainstRails(t *testing.T) {
	for _, f := range fixtures(t) {
		t.Run(f.name, func(t *testing.T) {
			copied := newRuntimeCopy(t, f)
			clock := filepath.Join(copied.dir, "clock")
			setClock(t, clock, f.doc.Steps[0].At)
			instance := startServer(t, f, copied, serverOptions{seam: true, clockFile: clock})
			run := newReplay(t, f, instance, copied, clock)
			for _, name := range f.doc.Actors {
				run.signIn(name)
			}
			run.previous = run.snapshot()
			var failures []string
			for _, s := range f.doc.Steps {
				switch s.Kind {
				case "request":
					failures = append(failures, run.request(s)...)
				case "decide", "inspect":
					failures = append(failures, run.connect(s)...)
				case "sql":
					failures = append(failures, run.sql(s)...)
				case "define":
					run.define(s)
				case "burst":
					failures = append(failures, run.burst(s)...)
				default:
					t.Fatalf("unknown step kind %q", s.Kind)
				}
			}
			if len(failures) > 0 {
				shown := failures
				if len(shown) > 60 {
					shown = shown[:60]
				}
				t.Errorf("%d problems against Rails:\n%s", len(failures), run.scrub(strings.Join(shown, "\n")))
			}
			final := run.snapshot()
			for _, table := range []string{"grants", "tokens"} {
				if difference := firstDifference(table, canonical(final[table]), canonical(f.doc.Final[table])); difference != "" {
					t.Errorf("final %s differ from Rails at %s", table, run.scrub(difference))
				}
			}
			if code := instance.stop(); code != 0 {
				t.Errorf("server exit code %d", code)
			}
			if difference := run.scanLogs(instance); difference != "" {
				t.Errorf("%s", difference)
			}
		})
	}
}

func (r *replay) scanLogs(instance *server) string {
	logs := instance.log.String()
	for name, value := range r.vars {
		if len(value) > 6 && strings.Contains(logs, value) {
			return "a secret reached the server log: " + name
		}
	}
	for name, value := range r.f.secrets.Tokens {
		if strings.Contains(logs, value) {
			return "a seeded token reached the server log: " + name
		}
	}
	for name, value := range r.f.secrets.Passwords {
		if strings.Contains(logs, value) {
			return "a password reached the server log: " + name
		}
	}
	return ""
}
