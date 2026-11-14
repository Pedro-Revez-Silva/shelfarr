package bundle

import "encoding/json"

const SupportedFormat = 1

type FileEntry struct {
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

type Tree struct {
	Name     string               `json:"name"`
	Root     string               `json:"root"`
	Files    map[string]FileEntry `json:"files"`
	Symlinks map[string]string    `json:"symlinks"`
}

type Gap struct {
	ID     string `json:"id"`
	Status string `json:"status"`
	Detail string `json:"detail"`
}

type Coverage struct {
	Cases  []string `json:"cases"`
	Digest string   `json:"digest"`
	Gaps   []Gap    `json:"gaps"`
}

type Producer struct {
	Ruby           string `json:"ruby"`
	Rails          string `json:"rails"`
	RepositoryHead string `json:"repository_head"`
}

type Schema struct {
	Revision string `json:"revision"`
	Path     string `json:"path"`
}

type Database struct {
	Path string `json:"path"`
}

type Manifest struct {
	FixtureFormat int                  `json:"fixture_format"`
	Origin        string               `json:"origin"`
	Producer      Producer             `json:"producer"`
	Schema        Schema               `json:"schema"`
	MediaRoot     string               `json:"media_root"`
	Database      Database             `json:"database"`
	NowAtCapture  string               `json:"now_at_capture"`
	Coverage      Coverage             `json:"coverage"`
	Files         map[string]FileEntry `json:"files"`
	ExternalTrees []Tree               `json:"external_trees"`
}

type IdentityVector struct {
	Name     string `json:"name"`
	BookID   string `json:"book_id"`
	FilePath string `json:"file_path"`
	Path     string `json:"path"`
	Device   string `json:"device"`
	Inode    string `json:"inode"`
	Size     string `json:"size"`
	Mtime    string `json:"mtime"`
	Ctime    string `json:"ctime"`
	ID       string `json:"id"`
}

type IdentityVectors struct {
	Vectors []IdentityVector `json:"vectors"`
}

type AssetRecord struct {
	ID        string `json:"id"`
	Path      string `json:"path"`
	Root      string `json:"root"`
	Filename  string `json:"filename"`
	Format    string `json:"format"`
	MediaType string `json:"media_type"`
	SizeBytes int64  `json:"size_bytes"`
	Position  int    `json:"position"`
	Device    string `json:"device"`
	Inode     string `json:"inode"`
	Size      string `json:"size"`
	Mtime     string `json:"mtime"`
	Ctime     string `json:"ctime"`
}

type BookAssets struct {
	Key         string        `json:"key"`
	BookID      string        `json:"book_id"`
	Unavailable bool          `json:"unavailable"`
	Assets      []AssetRecord `json:"assets"`
}

type LibraryAssets struct {
	Books []BookAssets `json:"books"`
}

type AccountRecord struct {
	Username     string          `json:"username"`
	ID           string          `json:"id"`
	Name         string          `json:"name"`
	Deleted      bool            `json:"deleted"`
	DigestPrefix string          `json:"digest_prefix"`
	Authenticate map[string]bool `json:"authenticate"`
}

type Accounts struct {
	Accounts []AccountRecord `json:"accounts"`
}

type ColumnRecord struct {
	Table           string `json:"table"`
	Column          string `json:"column"`
	ID              string `json:"id"`
	Scheme          string `json:"scheme"`
	Null            bool   `json:"null"`
	Compressed      bool   `json:"compressed"`
	PlaintextSHA256 string `json:"plaintext_sha256"`
	PlaintextBytes  int    `json:"plaintext_bytes"`
}

type TamperRecord struct {
	Name            string `json:"name"`
	Envelope        string `json:"envelope"`
	Outcome         string `json:"outcome"`
	RailsClass      string `json:"rails_class"`
	Category        string `json:"category"`
	PlaintextSHA256 string `json:"plaintext_sha256"`
}

type Encryption struct {
	Columns  []ColumnRecord `json:"columns"`
	Tampered []TamperRecord `json:"tampered"`
}

type ResponseCase struct {
	Name         string          `json:"name"`
	Path         string          `json:"path"`
	Token        *string         `json:"token"`
	Status       int             `json:"status"`
	CacheControl *string         `json:"cache_control"`
	Compare      string          `json:"compare"`
	Body         json.RawMessage `json:"body"`
	BodyBytes    int             `json:"body_bytes"`
}

type Refusal struct {
	Name      string `json:"name"`
	Path      string `json:"path"`
	Token     string `json:"token"`
	GoOutcome string `json:"go_outcome"`
}

type Responses struct {
	Cases    []ResponseCase `json:"cases"`
	Refusals []Refusal      `json:"refusals"`
}

type Candidate struct {
	Label string `json:"label"`
	Value string `json:"value"`
}

type UserCredentials struct {
	Password   string      `json:"password"`
	Candidates []Candidate `json:"candidates"`
}

type EncryptionKeys struct {
	PrimaryKey        string `json:"primary_key"`
	DeterministicKey  string `json:"deterministic_key"`
	KeyDerivationSalt string `json:"key_derivation_salt"`
	HashDigest        string `json:"hash_digest"`
	LegacyHashDigest  string `json:"legacy_hash_digest"`
}

type Credentials struct {
	Encryption EncryptionKeys             `json:"encryption"`
	Users      map[string]UserCredentials `json:"users"`
	Tokens     map[string]string          `json:"tokens"`
}
