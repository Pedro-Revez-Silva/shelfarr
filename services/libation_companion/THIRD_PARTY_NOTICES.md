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
- Version: `13.5.1`
- Image: `rmcrackan/libation:13.5.1`
- Manifest digest: `sha256:71b9db4bbda7d7e14bb9f5efcdcfe980915c90867599bc0d512d958069fb3da0`
- Source commit: `07c2f2b2a1deb8c57601c2b131aba30c95be3097`
- License: [GNU General Public License v3.0](https://github.com/rmcrackan/Libation/blob/v13.5.1/LICENSE)
- Source for the distributed version: [Libation v13.5.1](https://github.com/rmcrackan/Libation/tree/v13.5.1)
- Source snapshot in this image: `/companion/SOURCES/Libation-13.5.1-source.tar.gz`
- Source snapshot SHA-256: `7391b9e4e34375e5d134932246ce0a50e0561efe1a24c2a3aa8f32a1217fac9f`
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
