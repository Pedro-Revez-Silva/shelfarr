import type { SubmittedValue, SubmittedValues } from "./api";
import type { SettingField, SettingGroup } from "./contract";

export type DraftValue = string | boolean | string[];
export type Drafts = Record<string, DraftValue>;

function asList(value: SettingField["value"]): string[] {
  if (Array.isArray(value)) return value;
  if (typeof value === "string" && value !== "") return [value];
  return [];
}

export function initialDraft(field: SettingField): DraftValue {
  const value = field.value;
  switch (field.input) {
    case "toggle":
      return value === true || value === "true";
    case "secret":
      return "";
    case "order":
    case "events":
    case "libraries":
      return asList(value);
    case "list":
      return asList(value).join(", ");
    case "url_list":
      return asList(value).join("\n");
    default:
      return value === null || value === undefined ? "" : String(value);
  }
}

export function groupFields(group: SettingGroup): SettingField[] {
  return [...group.fields, ...group.advanced];
}

export function initialDrafts(group: SettingGroup): Drafts {
  return Object.fromEntries(groupFields(group).map((field) => [field.key, initialDraft(field)]));
}

function same(left: DraftValue, right: DraftValue): boolean {
  if (Array.isArray(left) && Array.isArray(right)) return left.length === right.length && left.every((entry, index) => entry === right[index]);
  return left === right;
}

export function editable(field: SettingField): boolean {
  return field.managed_by === undefined;
}

export function changedKeys(group: SettingGroup, drafts: Drafts): string[] {
  return groupFields(group)
    .filter((field) => editable(field))
    .filter((field) => {
      const draft = drafts[field.key];
      if (draft === undefined) return false;
      if (field.input === "secret") return typeof draft === "string" && draft !== "";
      return !same(draft, initialDraft(field));
    })
    .map((field) => field.key);
}

export function submittedValue(field: SettingField, draft: DraftValue): SubmittedValue {
  switch (field.input) {
    case "toggle":
      return draft === true ? "true" : "false";
    case "order":
      return JSON.stringify(Array.isArray(draft) ? draft : []);
    case "events":
      return (Array.isArray(draft) ? draft : []).join(",");
    case "libraries":
      return Array.isArray(draft) ? draft : String(draft);
    default:
      return Array.isArray(draft) ? draft.join(",") : String(draft);
  }
}

export function submission(group: SettingGroup, drafts: Drafts, keys: string[]): SubmittedValues {
  const byKey = new Map(groupFields(group).map((field) => [field.key, field]));
  const values: SubmittedValues = {};
  for (const key of keys) {
    const field = byKey.get(key);
    const draft = drafts[key];
    if (field && draft !== undefined) values[key] = submittedValue(field, draft);
  }
  return values;
}

export function probeValues(group: SettingGroup, drafts: Drafts): SubmittedValues {
  const keys = groupFields(group)
    .filter((field) => editable(field) && !(field.input === "secret" && drafts[field.key] === ""))
    .map((field) => field.key);
  return submission(group, drafts, keys);
}

export function draftText(drafts: Drafts, field: SettingField): string {
  const value = drafts[field.key];
  return typeof value === "string" ? value : String(initialDraft(field));
}

export function isVisible(field: SettingField, group: SettingGroup, drafts: Drafts): boolean {
  const rule = field.visible_when;
  if (rule) {
    const controlling = groupFields(group).find((entry) => entry.key === rule.key);
    const current = drafts[rule.key] ?? (controlling ? initialDraft(controlling) : "");
    if (!rule.in.includes(String(current))) return false;
  }
  if (group.toggle && field.key !== group.toggle) {
    const toggle = groupFields(group).find((entry) => entry.key === group.toggle);
    if (toggle && (drafts[toggle.key] ?? initialDraft(toggle)) !== true) return false;
  }
  return true;
}

export function moveItem(list: string[], index: number, offset: -1 | 1): string[] {
  const target = index + offset;
  if (target < 0 || target >= list.length) return list;
  const next = [...list];
  const [item] = next.splice(index, 1);
  if (item !== undefined) next.splice(target, 0, item);
  return next;
}
