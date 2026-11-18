import type { SaveState } from "./progress";
import { clockTime, describePlace } from "./progress";

type Props = {
  state: SaveState;
  onRetry: () => void;
  onKeep: () => void;
  onUseRemote: () => void;
  onDismiss: () => void;
};

function message(state: SaveState): string {
  switch (state.kind) {
    case "idle":
      return "Your place is saved when you turn a page, seek, pause or change track.";
    case "saving":
      return "Saving your place…";
    case "saved":
      return "Your place is saved to your account.";
    case "uncertain":
      return "Couldn't confirm that your place was saved. Check your connection, then retry; the same place and time are sent again.";
    case "token_refused":
      return "Your place wasn't saved because the page's security check expired. Retry to send the same place again.";
    case "rejected":
      return `Your account didn't accept this place: ${state.message}`;
    case "remote":
      return `A later place was saved on another device (${describePlace(state.remote, clockTime)}).`;
    case "conflict":
      return `Another device saved a different place (${describePlace(state.remote, clockTime)}; this device: ${describePlace(state.local, clockTime)}). Which place should your account keep?`;
    case "stopped":
      return "Saving stopped because this page is no longer signed in to the same account.";
  }
}

export function SaveStatus({ state, onRetry, onKeep, onUseRemote, onDismiss }: Props) {
  const urgent = state.kind === "uncertain" || state.kind === "token_refused" || state.kind === "rejected" || state.kind === "conflict" || state.kind === "stopped";
  const announced = urgent ? "alert" : state.kind === "remote" ? "status" : undefined;
  return (
    <div className={`save-status${urgent ? " save-status--attention" : ""}`} data-state={state.kind}>
      <p role={announced} className="save-status-text">
        {message(state)}
      </p>
      {state.kind === "uncertain" || state.kind === "token_refused" ? (
        <button type="button" className="button" onClick={onRetry}>
          Retry saving
        </button>
      ) : null}
      {state.kind === "remote" ? (
        <span className="save-status-actions">
          <button type="button" className="button button--primary" onClick={onUseRemote}>
            Go to that place
          </button>
          <button type="button" className="button button--subtle" onClick={onDismiss}>
            Stay here
          </button>
        </span>
      ) : null}
      {state.kind === "conflict" ? (
        <span className="save-status-actions">
          <button type="button" className="button button--primary" onClick={onKeep}>
            Keep this device's place
          </button>
          <button type="button" className="button" onClick={onUseRemote}>
            Use the other place
          </button>
        </span>
      ) : null}
    </div>
  );
}
