# Web reader dependencies

The checked-in browser engine is built from pinned packages with Bun 1.4.4. It contains EPUB.js (BSD-2-Clause), DOMPurify (Apache-2.0 or MPL-2.0), and their dependencies. Source and exact resolved versions are recorded in package.json and bun.lock. The XML parser is pinned to a patched release through an override; the actual EPUB browser path uses the browser DOM parser. No package install or CDN request runs in production.

Rebuild with `bun install --frozen-lockfile && bun run build` from this directory. Run `bun test` and `bun audit` before committing a rebuilt bundle. The output is vendor/javascript/consumer_reader_engine.js.

## License texts

- @types/trusted-types@2.0.7 — MIT ([license](licenses/types__trusted-types2.0.7.txt))
- @xmldom/xmldom@0.9.12 — MIT ([license](licenses/xmldom__xmldom0.9.12.txt))
- core-js@3.51.0 — MIT ([license](licenses/core-js3.51.0.txt))
- core-util-is@1.0.3 — MIT ([license](licenses/core-util-is1.0.3.txt))
- d@1.0.2 — ISC ([license](licenses/d1.0.2.txt))
- dompurify@3.4.17 — (MPL-2.0 OR Apache-2.0) ([license](licenses/dompurify3.4.17.txt))
- epubjs@0.3.93 — BSD-2-Clause ([license](licenses/epubjs0.3.93.txt))
- es5-ext@0.10.64 — ISC ([license](licenses/es5-ext0.10.64.txt))
- es6-iterator@2.0.3 — MIT ([license](licenses/es6-iterator2.0.3.txt))
- es6-symbol@3.1.4 — ISC ([license](licenses/es6-symbol3.1.4.txt))
- esniff@2.0.1 — ISC ([license](licenses/esniff2.0.1.txt))
- event-emitter@0.3.7 — ISC ([license](licenses/event-emitter0.3.7.txt))
- ext@1.7.0 — ISC ([license](licenses/ext1.7.0.txt))
- immediate@3.0.6 — MIT ([license](licenses/immediate3.0.6.txt))
- inherits@2.0.4 — ISC ([license](licenses/inherits2.0.4.txt))
- jszip@3.10.2 — (MIT OR GPL-3.0-or-later) ([license](licenses/jszip3.10.2.txt))
- lie@3.3.0 — MIT ([license](licenses/lie3.3.0.txt))
- lie@3.1.1 — MIT ([license](licenses/lie3.1.1.txt))
- localforage@1.10.0 — Apache-2.0 ([license](licenses/localforage1.10.0.txt))
- lodash@4.18.1 — MIT ([license](licenses/lodash4.18.1.txt))
- next-tick@1.1.0 — ISC ([license](licenses/next-tick1.1.0.txt))
- pako@1.0.11 — (MIT AND Zlib) ([license](licenses/pako1.0.11.txt))
- process-nextick-args@2.0.1 — MIT ([license](licenses/process-nextick-args2.0.1.txt))
- readable-stream@2.3.8 — MIT ([license](licenses/readable-stream2.3.8.txt))
- safe-buffer@5.1.2 — MIT ([license](licenses/safe-buffer5.1.2.txt))
- setimmediate@1.0.5 — MIT ([license](licenses/setimmediate1.0.5.txt))
- string_decoder@1.1.1 — MIT ([license](licenses/string_decoder1.1.1.txt))
- type@2.7.3 — ISC ([license](licenses/type2.7.3.txt))
- util-deprecate@1.0.2 — MIT ([license](licenses/util-deprecate1.0.2.txt))

Additional package license declarations and retained attribution:

- path-webpack 0.0.3 — MIT ([terms and attribution](licenses/path-webpack0.0.3.txt))
- marks-pane 1.0.9 — MIT ([terms and attribution](licenses/marks-pane1.0.9.txt))
- isarray 1.0.0 — MIT ([upstream README license](licenses/isarray1.0.0.txt))
- @types/localforage 0.0.34 — localForage MIT declaration ([upstream license](licenses/types__localforage0.0.34.txt)); type declarations are not part of the browser bundle.
