declare module "*/app/javascript/web_preview_offline_release.js" {
  export function previewDatabaseName(base: string): string;
  export function releasePreviewAccount(base: string, askedAt?: number, factory?: IDBFactory): Promise<boolean>;
}
