# Third-party notices

## Shelfarr companion bridge

The Shelfarr control bridge is part of the Shelfarr project and is distributed
under GNU GPL-3.0. Its preferred source is the
[`services/libation_companion`](https://github.com/Pedro-Revez-Silva/shelfarr/tree/main/services/libation_companion)
directory. Release images carry OCI source and revision labels for the exact
Shelfarr commit used to build them, and the companion version matches the
numeric Shelfarr release tag (for example, companion `X.Y.Z` corresponds to
Shelfarr source tag `vX.Y.Z`). A copy of its license is installed at
`/companion/LICENSES/Shelfarr-GPL-3.0.txt`.

## Libation

The Shelfarr Libation Companion is built on the unmodified Libation container
and invokes Libation through its command-line interface. Shelfarr and its
companion are independent projects and are not affiliated with Audible or
Amazon.

- Project: [rmcrackan/Libation](https://github.com/rmcrackan/Libation)
- Version: `14.2.0`
- Image: `rmcrackan/libation:14.2.0`
- Manifest digest: `sha256:c0ab061d317621057e914c51506d57238d5b6afb158c4aa5801b2fa29b15d8db`
- Source commit: `087c1076850d63f2ad172417535f3f0b025e722a`
- License: [GNU General Public License v3.0](https://github.com/rmcrackan/Libation/blob/v14.2.0/LICENSE)
- Source for the distributed version: [Libation v14.2.0](https://github.com/rmcrackan/Libation/tree/v14.2.0)
- Source snapshot in this image: `/companion/SOURCES/Libation-14.2.0-source.tar.gz`
- Source snapshot SHA-256: `662f065621f042c8cacd7c86a3f487f42cc490ed2ae96ce1f7566e7a491678b6`
- Documentation: [getlibation.com/docs](https://getlibation.com/docs)

Libation is Copyright (C) its authors and contributors. The Shelfarr project
does not claim authorship of Libation. The companion adds an authenticated,
local-network control API around an unmodified, pinned Libation CLI. Issues
specific to this bridge should be reported to Shelfarr rather than to Libation's
maintainers.

Shelfarr includes the verbatim GPL-3.0 text at
`/companion/LICENSES/Libation-GPL-3.0.txt`, publishes this notice alongside the
companion, provides the exact upstream source link, and conveys a
machine-readable snapshot of that source inside every companion image.
