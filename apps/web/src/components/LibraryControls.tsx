import { useId, useState, type FormEvent } from "react";
import type { LibraryFilters } from "../contract";

type Props = { filters: LibraryFilters; onChange: (next: LibraryFilters) => void };

const TYPES = [
  { value: undefined, label: "Everything" },
  { value: "ebook", label: "Ebooks & comics" },
  { value: "audiobook", label: "Audiobooks" },
] as const;

const STATUSES = [
  { value: "", label: "All statuses" },
  { value: "unread", label: "Unread" },
  { value: "in_progress", label: "Reading" },
  { value: "finished", label: "Finished" },
] as const;

const SORTS = [
  { value: "recent", label: "Recently added" },
  { value: "title", label: "Title A–Z" },
] as const;

export function LibraryControls({ filters, onChange }: Props) {
  const typeName = useId();
  return (
    <div className="controls">
      <SearchForm key={filters.q ?? ""} filters={filters} onChange={onChange} />
      <fieldset className="type-filter">
        <legend>Show</legend>
        {TYPES.map((option) => (
          <label key={option.label} className="pill">
            <input
              type="radio"
              name={typeName}
              checked={filters.type === option.value}
              onChange={() => onChange({ ...filters, type: option.value })}
            />
            <span>{option.label}</span>
          </label>
        ))}
      </fieldset>
      <div className="selects">
        <label>
          Reading status
          <select
            value={filters.status ?? ""}
            onChange={(event) => {
              const value = event.target.value;
              const next: LibraryFilters = { ...filters };
              if (value === "unread" || value === "in_progress" || value === "finished") next.status = value;
              else delete next.status;
              onChange(next);
            }}
          >
            {STATUSES.map((option) => (
              <option key={option.value} value={option.value}>
                {option.label}
              </option>
            ))}
          </select>
        </label>
        <label>
          Sort by
          <select
            value={filters.sort ?? "recent"}
            onChange={(event) => onChange({ ...filters, sort: event.target.value === "title" ? "title" : "recent" })}
          >
            {SORTS.map((option) => (
              <option key={option.value} value={option.value}>
                {option.label}
              </option>
            ))}
          </select>
        </label>
      </div>
    </div>
  );
}

function SearchForm({ filters, onChange }: Props) {
  const [text, setText] = useState(filters.q ?? "");
  const inputId = useId();

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const next: LibraryFilters = { ...filters };
    const trimmed = text.trim();
    if (trimmed) next.q = trimmed;
    else delete next.q;
    onChange(next);
  }

  return (
    <form className="search" role="search" onSubmit={submit}>
      <label htmlFor={inputId}>Search your library</label>
      <div className="search-row">
        <input
          id={inputId}
          type="search"
          name="q"
          value={text}
          maxLength={200}
          enterKeyHint="search"
          autoComplete="off"
          autoCorrect="off"
          autoCapitalize="none"
          spellCheck={false}
          placeholder="Title or author"
          onChange={(event) => setText(event.target.value)}
        />
        <button type="submit" className="button">
          Search
        </button>
        {filters.q ? (
          <button
            type="button"
            className="button button--subtle"
            onClick={() => {
              const next: LibraryFilters = { ...filters };
              delete next.q;
              onChange(next);
            }}
          >
            Clear search
          </button>
        ) : null}
      </div>
    </form>
  );
}
