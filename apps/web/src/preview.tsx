import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { BootError, readCsrfToken, readStartup } from "./boot";
import { GoApp } from "./go/GoApp";
import { createAppRouter } from "./router";
import { createServices } from "./services";
import "./styles.css";

const container = document.getElementById("root");
if (!container) throw new Error("The page has no root element");

try {
  const startup = readStartup(document);
  if (startup.kind === "go") {
    createRoot(container).render(
      <StrictMode>
        <GoApp boot={startup.boot} />
      </StrictMode>,
    );
  } else {
    const services = createServices({ boot: startup.boot, csrfToken: () => readCsrfToken(document) });
    const router = createAppRouter({ basepath: startup.boot.mount });
    createRoot(container).render(
      <StrictMode>
        <App services={services} router={router} />
      </StrictMode>,
    );
  }
} catch (error) {
  const message = error instanceof BootError ? error.message : "The library preview could not start";
  const classic = container.querySelector("a")?.getAttribute("href") ?? null;
  container.replaceChildren();
  const paragraph = document.createElement("p");
  paragraph.className = "boot-message";
  paragraph.textContent = classic ? `${message}. ` : `${message}.`;
  if (classic) {
    const link = document.createElement("a");
    link.href = classic;
    link.textContent = "Open the classic library";
    paragraph.append(link);
  }
  container.append(paragraph);
}
