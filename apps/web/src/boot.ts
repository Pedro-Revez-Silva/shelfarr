import { bootSchema, goBootSchema, type Boot, type GoBoot } from "./contract";

export class BootError extends Error {}

export type Startup = { kind: "rails"; boot: Boot } | { kind: "go"; boot: GoBoot };

export function readStartup(document: Document): Startup {
  const value = readBootValue(document);
  if (typeof value === "object" && value !== null && "runtime" in value) {
    const go = goBootSchema.safeParse(value);
    if (!go.success) throw new BootError("The page's startup data has an unexpected shape");
    return { kind: "go", boot: go.data };
  }
  return { kind: "rails", boot: parseRailsBoot(value) };
}

export function readBoot(document: Document): Boot {
  return parseRailsBoot(readBootValue(document));
}

function readBootValue(document: Document): unknown {
  const element = document.getElementById("shelfarr-boot");
  if (!element?.textContent) throw new BootError("The page did not say which account it was built for");
  try {
    return JSON.parse(element.textContent);
  } catch {
    throw new BootError("The page's startup data is damaged");
  }
}

function parseRailsBoot(value: unknown): Boot {
  const parsed = bootSchema.safeParse(value);
  if (!parsed.success) throw new BootError("The page's startup data has an unexpected shape");
  return parsed.data;
}

export function readCsrfToken(document: Document): string | null {
  return document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content || null;
}
