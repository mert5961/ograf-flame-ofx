# Third-party components

These are downloaded by `scripts/fetch-deps.sh` at build time and are not part of this
repository. The built plugin bundle contains the CEF framework and binaries linked from it.

| Component | Version | Licence |
|---|---|---|
| [Chromium Embedded Framework](https://bitbucket.org/chromiumembedded/cef) | 156.0.30 (Chromium 156.0.8078.96), macOS arm64 minimal distribution | BSD-3-Clause. Chromium and its dependencies are listed in the distribution's `CREDITS.html`, shipped in the bundle as `Contents/Resources/CHROMIUM-CREDITS.html`. |
| [OpenFX](https://github.com/AcademySoftwareFoundation/openfx) | OFX_Release_1.5 (headers only) | BSD-3-Clause |
| [nlohmann/json](https://github.com/nlohmann/json) | 3.11.3 | MIT |

OGraf templates rendered by the plugin carry their own licences (for example, fonts packaged by
OGraf Studio include their licence files inside the `.ograf.zip`).
