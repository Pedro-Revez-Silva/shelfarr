import { Navigate, useRouter } from "@tanstack/react-router";
import { useState } from "react";
import { LEGACY_SETTINGS_TABS } from "./ServerShell";

export function LegacySettingsRedirect() {
  const router = useRouter();
  const [category] = useState(() => LEGACY_SETTINGS_TABS[router.state.location.hash.replace(/^#/, "")] ?? "policy");
  return <Navigate to="/server/$category" params={{ category }} replace />;
}
