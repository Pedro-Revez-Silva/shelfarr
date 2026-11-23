import { getRouteApi, Link, useBlocker, useNavigate } from "@tanstack/react-router";
import { useEffect, useId, useRef, useState, type DragEvent, type FormEvent } from "react";
import { failureKind } from "../api/errors";
import { PageHeading } from "../components/PageHeading";
import { actionFailure } from "../components/requestText";
import { EmptyState, ErrorPanel, Loading } from "../components/States";
import { useSession } from "../queries";
import { useServices } from "../services";
import { usePageTitle } from "../title";
import { useSendUpload, useUploadRequest, useUploads, type UploadSubmission } from "./api";
import type { UploadCreated, UploadFormats, UploadRequest } from "./contract";
import { acceptList, bySize, dropped as readDrop, droppedSelection, formatBytes, oversizedText, selectionText, supported, type Selection } from "./files";
import { BOOK_TYPE_LABELS, UploadList } from "./UploadList";
import "./uploads.css";

const routeApi = getRouteApi("/library/uploads");

export function UploadsPage() {
  const { mode } = useServices();
  usePageTitle("Uploads");
  if (mode !== "rails") {
    return (
      <EmptyState title="That page is not part of this preview">
        <p>Use the navigation to return to your library.</p>
      </EmptyState>
    );
  }
  return <RailsUploads />;
}

function RailsUploads() {
  const search = routeApi.useSearch();
  const navigate = useNavigate();
  const session = useSession();
  const admin = session.data?.admin !== undefined;
  const page = Number(search.page ?? "1");
  const list = useUploads(page);

  return (
    <section aria-labelledby="uploads-heading" className="library uploads-page">
      <header className="page-heading">
        <p className="eyebrow">
          <Link to="/library">Library</Link>
        </p>
        <PageHeading id="uploads-heading">Uploads</PageHeading>
        <p className="lede">Add book files you already have. Shelfarr reads each file name, matches it to a book and puts it in the library.</p>
      </header>

      {list.data ? (
        list.data.can_upload ? (
          <AddBooks key={search.request ?? "library"} requestId={search.request} formats={list.data.formats} maxBytes={list.data.max_bytes} />
        ) : (
          <p className="request-note upload-disabled">Uploads are not currently enabled. An administrator can turn them on in Server ▸ People and access.</p>
        )
      ) : null}

      <UploadList admin={admin} page={page} level={2} title={admin ? "All uploads" : "Uploads on this server"} onPage={(next) => void navigate({ to: "/library/uploads", search: { ...(search.request ? { request: search.request } : {}), ...(next > 1 ? { page: String(next) } : {}) } })} />
    </section>
  );
}

function AddBooks({ requestId, formats, maxBytes }: { requestId: string | undefined; formats: UploadFormats; maxBytes: number }) {
  const valid = requestId === undefined || REQUEST_ID.test(requestId);
  const context = useUploadRequest(valid ? requestId : undefined);
  if (requestId === undefined) return <UploadForm request={null} formats={formats} maxBytes={maxBytes} />;
  if (!valid) return <RequestNotFound />;
  if (context.isPending) return <Loading label="Loading the request…" />;
  if (context.isError) {
    const kind = failureKind(context.error);
    if (kind === "not_found") return <RequestNotFound />;
    if (kind === "conflict") return <p className="request-note upload-disabled">{actionFailure(context.error, "Uploads are not currently enabled.")}</p>;
    return <ErrorPanel error={context.error} onRetry={() => void context.refetch()} />;
  }
  return <UploadForm request={context.data} formats={formats} maxBytes={maxBytes} />;
}

const REQUEST_ID = /^[1-9]\d{0,18}$/;

function RequestNotFound() {
  return (
    <div className="upload-context upload-context--closed" role="alert">
      <p>That request can't be found, or it belongs to another account.</p>
      <Link to="/library/uploads" search={{}} className="button button--subtle">
        Upload a book instead
      </Link>
    </div>
  );
}

