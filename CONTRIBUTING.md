# Contributing to Shelfarr

Shelfarr is a maintainer-directed hobby project. Bug reports, feature ideas,
and focused technical proposals are welcome through GitHub Issues. Opening an
issue does not commit the project to an implementation or timeline.

## Implementation requires assignment

Do not open an implementation pull request unless the maintainer has assigned
you an open Shelfarr issue for that work. Assignment is the explicit approval
to implement that issue's agreed scope; it is not a general invitation to add
other changes and does not guarantee that a pull request will be merged.

Every external pull request must:

1. Link at least one open Shelfarr issue using `Closes #123`, `Fixes #123`, or
   `Resolves #123` in the pull request description.
2. Be authored by a person assigned to every Shelfarr issue it claims to close.
3. Stay focused on the assigned scope.
4. Include appropriate tests, documentation, and verification evidence.

Pull requests that do not meet the assignment requirements are closed
automatically. After the maintainer assigns the issue and the pull request
description links it correctly, the author may reopen the pull request.

## Maintainer adoption

Occasionally, a maintainer may choose to finish an existing external pull
request rather than ask its author to repeat integration work. The maintainer
will apply the `maintainer-adopted` label and explain the handoff in the pull
request. That label is explicit approval for the pull request to remain open
without an assigned issue while the maintainer rebases, adjusts, tests, or
finishes it.

Adoption does not transfer ownership of the contributor's work. Original
commits retain their authorship, and substantial rewrites or squashed commits
must preserve credit with a `Co-authored-by` trailer. Once a pull request is
adopted, its author does not need to take further action unless the maintainer
asks for input.

## Before requesting review

- Rebase once onto the current `main` branch when the implementation is ready.
- Run `bin/quality push` and resolve its failures.
- Explain what changed, why it belongs in Shelfarr, and how it was verified.
- Include screenshots or recordings for visible or interactive changes.
- Avoid unrelated cleanup, broad rewrites, and speculative feature expansion.

The maintainer may close an implementation that is too costly to review or
maintain, even when its underlying idea is useful. In that case, the issue can
remain as the durable record of the problem or proposal.

## Security reports

Do not report vulnerabilities in a public issue. Follow [SECURITY.md](SECURITY.md)
instead.
