import { useEffect } from "react";
import { useServices } from "./services";

const SUFFIX = "Shelfarr";

export function usePageTitle(title: string | null) {
  const { mode } = useServices();
  useEffect(() => {
    if (mode !== "go" || !title) return;
    document.title = `${title} · ${SUFFIX}`;
  }, [mode, title]);
}

export function useDocumentTitle(title: string) {
  useEffect(() => {
    document.title = `${title} · ${SUFFIX}`;
  }, [title]);
}
