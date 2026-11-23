import type { SettingField } from "../contract";
import { REMOVE_SAVED, same, type DraftValue, type Drafts } from "../draft";
import type { RecordValues } from "./api";
import type { ClientType, DownloadClient, Downloads, RoutingRule } from "./contract";

type Kind = "torrent" | "usenet";

function field(key: string, label: string, input: SettingField["input"], description: string, extra: Partial<SettingField> = {}): SettingField {
  return { key, label, input, description, value: "", ...extra };
}

function apiKeyHint(type: ClientType): string {
  if (type.value === "qbittorrent") return "For qBittorrent 5.2 or later, create a key under Web UI › Preferences › Web UI. When set, it replaces the username and password.";
  if (type.value === "sabnzbd") return "Find it in SABnzbd under Config › General.";
  return "";
}

export function clientFields(type: ClientType | undefined, client: DownloadClient | null): { basic: SettingField[]; advanced: SettingField[] } {
  const basic: SettingField[] = [field("url", "Address", "url", "Include the protocol (http or https) and the port.", { placeholder: "http://192.168.1.100:8080" })];
  if (type?.authentication) {
    basic.push(field("username", "Username", "code", "", { placeholder: "admin" }));
    basic.push(field("password", "Password", "secret", "", { configured: client?.password_saved ?? false, clearable: false }));
  }
  if (type?.api_key) basic.push(field("api_key", "API key", "secret", apiKeyHint(type), { configured: client?.api_key_saved ?? false, clearable: true }));
  basic.push(field("category", "Category", "code", "Optional. Downloads are added to this category.", { placeholder: "shelfarr" }));
  basic.push(field("download_path", "Download folder", "code", "Where finished downloads appear inside Shelfarr's container, for example /downloads. Leave blank to use the path mapping below.", { placeholder: "/downloads" }));
  basic.push(field("enabled", "Use this client", "toggle", "Turned-off clients are skipped and not checked."));
  const advanced = type?.verification
    ? [
        field("torrent_verification_max_attempts", "Torrent checks after adding", "number", "How many times Shelfarr checks that qBittorrent has a newly added torrent.", { min: 1 }),
        field("torrent_verification_wait_time", "Seconds between checks", "number", "Increase this if qBittorrent runs behind a VPN or a slow network.", { min: 0 }),
      ]
    : [];
  return { basic, advanced };
}

export const NAME_FIELD = field("name", "Name", "text", "Shown in Shelfarr only.", { placeholder: "Home qBittorrent" });

export function initialClientDraft(client: DownloadClient | null, defaults: Downloads["defaults"]): Drafts {
  return {
    name: client?.name ?? "",
    client_type: client?.client_type ?? defaults.client_type,
    url: client?.url ?? "",
    username: client?.username ?? "",
    password: "",
    api_key: "",
    category: client?.category ?? "",
    download_path: client?.download_path ?? "",
    enabled: client?.enabled ?? defaults.enabled,
    torrent_verification_max_attempts: String(client?.torrent_verification_max_attempts ?? defaults.torrent_verification_max_attempts),
    torrent_verification_wait_time: String(client?.torrent_verification_wait_time ?? defaults.torrent_verification_wait_time),
  };
}

export function clientKeys(type: ClientType | undefined, client: DownloadClient | null): string[] {
  const { basic, advanced } = clientFields(type, client);
  return ["name", "client_type", ...basic.map((entry) => entry.key), ...advanced.map((entry) => entry.key)];
}

const SECRET_KEYS = new Set(["password", "api_key"]);

function secretTyped(value: DraftValue | undefined): boolean {
  return value === REMOVE_SAVED || (typeof value === "string" && value.trim() !== "");
}

export function changedKeys(keys: string[], drafts: Drafts, initial: Drafts): string[] {
  return keys.filter((key) => (SECRET_KEYS.has(key) ? secretTyped(drafts[key]) : !same(drafts[key], initial[key])));
}

export function submission(keys: string[], drafts: Drafts): RecordValues {
  const values: RecordValues = {};
  for (const key of keys) {
    const value = drafts[key];
    if (typeof value === "string" || typeof value === "boolean") {
      if (!SECRET_KEYS.has(key) || secretTyped(value)) values[key] = value;
    } else if (value === REMOVE_SAVED) {
      values[key] = "";
      if (key === "api_key") values.clear_api_key = "1";
    }
  }
  return values;
}

export function clientSubmission(type: ClientType | undefined, client: DownloadClient | null, drafts: Drafts, initial: Drafts): RecordValues {
  const keys = clientKeys(type, client);
  return submission(client ? changedKeys(keys, drafts, initial) : keys, drafts);
}

export function initialRuleDraft(rule: RoutingRule | null, downloads: Downloads): Drafts {
  return {
    provider: rule?.provider ?? downloads.providers[0]?.value ?? "",
    download_type: rule?.download_type ?? downloads.download_types[0]?.value ?? "torrent",
    indexer_name: rule?.indexer_name ?? "",
    download_client_id: rule?.client_id ?? "",
    enabled: rule?.enabled ?? true,
  };
}

export const RULE_KEYS = ["provider", "download_type", "indexer_name", "download_client_id", "enabled"];

export function clientsOfKind(downloads: Downloads, kind: string): DownloadClient[] {
  return downloads.clients.filter((client) => client.kind === kind);
}

export function ruleTypeChange(drafts: Drafts, downloads: Downloads, kind: string): Drafts {
  const chosen = downloads.clients.find((client) => client.id === drafts.download_client_id);
  return { ...drafts, download_type: kind, download_client_id: chosen && chosen.kind === kind ? chosen.id : "" };
}

const SERVER_FIELDS: Record<string, string> = { download_client: "download_client_id", normalized_indexer_name: "indexer_name" };

export function fieldErrors(errors: { field: string; message: string }[], known: string[]): { byField: Record<string, string>; general: string[] } {
  const byField: Record<string, string> = {};
  const general: string[] = [];
  for (const error of errors) {
    const key = SERVER_FIELDS[error.field] ?? error.field;
    if (known.includes(key)) byField[key] = byField[key] ? `${byField[key]} ${error.message}` : error.message;
    else general.push(error.message);
  }
  return { byField, general };
}

export function sameTypeNeighbours(clients: DownloadClient[], client: DownloadClient): { up: boolean; down: boolean; above: string | null; below: string | null; position: number; total: number } {
  const peers = clients.filter((entry) => entry.client_type === client.client_type);
  const index = peers.findIndex((entry) => entry.id === client.id);
  const above = index > 0 ? (peers[index - 1]?.id ?? null) : null;
  const below = index >= 0 ? (peers[index + 1]?.id ?? null) : null;
  return { up: above !== null, down: below !== null, above, below, position: index + 1, total: peers.length };
}

const FIELD_LABELS: Record<string, string> = {
  username: "Username",
  password: "Password",
  api_key: "API key",
  torrent_verification_max_attempts: "Torrent checks after adding",
  torrent_verification_wait_time: "Seconds between checks",
};

export function fieldLabel(key: string): string {
  return FIELD_LABELS[key] ?? key;
}

export function kindLabel(kind: Kind): string {
  return kind === "torrent" ? "Torrent" : "Usenet";
}
