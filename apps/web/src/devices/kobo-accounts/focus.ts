import { useEffect, useRef, type RefObject } from "react";

function focusLost(): boolean {
  return document.activeElement === null || document.activeElement === document.body;
}

export function useFocusStaysInCard(card: RefObject<HTMLElement | null>, heading: RefObject<HTMLElement | null>, change: unknown) {
  const inside = useRef(false);
  useEffect(() => {
    const element = card.current;
    if (!element) return undefined;
    const enter = () => {
      inside.current = true;
    };
    const leave = (event: FocusEvent) => {
      if (event.relatedTarget instanceof Node && !element.contains(event.relatedTarget)) inside.current = false;
    };
    element.addEventListener("focusin", enter);
    element.addEventListener("focusout", leave);
    return () => {
      element.removeEventListener("focusin", enter);
      element.removeEventListener("focusout", leave);
    };
  }, [card]);
  useEffect(() => {
    if (inside.current && focusLost()) heading.current?.focus();
  }, [change, heading]);
}
