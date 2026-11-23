import type { SettingField } from "../contract";
import type { Drafts } from "../draft";
import type { RecordValues } from "../downloads/api";
import { changedKeys, submission } from "../downloads/forms";
import type { AcquisitionProvider, Providers } from "./contract";

export const MEDIA_KEY = "media";

export const MEDIA_TYPES = [
  { value: "ebooks", label: "Ebooks", attribute: "supports_ebooks" },
  { value: "audiobooks", label: "Audiobooks", attribute: "supports_audiobooks" },
  { value: "comicbooks", label: "Comics & Manga", attribute: "supports_comicbooks" },
] as const;

type Supports = Pick<AcquisitionProvider, "supports_ebooks" | "supports_audiobooks" | "supports_comicbooks">;

function field(key: string, label: string, input: SettingField["input"], description: string, extra: Partial<SettingField> = {}): SettingField {
  return { key, label, input, description, value: "", ...extra };
}

export function providerFields(provider: AcquisitionProvider | null): { basic: SettingField[]; advanced: SettingField[] } {
  return {
    basic: [
      field("name", "Name", "text", "Shown in Shelfarr and beside the copies this provider finds.", { placeholder: "Local provider" }),
      field("url", "Address", "url", "The provider's base address with http or https. It must answer POST /search and POST /acquire; Test calls GET /health.", { placeholder: "http://192.168.1.50:4567" }),
      field("api_key", "Bearer token", "secret", "Optional. Sent as a bearer token with every call to this provider.", { configured: provider?.api_key_saved ?? false, clearable: false }),
      field(MEDIA_KEY, "Book types", "events", "Shelfarr asks this provider only for requests of the ticked types.", { options: MEDIA_TYPES.map(({ value, label }) => ({ value, label })) }),
      field("allow_private_network", "Allow private network", "toggle", "Lets this provider and the download links it returns use local addresses such as localhost or 192.168.x.x. Turn this on only for a provider on your own network."),
      field("enabled", "Use this provider", "toggle", "A turned-off provider is not searched, and copies it already found cannot be downloaded."),
    ],
    advanced: [field("timeout_seconds", "Timeout in seconds", "number", "How long Shelfarr waits for this provider to answer a search or a download. Test waits at most 10 seconds.", { min: 1, max: 120 })],
  };
}

export const PROVIDER_KEYS = ["name", "url", "api_key", MEDIA_KEY, "allow_private_network", "enabled", "timeout_seconds"];

export function mediaOf(supports: Supports): string[] {
  return MEDIA_TYPES.filter((type) => supports[type.attribute]).map((type) => type.value);
}

export function mediaLabels(supports: Supports): string[] {
  return MEDIA_TYPES.filter((type) => supports[type.attribute]).map((type) => type.label);
}

export function initialProviderDraft(provider: AcquisitionProvider | null, defaults: Providers["defaults"]): Drafts {
  const source = provider ?? defaults;
  return {
    name: provider?.name ?? "",
    url: provider?.url ?? "",
    api_key: "",
    [MEDIA_KEY]: mediaOf(source),
    allow_private_network: source.allow_private_network,
    enabled: source.enabled,
    timeout_seconds: String(source.timeout_seconds),
  };
}

export function providerSubmission(provider: AcquisitionProvider | null, drafts: Drafts, initial: Drafts): RecordValues {
  const keys = provider ? changedKeys(PROVIDER_KEYS, drafts, initial) : PROVIDER_KEYS;
  const values = submission(keys.filter((key) => key !== MEDIA_KEY), drafts);
  if (keys.includes(MEDIA_KEY)) {
    const chosen = drafts[MEDIA_KEY];
    const media = Array.isArray(chosen) ? chosen : [];
    for (const type of MEDIA_TYPES) values[type.attribute] = media.includes(type.value);
  }
  return values;
}
