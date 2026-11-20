import { useEffect, useMemo, useRef, useState } from "react";
import type { ReaderPublication, StoredProgress } from "../contract";
import type { OfferedPlace } from "../reader/EpubReader";
import { samePlace } from "../reader/shared";
import { announceChange, type Offline } from "./context";
import { describeLocator, laterDevicePlace, rememberAccountPlace, type DevicePlace } from "./model";
import { formatMoment } from "./text";

export type RememberedPlace = { remember: (progress: StoredProgress) => void; offer: (assetId: string) => OfferedPlace | null };

export function deviceOffer(device: DevicePlace, server: StoredProgress | null): OfferedPlace | null {
  if (server && server.asset_id === device.asset_id && samePlace({ asset_id: device.asset_id, locator: device.locator }, server)) return null;
  return {
    text: `On ${formatMoment(device.recordedAt)} you reached ${describeLocator(device.locator)} in the copy saved on this device, while offline. That place is kept on this device only; it isn't in your account.`,
    action: "Go to the place on this device",
    locator: device.locator,
  };
}

export function useRememberedPlace(offline: Offline | null, account: string, publication: ReaderPublication): RememberedPlace {
  const [device, setDevice] = useState<DevicePlace | null>(null);
  const saved = useRef(false);

  useEffect(() => {
    if (!offline?.confirmation) return;
    let current = true;
    const load = async () => {
      const book = await offline.store.book(account, publication.id);
      if (!book || !current) return;
      saved.current = true;
      setDevice(laterDevicePlace(book));
      const changed = rememberAccountPlace(book, publication.progress, Date.now());
      if (changed !== book) await offline.store.updateBook(account, publication.id, (stored) => rememberAccountPlace(stored, publication.progress, Date.now()), Date.now());
    };
    load().catch(() => undefined);
    return () => {
      current = false;
    };
  }, [offline, account, publication]);

  const [remember] = useState(() => (progress: StoredProgress) => {
    if (!offline?.confirmation || !saved.current) return;
    offline.store
      .updateBook(account, publication.id, (stored) => rememberAccountPlace(stored, progress, Date.now()), Date.now())
      .then(announceChange, () => undefined);
  });

  const offered = useMemo(() => (device ? deviceOffer(device, publication.progress) : null), [device, publication.progress]);
  return { remember, offer: (assetId) => (offered && device?.asset_id === assetId ? offered : null) };
}
