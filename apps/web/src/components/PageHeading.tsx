import { useEffect, useRef, type ReactNode } from "react";

let firstPage = true;

export function PageHeading({ id, children, className }: { id: string; children: ReactNode; className?: string }) {
  const ref = useRef<HTMLHeadingElement>(null);
  useEffect(() => {
    if (firstPage) {
      firstPage = false;
      return;
    }
    ref.current?.focus({ preventScroll: true });
  }, []);
  return (
    <h1 id={id} ref={ref} tabIndex={-1} className={className}>
      {children}
    </h1>
  );
}

export function resetFirstPage() {
  firstPage = true;
}

export function markPageNavigated() {
  firstPage = false;
}
