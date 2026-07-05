# Third-Party Notices

Momenterm is distributed under the MIT License (see [LICENSE](LICENSE)). It
also bundles or links the following third-party components, each retaining its
own copyright and license. This file is provided to satisfy the attribution
requirements of those licenses.

---

## Monaco Editor (v0.45.0)

The diff, file, and Git-graph panels render inside an embedded Monaco editor.
The `resources/webviews/vs/` directory contains the Monaco distribution.

- Source: https://github.com/microsoft/vscode
- Copyright (c) Microsoft Corporation
- License: MIT

## Codicons (`resources/webviews/vs/base/browser/ui/codicons/codicon/codicon.ttf`)

The icon font shipped with Monaco.

- Source: https://github.com/microsoft/vscode-codicons
- Copyright (c) Microsoft Corporation
- License: the code is MIT; the icon glyphs are licensed under
  Creative Commons Attribution 4.0 International (CC-BY-4.0),
  https://creativecommons.org/licenses/by/4.0/

## marked (v11.2.0)

Markdown parser used by the memo/markdown rendering path
(`resources/webviews/marked.min.js`).

- Source: https://github.com/markedjs/marked
- Copyright (c) 2011-2024, Christopher Jeffrey
- License: MIT

## libghostty / Ghostty

The native terminal is backed by libghostty. `scripts/build.sh` downloads a
prebuilt, checksum-verified `GhosttyKit.xcframework` at build time; it is not
committed to this repository.

- Ghostty: https://github.com/ghostty-org/ghostty — Copyright (c) Mitchell
  Hashimoto and the Ghostty contributors — License: MIT
- SwiftPM packaging: https://github.com/Lakr233/libghostty-spm
  (release `storage.1.2.8`)

---

## MIT License (full text)

The MIT-licensed components above are governed by the following terms, with
copyright held by their respective owners as listed above:

```
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