function RequestContext({ request }: { request: UploadRequest }) {
  return (
    <div className={`upload-context${request.open ? "" : " upload-context--closed"}`} role={request.open ? undefined : "alert"}>
      {request.open ? (
        <p>
          This file will fulfil <strong>{request.title}</strong>
          {request.author ? ` by ${request.author}` : ""}
          {request.book_type ? ` as the ${BOOK_TYPE_LABELS[request.book_type].toLowerCase()} request` : ""} once processing succeeds.
        </p>
      ) : (
        <p>{request.message}</p>
      )}
      <p className="request-meta">
        <Link to="/requests/$requestId" params={{ requestId: request.id }}>
          Back to the request
        </Link>
        <Link to="/library/uploads" search={{}}>
          Upload a different book instead
        </Link>
      </p>
    </div>
  );
}

function UploadForm({ request, formats, maxBytes }: { request: UploadRequest | null; formats: UploadFormats; maxBytes: number }) {
  const bulk = request === null;
  const send = useSendUpload();
  const [selection, setSelection] = useState<Selection | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [result, setResult] = useState<UploadCreated | null>(null);
  const [skipped, setSkipped] = useState<string | null>(null);
  const [dragging, setDragging] = useState(false);
  const [scanning, setScanning] = useState(false);
  const scan = useRef(0);
  const fileInput = useRef<HTMLInputElement>(null);
  const folderInput = useRef<HTMLInputElement>(null);
  const problemRef = useRef<HTMLParagraphElement>(null);
  const ids = { heading: useId(), hint: useId(), status: useId(), problem: useId() };
  useBlocker({ shouldBlockFn: () => false, enableBeforeUnload: () => send.isPending });
  useEffect(() => {
    if (problem) problemRef.current?.focus();
  }, [problem]);

  if (request && !request.open) {
    return (
      <section className="upload-add" aria-labelledby={ids.heading}>
        <h2 id={ids.heading}>Upload a file for this request</h2>
        <RequestContext request={request} />
      </section>
    );
  }

  const choose = (next: Selection) => {
    scan.current += 1;
    setScanning(false);
    setResult(null);
    setSkipped(null);
    setProblem(null);
    send.reset();
    if (!bulk && (next.folder || next.files.length > 1)) {
      setSelection(null);
      setNote("Choose one file for this request.");
      return;
    }
    const files = next.folder ? supported(next.files, formats) : next.files;
    if (files.length === 0) {
      setSelection(null);
      setNote(next.folder ? "No supported book files were found in that folder." : null);
      return;
    }
    setSelection({ files, folder: next.folder });
    setNote(null);
  };

  const clearInputs = () => {
    if (fileInput.current) fileInput.current.value = "";
    if (folderInput.current) folderInput.current.value = "";
  };

  const drop = async (event: DragEvent<HTMLDivElement>) => {
    event.preventDefault();
    setDragging(false);
    if (send.isPending || scanning) return;
    const incoming = readDrop(event.dataTransfer);
    clearInputs();
    if (!bulk && (incoming.folder || incoming.entries.length > 1 || incoming.files.length > 1)) {
      choose({ files: incoming.files, folder: incoming.folder });
      return;
    }
    setSelection(null);
    setNote(null);
    setScanning(incoming.folder);
    scan.current += 1;
    const current = scan.current;
    const selection = await droppedSelection(incoming);
    if (scan.current === current) choose(selection);
  };

  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (send.isPending || scanning) return;
    if (!selection) {
      setProblem(bulk ? "Choose at least one file or a folder to upload." : "Choose the file to upload.");
      return;
    }
    const { fitting, oversized } = bySize(selection.files, maxBytes);
    if (fitting.length === 0) {
      setProblem(`${oversizedText(oversized, maxBytes)}.`);
      return;
    }
    const submission: UploadSubmission = { files: fitting, folder: selection.folder, requestId: request?.id ?? null };
    setProblem(null);
    setResult(null);
    setSkipped(oversized.length > 0 ? `${oversizedText(oversized, maxBytes)} and ${oversized.length === 1 ? "was" : "were"} not sent.` : null);
    send.mutate(submission, {
      onSuccess: (answer) => {
        setResult(answer);
        setSelection(null);
        clearInputs();
      },
      onError: (error) => setProblem(actionFailure(error, "The upload did not finish. Nothing was added; try again.")),
    });
  };

  const extensions = [`Audiobooks: ${formats.audiobook.join(", ")}`, `Ebooks: ${formats.ebook.join(", ")}`, `Comics: ${formats.comicbook.join(", ")}`];

  return (
    <section className="upload-add" aria-labelledby={ids.heading}>
      <h2 id={ids.heading}>{bulk ? "Add a book" : "Upload a file for this request"}</h2>
      {request ? <RequestContext request={request} /> : null}
      <form className="upload-form" aria-labelledby={ids.heading} onSubmit={submit} noValidate>
        <div
          className={`upload-drop${dragging ? " upload-drop--active" : ""}`}
          onDragOver={(event) => {
            event.preventDefault();
            setDragging(true);
          }}
          onDragLeave={() => setDragging(false)}
          onDrop={(event) => void drop(event)}
        >
          <div className="upload-pickers">
            <label className="button">
              {bulk ? "Choose files" : "Choose a file"}
              <input
                ref={fileInput}
                type="file"
                name={bulk ? "files[]" : "file"}
                className="sr-only"
                multiple={bulk}
                accept={acceptList(formats)}
                aria-describedby={ids.hint}
                disabled={send.isPending || scanning}
                onChange={(event) => {
                  if (folderInput.current) folderInput.current.value = "";
                  choose({ files: Array.from(event.target.files ?? []), folder: false });
                }}
              />
            </label>
            {bulk ? (
              <label className="button button--subtle">
                Choose a folder
                <input
                  ref={folderInput}
                  type="file"
                  name="files[]"
                  className="sr-only"
                  multiple
                  aria-describedby={ids.hint}
                  disabled={send.isPending || scanning}
                  {...({ webkitdirectory: "", directory: "" } as Record<string, string>)}
                  onChange={(event) => {
                    if (fileInput.current) fileInput.current.value = "";
                    choose({ files: Array.from(event.target.files ?? []), folder: true });
                  }}
                />
              </label>
            ) : null}
            <span className="upload-drop-hint">{bulk ? "or drop files or a folder here" : "or drop the file here"}</span>
          </div>
          <div id={ids.hint} className="field-hint">
            <p>{extensions.join(" · ")}</p>
            <p>Up to {formatBytes(maxBytes)} per file.{bulk ? " A folder queues every supported book file inside it." : ""}</p>
          </div>
          <p id={ids.status} className="upload-selection" role="status">
            {selection ? `Selected: ${selectionText(selection)}` : (note ?? "")}
          </p>
        </div>
        {problem ? (
          <p ref={problemRef} id={ids.problem} className="form-error" role="alert" tabIndex={-1}>
            {problem}
          </p>
        ) : null}
        <div className="form-actions">
          <button type="submit" className="button button--primary" disabled={send.isPending || scanning}>
            {send.isPending ? "Uploading…" : scanning ? "Reading the folder…" : "Upload"}
          </button>
        </div>
        {send.isPending ? (
          <div className="upload-progress">
            <progress aria-labelledby={`${ids.status}-sending`} />
            <p id={`${ids.status}-sending`}>Sending {selection ? selectionText(selection) : "the files"}. Keep this page open until it finishes.</p>
          </div>
        ) : null}
        <Outcome result={result} skipped={skipped} />
      </form>
      <details className="settings-note">
        <summary>File name tips</summary>
        <p>Shelfarr matches best when a file is named in one of these ways:</p>
        <ul className="settings-note-list">
          <li>Author Name - Book Title.m4b</li>
          <li>Book Title (Author Name).epub</li>
          <li>Book Title [Author Name].pdf</li>
        </ul>
      </details>
    </section>
  );
}

function Outcome({ result, skipped }: { result: UploadCreated | null; skipped: string | null }) {
  return (
    <div className="form-outcome" role="status">
      {result?.notice ? (
        <p className="form-success">
          {result.notice}
          {result.request_id ? (
            <>
              {" "}
              <Link to="/requests/$requestId" params={{ requestId: result.request_id }}>
                Back to the request
              </Link>
            </>
          ) : null}
        </p>
      ) : null}
      {result?.alert ? <p className="form-error">{result.alert}</p> : null}
      {skipped ? <p className="form-error">{skipped}</p> : null}
    </div>
  );
}
