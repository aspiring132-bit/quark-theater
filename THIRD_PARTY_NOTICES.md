# Third-party notices

Quark Theater's native Swift adapter was independently written against observable protocol behavior in two public reference repositories. It does not link or bundle either project.

- **QuarkPan** by lich0821: [MIT license](https://github.com/lich0821/QuarkPan/blob/ca311f6eaf3a50374371ad0e6900d85c992c7788/LICENSE), inspected commit `ca311f6eaf3a50374371ad0e6900d85c992c7788` on `master`. Protocol behavior was independently implemented in Swift; no Python implementation was copied.
- **quarkpan-rs** by niuhuan: [GPL-3.0-only license](https://github.com/niuhuan/quarkpan-rs/blob/41b26b0cd8a03696c4c22bf2c006ad981b6f5d44/LICENSE), inspected commit `41b26b0cd8a03696c4c22bf2c006ad981b6f5d44` on `main`. This project was consulted for independent field and Range behavior checks only. No Rust code or dependency was copied or linked.

This project is an unofficial client. Quark's endpoints and login behavior can change without notice.

## MIT License

Copyright (c) 2025 QuarkPan

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

## TVVLCKit (VideoLAN)

- **Component:** TVVLCKit for tvOS
- **Version:** 3.7.2 (LibVLC 3.0.x core, commit `3e42ae47`)
- **Archive URL:** `https://download.videolan.org/cocoapods/prod/TVVLCKit-3.7.2-3e42ae47-79128878.tar.xz`
- **Archive SHA-256:** `fa264c2eb17d648669d9d12b51e76e5b6769828354517d09b340387b30825f58`
- **Included License File:** `TVVLCKit-binary/COPYING.txt` identifying GNU Lesser General Public License Version 2.1, February 1999 (full text available in `LICENSES/LGPL-2.1.txt`).

### Notice and Licensing Scope

The pinned upstream archive includes `TVVLCKit-binary/COPYING.txt` identifying the GNU Lesser General Public License Version 2.1 (LGPL-2.1); this notice does not independently establish the license of every bundled component. This notice does not claim or imply that every bundled, linked, or transitive third-party component within LibVLC/TVVLCKit shares this exact license, nor does this notice alone establish legal compliance. Distribution review may still need corresponding source, relinking mechanisms, and accompanying materials per applicable license terms for all included modules. This documentation is provided for informational purposes and does not constitute legal advice.
