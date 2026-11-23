import { Link } from "@tanstack/react-router";
import { useState } from "react";
import { SettingsCard } from "../server/primitives";
import { UploadList } from "./UploadList";
import "./uploads.css";

export const UPLOAD_CARDS = [{ id: "uploads", title: "Uploads" }];

export function ServerUploads() {
  const [page, setPage] = useState(1);
  return (
    <SettingsCard id="uploads" headingId="uploads-card-heading" title="Uploads" summary="Every file added to this server. Retry one that failed, correct its match, or delete it.">
      <p>
        <Link to="/library/uploads" className="button button--subtle">
          Add a book
        </Link>
      </p>
      <UploadList admin page={page} onPage={setPage} level={4} title="All uploads" />
    </SettingsCard>
  );
}
