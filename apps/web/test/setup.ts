import { afterEach } from "bun:test";
import { GlobalRegistrator } from "@happy-dom/global-registrator";

GlobalRegistrator.register({ url: "http://shelf.test/sub/preview/library", width: 1024, height: 768 });

const { cleanup } = await import("@testing-library/react");
afterEach(() => {
  cleanup();
  window.sessionStorage.clear();
  window.history.replaceState(null, "");
});
