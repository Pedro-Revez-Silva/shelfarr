import { useEffect, useId, useRef, useState, useSyncExternalStore } from "react";
import type { ProgressPlace, ReaderPublication, StoredProgress } from "../contract";
import { useServices } from "../services";
import { AudioSession, PLAYBACK_RATES, type AudioState } from "./audio";
import { playKey } from "./keys";
import { clockTime } from "./progress";

type Props = {
  publication: ReaderPublication;
  record: (place: ProgressPlace) => void;
  flush: () => void;
  registerPlace: (show: ((progress: StoredProgress) => void) | null) => void;
};

export function AudioPlayer({ publication, record, flush, registerPlace }: Props) {
  const { revalidate } = useServices();
  const audio = useRef<HTMLAudioElement>(null);
  const [session, setSession] = useState<AudioSession | null>(null);

  useEffect(() => {
    const element = audio.current;
    if (!element) return;
    const created = new AudioSession(element, publication.assets, publication.progress, { record, flush, failed: revalidate });
    setSession(created);
    const leave = () => created.settle();
    window.addEventListener("pagehide", leave);
    return () => {
      window.removeEventListener("pagehide", leave);
      created.settle();
      flush();
      created.destroy();
      setSession(null);
    };
  }, [publication, record, flush, revalidate]);

  useEffect(() => {
    if (!session) return;
    const onKey = (event: KeyboardEvent) => {
      if (!playKey(event)) return;
      event.preventDefault();
      session.toggle();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [session]);

  useEffect(() => {
    if (!session) return;
    registerPlace((progress) => session.showRemote(progress));
    return () => registerPlace(null);
  }, [registerPlace, session]);

  return (
    <section className="player" aria-label="Audiobook player">
      <audio ref={audio} preload="metadata" />
      {session ? <PlayerControls session={session} publication={publication} /> : null}
    </section>
  );
}

function stateLabel(state: AudioState): string {
  if (state.problem === "load") return "This track couldn't be loaded.";
  if (!state.ready || state.buffering) return "Loading…";
  if (state.finished) return "Finished";
  return state.playing ? "Playing" : "Paused";
}

function problemText(state: AudioState): string | null {
  switch (state.problem) {
    case "blocked":
      return "The browser didn't let playback start by itself. Press Play to start listening; nothing was saved.";
    case "failed":
      return "Playback couldn't start. Check your connection, then press Play again.";
    case "load":
      return "This track couldn't be loaded. Check your connection or sign in again, then choose the track again.";
    case null:
      return null;
  }
}

function PlayerControls({ session, publication }: { session: AudioSession; publication: ReaderPublication }) {
  const state = useSyncExternalStore(session.subscribe, session.getState, session.getState);
  const seekId = useId();
  const trackId = useId();
  const speedId = useId();
  const seek = useRef<HTMLInputElement>(null);
  const [scrub, setScrub] = useState<number | null>(null);
  const tracks = publication.assets;
  const duration = Number.isFinite(state.duration) ? state.duration : 0;
  const shown = scrub ?? state.position;

  useEffect(() => {
    const element = seek.current;
    if (!element) return;
    const commit = () => {
      session.seek(Number(element.value));
      setScrub(null);
    };
    element.addEventListener("change", commit);
    return () => element.removeEventListener("change", commit);
  }, [session]);

  const problem = problemText(state);
  return (
    <>
      <p className="player-track">
        Track {state.track + 1} of {tracks.length}: <span className="player-track-name">{tracks[state.track]?.filename}</span>
      </p>
      <div className="player-seek">
        <label htmlFor={seekId}>Position in this track</label>
        <input
          ref={seek}
          id={seekId}
          type="range"
          min={0}
          max={Math.max(duration, 0)}
          step={1}
          value={Math.min(shown, duration)}
          disabled={!state.ready}
          aria-valuetext={`${clockTime(shown)} of ${clockTime(duration)}`}
          onChange={(event) => setScrub(Number(event.currentTarget.value))}
        />
        <p className="player-times">
          <span>{clockTime(shown)}</span>
          <span>{state.ready ? clockTime(duration) : "—"}</span>
        </p>
      </div>
      <div className="player-buttons">
        <button type="button" className="button" disabled={!state.ready} onClick={() => session.skipBack()}>
          Back 15 s
        </button>
        <button type="button" className="button button--primary button--large player-play" disabled={!state.ready && state.problem !== "load"} onClick={() => session.toggle()}>
          {state.playing ? "Pause" : "Play"}
        </button>
        <button type="button" className="button" disabled={!state.ready} onClick={() => session.skipForward()}>
          Forward 30 s
        </button>
      </div>
      <div className="player-options">
        <label className="reader-field" htmlFor={trackId}>
          <span>Track</span>
          <select id={trackId} value={state.track} onChange={(event) => session.chooseTrack(Number(event.currentTarget.value))}>
            {tracks.map((track, index) => (
              <option key={track.id} value={index}>
                {`${index + 1}. ${track.filename}`}
              </option>
            ))}
          </select>
        </label>
        <div className="player-track-buttons">
          <button type="button" className="button" disabled={state.track === 0} onClick={() => session.chooseTrack(state.track - 1)}>
            Previous track
          </button>
          <button type="button" className="button" disabled={state.track + 1 >= tracks.length} onClick={() => session.chooseTrack(state.track + 1)}>
            Next track
          </button>
        </div>
        <label className="reader-field" htmlFor={speedId}>
          <span>Speed</span>
          <select id={speedId} value={String(state.rate)} onChange={(event) => session.setRate(Number(event.currentTarget.value))}>
            {PLAYBACK_RATES.map((rate) => (
              <option key={rate} value={String(rate)}>
                {`${rate}×`}
              </option>
            ))}
          </select>
        </label>
      </div>
      <p className="player-state">{stateLabel(state)}</p>
      {problem ? (
        <p className="form-error reader-error" role="alert">
          {problem}
        </p>
      ) : null}
    </>
  );
}
