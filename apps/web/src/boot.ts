import { bootSchema, type Boot } from "./contract";

export class BootError extends Error {}

export function readBoot(document: Document): Boot {
  const element = document.getElementById("shelfarr-boot");
  if (!element?.textContent) throw new BootError("The page did not say which account it was built for");
  let value: unknown;
  try {
    value = JSON.parse(element.textContent);
  } catch {
    throw new BootError("The page's startup data is damaged");
  }
  const parsed = bootSchema.safeParse(value);
  if (!parsed.success) throw new BootError("The page's startup data has an unexpected shape");
  return parsed.data;
}

export function readCsrfToken(document: Document): string | null {
  return document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content || null;
}
