# Third-party software

MacViewer statically includes compression and decompression portions of
[Zstandard 1.5.7](https://github.com/facebook/zstd/tree/v1.5.7), copyright Meta
Platforms, Inc. and affiliates, under its BSD license. The source's alternative
GPLv2 license is also preserved. Original notices are in
`ThirdParty/zstd/LICENSE` and `ThirdParty/zstd/COPYING`, and the packaging script
copies both into `MacViewer.app/Contents/Resources/Licenses/Zstandard/`.

Upstream source files are unmodified. `ThirdParty/zstd/provenance.json` records
the exact release, acquisition URL, archive digest and selected files. The local
module entry point is `ThirdParty/zstd/include/CZstd.h`. The build includes
compression, decompression and legacy formats 4–7 and disables architecture-specific assembly.

REA and Ghidra are analysis tools and are not distributed inside the Mac app.

Computer audio decoding includes the WebRTC G.722 decoder from revision
`4fdd50a57b79826ea87cc5170be78b6444d9cdf9`. Its original public-domain notice
and WebRTC BSD license are preserved in `ThirdParty/g722/LICENSE` and
`ThirdParty/g722/WEBRTC_LICENSE`, and copied into the app’s `Licenses/G722/`
folder. `ThirdParty/g722/provenance.json` records the upstream source URLs and
digests. `MacViewerG722.c` is the local allocation-checked wrapper.

The supplied Windows UltraViewer executable and library files remain separate
analysis inputs and are not bundled into the native application.

The application includes the supplied `UltraViewer/8bit.dat` Zstandard decoding
dictionary as data at `Contents/Resources/8bit.dat`. It is 112,640 bytes with
SHA-256 `9aa45789d9ff9d329a623a685d57b67e33c777019de9ce1f273f21860e4bfe6b`
and dictionary ID `0x3da0bd10`. This is an UltraViewer-supplied asset, not an
independently authored or open-source dictionary. No redistribution license for
that asset was established; the supplied asset is retained for this local
interoperability build. No Windows executable code is embedded.
