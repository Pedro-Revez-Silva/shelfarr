import { Link } from "@tanstack/react-router";
import { useEffect, useRef } from "react";

export type RailItem = { id: string; label: string; to: string; params?: Record<string, string>; current: boolean };

export function SettingsRail({ label, items }: { label: string; items: RailItem[] }) {
  const list = useRef<HTMLUListElement>(null);
  const currentId = items.find((item) => item.current)?.id;
  useEffect(() => {
    const current = list.current?.querySelector<HTMLElement>('[aria-current="page"]');
    if (current && list.current && list.current.scrollWidth > list.current.clientWidth) {
      list.current.scrollLeft = current.offsetLeft - list.current.offsetLeft - 16;
    }
  }, [currentId]);
  return (
    <nav className="settings-rail" aria-label={label}>
      <ul ref={list}>
        {items.map((item) => (
          <li key={item.id}>
            <Link to={item.to} params={item.params} className="settings-rail-link" aria-current={item.current ? "page" : undefined} activeOptions={{ exact: true }} activeProps={{}}>
              {item.label}
            </Link>
          </li>
        ))}
      </ul>
    </nav>
  );
}
