import type { UploadFormats } from "./contract";

export type Selection = { files: File[]; folder: boolean };

const AUDIO_TYPES = ["audio/mp4", "audio/mpeg"];

export function supportedExtensions(formats: UploadFormats): string[] {
  return [...formats.audiobook, ...formats.ebook, ...formats.comicbook];
}

export function acceptList(formats: UploadFormats): string {
  return [...supportedExtensions(formats).map((extension) => `.${extension}`), ...AUDIO_TYPES].join(",");
}

export function extensionOf(name: string): string {
  const dot = name.lastIndexOf(".");
  return dot < 0 ? "" : name.slice(dot + 1).toLowerCase();
}

export function supported(files: File[], formats: UploadFormats): File[] {
  const extensions = new Set(supportedExtensions(formats));
  return files.filter((file) => extensions.has(extensionOf(file.name)));
}

export function selectionText(selection: Selection): string {
  const count = selection.files.length;
  if (selection.folder) return `${count} supported ${count === 1 ? "file" : "files"} selected from the folder`;
  if (count === 1) return selection.files[0]?.name ?? "";
  return `${count} files selected`;
}

export function formatBytes(bytes: number): string {
  const units = ["bytes", "KB", "MB", "GB", "TB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  if (unit === 0) return `${bytes} ${bytes === 1 ? "byte" : "bytes"}`;
  return `${value >= 10 ? Math.round(value) : Math.round(value * 10) / 10} ${units[unit]}`;
}

export function bySize(files: File[], maxBytes: number): { fitting: File[]; oversized: File[] } {
  return { fitting: files.filter((file) => file.size <= maxBytes), oversized: files.filter((file) => file.size > maxBytes) };
}

export function oversizedText(oversized: File[], maxBytes: number): string {
  const names = oversized.map((file) => file.name).join(", ");
  const limit = `Shelfarr's ${formatBytes(maxBytes)} limit`;
  return oversized.length === 1 ? `${names} is larger than ${limit}` : `${names} are larger than ${limit}`;
}

function entryFile(entry: FileSystemFileEntry): Promise<File[]> {
  return new Promise((resolve) => {
    entry.file(
      (file) => resolve([file]),
      () => resolve([]),
    );
  });
}

function readAll(entry: FileSystemDirectoryEntry): Promise<FileSystemEntry[]> {
  const reader = entry.createReader();
  const collected: FileSystemEntry[] = [];
  return new Promise((resolve) => {
    const next = () =>
      reader.readEntries(
        (batch) => {
          if (batch.length === 0) return resolve(collected);
          collected.push(...batch);
          next();
        },
        () => resolve(collected),
      );
    next();
  });
}

async function filesOf(entries: FileSystemEntry[]): Promise<File[]> {
  const nested = await Promise.all(
    entries.map(async (entry) => {
      if (entry.isDirectory) return filesOf(await readAll(entry as FileSystemDirectoryEntry));
      return entry.isFile ? entryFile(entry as FileSystemFileEntry) : [];
    }),
  );
  return nested.flat();
}

export type Dropped = { entries: FileSystemEntry[]; files: File[]; folder: boolean };

export function dropped(transfer: DataTransfer): Dropped {
  const entries = Array.from(transfer.items ?? [])
    .map((item) => item.webkitGetAsEntry())
    .filter((entry): entry is FileSystemEntry => entry !== null);
  return { entries, files: Array.from(transfer.files), folder: entries.some((entry) => entry.isDirectory) };
}

export async function droppedSelection(drop: Dropped): Promise<Selection> {
  if (drop.folder) return { files: await filesOf(drop.entries), folder: true };
  return { files: drop.files, folder: false };
}
