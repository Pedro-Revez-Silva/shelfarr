import { useEffect, useMemo, useState } from "react";
import type { ReaderPublication, StoredProgress } from "../contract";
import type { OfferedPlace } from "../reader/EpubReader";
import { samePlace } from "../reader/shared";
import { announceChange, type Offline } from "./context";
import { describeLocator, deviceIsLater, rememberAccountPlace, type DevicePlace, type SavedBook } from "./model";
import { formatMoment, uploadText } from "./text";

export type RememberedPlace = {
  remember: (progress: StoredProgress) => void;
  offer: (assetId: string) => OfferedPlace | null;
  elsewhere: (assetId: string | null) => (OfferedPlace & { assetId: string }) | null;
};

export function offeredDevicePlace(book: SavedBook, server: StoredProgress | null, now: number): DevicePlace | null {
  const device = book.devicePlace;
  if (!device || device.asset_id !== book.asset.id) return null;
  if (server && server.asset_id === device.asset_id && samePlace({ asset_id: device.asset_id, locator: device.locator }, server)) return null;
  if (device.upload) return device.upload.state === "pending" || device.upload.state === "held" ? device : null;
  const learnedAt = book.accountPlace && server && book.accountPlace.version === server.version ? book.accountPlace.learnedAt : now;
  return deviceIsLater(device, server ? { observedAt: server.observed_at, learnedAt } : null) ? device : null;
}

function offerFor(device: DevicePlace): OfferedPlace {
  const status = device.upload?.state === "held" ? uploadText(device.upload) : "It is being sent to your account.";
  return {
    text: `On ${formatMoment(device.recordedAt)} you reached ${describeLocator(device.locator)} in the copy saved on this device, while offline. ${status}`,
    action: "Go to the place on this device",
    locator: device.locator,
  };
}

export function useRememberedPlace(offline: Offline | null, account: string, publication: ReaderPublication): RememberedPlace {
  const [device, setDevice] = useState<DevicePlace | null>(null);

  useEffect(() => {
    if (!offline?.confirmation) return;
    let current = true;
    const load = async () => {
      const book = await offline.store.book(account, publication.id);
      if (!book || !current) return;
      setDevice(offeredDevicePlace(book, publication.progress, Date.now()));
      if (rememberAccountPlace(book, publication.progress, Date.now()) !== book) {
        await offline.store.updateBook(account, publication.id, (stored) => rememberAccountPlace(stored, publication.progress, Date.now()), Date.now());
      }
    };
    load().catch(() => undefined);
    return () => {
      current = false;
    };
  }, [offline, account, publication]);

  const [remember] = useState(() => (progress: StoredProgress) => {
    if (!offline?.confirmation) return;
    const store = offline.store;
    void (async () => {
      if (!(await store.book(account, publication.id))) return;
      if ((await store.updateBook(account, publication.id, (stored) => rememberAccountPlace(stored, progress, Date.now()), Date.now())) === "updated") announceChange();
    })().catch(() => undefined);
  });

  const offered = useMemo(() => (device ? offerFor(device) : null), [device]);
  const listed = device !== null && publication.assets.some((asset) => asset.id === device.asset_id);
  return {
    remember,
    offer: (assetId) => (offered && device?.asset_id === assetId ? offered : null),
    elsewhere: (assetId) => (offered && device && listed && device.asset_id !== assetId ? { ...offered, action: "Open that file at the place on this device", assetId: device.asset_id } : null),
  };
}
