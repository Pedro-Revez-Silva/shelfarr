import type { ReaderAsset, StoredProgress } from "../contract";
import { ListeningCheckpoints, type ListeningPlace } from "./shared";

export type AudioProblem = "blocked" | "failed" | "load" | null;

export type AudioState = {
  track: number;
  ready: boolean;
  playing: boolean;
  buffering: boolean;
  finished: boolean;
  position: number;
  duration: number;
  rate: number;
  problem: AudioProblem;
};

export type AudioCallbacks = {
  record: (place: ListeningPlace) => void;
  flush: () => void;
  failed: () => void;
};

export const PLAYBACK_RATES = [0.75, 1, 1.25, 1.5, 1.75, 2] as const;
const SKIP_BACK = 15;
const SKIP_FORWARD = 30;

type Restore = { track: number; position: number } | null;

export class AudioSession {
  private readonly audio: HTMLAudioElement;
  private readonly tracks: ReaderAsset[];
  private readonly callbacks: AudioCallbacks;
  private readonly checkpoints: ListeningCheckpoints;
  private readonly listeners = new Set<() => void>();
  private readonly detach: () => void;
  private snapshot: AudioState;
  private restore: Restore;
  private switching = false;
  private playWhenReady = false;
  private active = true;

  constructor(audio: HTMLAudioElement, tracks: ReaderAsset[], saved: StoredProgress | null, callbacks: AudioCallbacks) {
    this.audio = audio;
    this.tracks = tracks;
    this.callbacks = callbacks;
    this.checkpoints = new ListeningCheckpoints({ record: (place) => this.callbacks.record(place) });
    const savedTrack = saved ? tracks.findIndex((track) => track.id === saved.asset_id) : -1;
    this.restore = savedTrack >= 0 ? { track: savedTrack, position: saved?.position_seconds ?? 0 } : null;
    this.snapshot = { track: Math.max(savedTrack, 0), ready: false, playing: false, buffering: false, finished: false, position: 0, duration: Number.NaN, rate: 1, problem: null };
    const handlers: [keyof HTMLMediaElementEventMap, () => void][] = [
      ["loadedmetadata", () => this.loaded()],
      ["timeupdate", () => this.progressed()],
      ["pause", () => this.paused()],
      ["playing", () => this.update({ playing: true, buffering: false, finished: false, problem: null })],
      ["waiting", () => this.update({ buffering: true })],
      ["canplay", () => this.update({ buffering: false })],
      ["ended", () => this.ended()],
      ["error", () => this.loadFailed()],
    ];
    for (const [name, handler] of handlers) audio.addEventListener(name, handler);
    this.detach = () => {
      for (const [name, handler] of handlers) audio.removeEventListener(name, handler);
    };
    this.open(false);
  }

  getState = (): AudioState => this.snapshot;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  get current(): ReaderAsset {
    const track = this.tracks[this.snapshot.track] ?? this.tracks[0];
    if (!track) throw new Error("An audiobook needs at least one track");
    return track;
  }

  toggle(): void {
    if (this.audio.paused) void this.play();
    else this.audio.pause();
  }

  async play(resume = true): Promise<void> {
    const audio = this.audio;
    if (resume && audio.paused && !audio.ended && this.snapshot.ready) {
      const from = this.checkpoints.resume(audio.currentTime);
      if (from !== audio.currentTime) audio.currentTime = from;
    } else this.checkpoints.active = true;
    try {
      await audio.play();
    } catch (error) {
      if (!this.active) return;
      this.update({ playing: false, problem: error instanceof DOMException && error.name === "NotAllowedError" ? "blocked" : "failed" });
    }
  }

  pause(): void {
    this.audio.pause();
  }

  seek(seconds: number): void {
    const duration = this.audio.duration;
    if (!this.snapshot.ready || !Number.isFinite(duration)) return;
    this.audio.currentTime = Math.max(0, Math.min(duration, seconds));
    this.update({ position: this.audio.currentTime });
    this.deliberate();
  }

  skipBack(): void {
    this.seek(this.audio.currentTime - SKIP_BACK);
  }

