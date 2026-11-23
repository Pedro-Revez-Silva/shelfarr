import { Link } from "@tanstack/react-router";
import { ErrorPanel } from "../../components/States";
import { SettingsCard } from "../primitives";
import type { PersonRole, PersonRow } from "./contract";
import { useArrival, usePeople } from "./queries";
import "./people.css";

export const ROLE_LABELS: Record<PersonRole, string> = { member: "Member", administrator: "Administrator" };
export const PEOPLE_ARRIVAL = "people";

const day = new Intl.DateTimeFormat("en", { dateStyle: "medium" });

export function AddedOn({ iso }: { iso: string }) {
  return <time dateTime={iso}>{day.format(new Date(iso))}</time>;
}

export function PeopleCard() {
  const people = usePeople();
  const arrival = useArrival(PEOPLE_ARRIVAL);
  return (
    <SettingsCard id="users" headingId="users-heading" title="People" summary="Everyone who can sign in to this server. Removed accounts are not listed.">
      <p className="people-actions">
        <Link to="/server/people/users/new" className="button button--primary">
          Add a person
        </Link>
      </p>
      <div className="settings-card-status" role="status">
        {arrival ? <p className="form-success">{arrival}</p> : null}
      </div>
      {people.data ? (
        <ul className="people-list" aria-labelledby="users-heading">
          {people.data.users.map((entry) => (
            <PersonListRow key={entry.id} person={entry} />
          ))}
        </ul>
      ) : people.isError ? (
        <ErrorPanel error={people.error} onRetry={() => void people.refetch()} />
      ) : (
        <p className="field-hint">Loading people…</p>
      )}
    </SettingsCard>
  );
}

function PersonListRow({ person }: { person: PersonRow }) {
  return (
    <li className="people-row">
      <Link to="/server/people/users/$userId" params={{ userId: person.id }} className="people-name">
        {person.name}
      </Link>
      {person.self ? <span className="badge">You</span> : null}
      <span className={`badge${person.role === "administrator" ? " badge--completed" : ""}`}>{ROLE_LABELS[person.role]}</span>
      <span className="people-facts">
        <span className="people-username">{person.username}</span>
        <span>
          Added <AddedOn iso={person.created_at} />
        </span>
      </span>
    </li>
  );
}
