# Third-party notices

The source code in this repository is © 2026 BLHN under the [MIT License](LICENSE).

The app bundles built by `build.sh` also contain third-party software, listed below. The same text
ships inside every bundle as `Contents/Resources/THIRD_PARTY_NOTICES.txt` (from
`Packaging/THIRD_PARTY_NOTICES.txt`) and `Contents/Resources/Licenses/rclone-COPYING.txt`.

## rclone

- Version: v1.75.2, the official macOS builds for arm64 and amd64 from
  <https://downloads.rclone.org/v1.75.2/>, checked against the release's `SHA256SUMS`, combined into
  one universal binary with `lipo` and signed together with the app. The code is not modified.
- Location in the bundle: `Contents/Helpers/rclone`
- Website: <https://rclone.org>
- Source: <https://github.com/rclone/rclone/tree/v1.75.2>
- Licence: MIT

```
Copyright (C) 2019 by Nick Craig-Wood https://www.craig-wood.com/nick/

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

rclone is written in Go and is built from many open source Go modules, each under its own licence
(mostly MIT, BSD and Apache 2.0). The modules of this version are listed in
[go.mod of the v1.75.2 tag](https://github.com/rclone/rclone/blob/v1.75.2/go.mod).
