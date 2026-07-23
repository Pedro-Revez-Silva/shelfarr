window.addEventListener("popstate", (event) => {
  window.settingsNavigationGuard?.(event);
}, true);