  skipForward(): void {
    this.seek(this.audio.currentTime + SKIP_FORWARD);
  }

  chooseTrack(index: number, autoplay = !this.audio.paused): void {
    if (!this.tracks[index] || index === this.snapshot.track) return;
    if (this.snapshot.ready) this.checkpoints.settle(this.audio.currentTime, this.current.id);
    this.restore = null;
    this.snapshot = { ...this.snapshot, track: index };
    this.checkpoints.deliberate(0, this.current.id, !autoplay);
    this.callbacks.flush();
    this.open(autoplay);
  }

  setRate(rate: number): void {
    this.audio.defaultPlaybackRate = rate;
    this.audio.playbackRate = rate;
    this.update({ rate });
  }

  showRemote(progress: StoredProgress): void {
    const index = this.tracks.findIndex((track) => track.id === progress.asset_id);
    if (index < 0) return;
    const position = progress.position_seconds ?? 0;
    if (index !== this.snapshot.track) {
      this.restore = { track: index, position };
      this.snapshot = { ...this.snapshot, track: index };
      this.open(false);
      return;
    }
    if (!this.snapshot.ready) {
      this.restore = { track: index, position };
      return;
    }
    this.audio.currentTime = Math.min(position, this.audio.duration || 0);
    this.checkpoints.restored(this.audio.currentTime, this.current.id);
    this.update({ position: this.audio.currentTime });
  }

  settle(): void {
    if (this.snapshot.ready && !this.switching) this.checkpoints.settle(this.audio.currentTime, this.current.id);
  }

  destroy(): void {
    this.active = false;
    this.detach();
    this.audio.pause();
    this.audio.removeAttribute("src");
    this.audio.load();
    this.listeners.clear();
  }

  private open(autoplay: boolean): void {
    this.switching = true;
    this.playWhenReady = autoplay;
    this.update({ ready: false, buffering: true, position: 0, duration: Number.NaN, problem: null, finished: false });
    this.audio.src = this.current.url;
    this.audio.defaultPlaybackRate = this.snapshot.rate;
    this.audio.playbackRate = this.snapshot.rate;
    this.audio.load();
  }

  private loaded(): void {
    if (!this.active) return;
    const audio = this.audio;
    if (this.restore && this.restore.track === this.snapshot.track) audio.currentTime = Math.min(this.restore.position, audio.duration || 0);
    this.restore = null;
    this.checkpoints.restored(audio.currentTime, this.current.id);
    this.switching = false;
    this.update({ ready: true, buffering: false, position: audio.currentTime, duration: audio.duration });
    if (this.playWhenReady) void this.play(false);
  }

  private progressed(): void {
    if (!this.active || !this.snapshot.ready) return;
    this.update({ position: this.audio.currentTime });
    if (!this.audio.paused) this.checkpoints.tick(this.audio.currentTime, this.current.id);
  }

  private paused(): void {
    if (!this.active) return;
    this.update({ playing: false });
    if (this.switching || !this.snapshot.ready) return;
    this.checkpoints.settle(this.audio.currentTime, this.current.id);
    this.callbacks.flush();
  }

  private ended(): void {
    if (!this.active) return;
    const next = this.snapshot.track + 1;
    if (next >= this.tracks.length) {
      this.update({ finished: true });
      this.paused();
      return;
    }
    this.restore = null;
    this.snapshot = { ...this.snapshot, track: next };
    this.checkpoints.continued(this.current.id);
    this.callbacks.flush();
    this.open(true);
  }

  private deliberate(): void {
    if (!this.snapshot.ready) return;
    this.checkpoints.deliberate(this.audio.currentTime, this.current.id, this.audio.paused);
    this.callbacks.flush();
  }

  private loadFailed(): void {
    if (!this.active || !this.audio.getAttribute("src")) return;
    this.switching = false;
    this.update({ ready: false, playing: false, buffering: false, problem: "load" });
    this.callbacks.failed();
  }

  private update(change: Partial<AudioState>): void {
    this.snapshot = { ...this.snapshot, ...change };
    for (const listener of [...this.listeners]) listener();
  }
}
