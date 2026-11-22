import { useState, type MouseEvent, type ReactNode } from "react";
import { useServices } from "../services";

export type BackTarget = { href: string; label: string; returns: boolean };

export function backTarget(referrer: string, id: string, mount: string, origin: string): BackTarget {
  const details = `${mount}/library/${id}`;
  let from: URL | null = null;
  try {
    from = referrer ? new URL(referrer) : null;
  } catch {
    from = null;
  }
  if (from && from.origin === origin && from.pathname === `${mount}/library`) return { href: `${mount}/library${from.search}`, label: "Back to the library", returns: true };
  return { href: details, label: "Back to the book", returns: from !== null && from.origin === origin && from.pathname === details };
}

async function goBack(event: MouseEvent<HTMLAnchorElement>, target: BackTarget, beforeLeave: (() => Promise<void>) | undefined) {
  if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
  event.preventDefault();
  await beforeLeave?.();
  if (target.returns && window.history.length > 1) window.history.back();
  else window.location.assign(target.href);
}

type FrameProps = {
  id: string;
  title: string;
  author: string | null;
  kind?: string;
  children: ReactNode;
  footer?: ReactNode;
  tools?: ReactNode;
  back?: BackTarget;
  beforeLeave?: () => Promise<void>;
};

export function ReaderFrame({ id, title, author, kind, children, footer, tools, back, beforeLeave }: FrameProps) {
  const { boot } = useServices();
  const [target] = useState(() => back ?? backTarget(document.referrer, id, boot.mount, window.location.origin));
  return (
    <div className="reader">
      <header className="reader-header">
        <a className="back-link reader-back" href={target.href} onClick={(event) => void goBack(event, target, beforeLeave)}>
          <span aria-hidden="true">←</span>
          {target.label}
        </a>
        <div className="reader-title">
          {kind ? <p className="eyebrow">{kind}</p> : null}
          <h1 id="reader-heading">{title}</h1>
          {author ? <p className="reader-author">{author}</p> : null}
        </div>
        {tools ? <div className="reader-tools">{tools}</div> : null}
      </header>
      <main id="main" className="reader-main" aria-labelledby="reader-heading">
        {children}
      </main>
      {footer ? <footer className="reader-footer">{footer}</footer> : null}
    </div>
  );
}
