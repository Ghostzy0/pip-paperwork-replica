# Pinned helper dependency notices

All files here must accompany distributed helper binaries and source exports.

| Component | Exact version / provenance | Licence / included notice |
| --- | --- | --- |
| pdfcpu | github.com/pdfcpu/pdfcpu v0.16.1 | Apache-2.0 (`pdfcpu-LICENSE.txt`); Copyright 2018–2026 The pdfcpu Authors, individual source headers retained in dependency module |
| pdfcpu LZW implementation | internal/filter/lzw at pdfcpu v0.16.1 | Go BSD-3-Clause (`pdfcpu-lzw-LICENSE.txt`) |
| pdfcpu PKCS7 | pkg/pdfcpu/pkcs7 at pdfcpu v0.16.1 | MIT, Andrew Smith (`pdfcpu-pkcs7-LICENSE.txt`) |
| Roboto Regular embedded by pdfcpu configuration package | pkg/pdfcpu/model/resources/Roboto-Regular.ttf at v0.16.1 | Copyright 2011 Google Inc.; Apache-2.0 (`Roboto-NAME-NOTICES.txt`, `pdfcpu-LICENSE.txt`); runtime config is disabled, so this helper never installs it |
| Adobe core 14 font metrics | internal/corefont/Core14_AFMs → generated metrics at v0.16.1 | Adobe permission paragraph retained unmodified in `Adobe-Core14-MustRead.html`; original copyright/trademark notices in `Adobe-Core14-Copyrights.txt`; no AFM modifications by this project |
| clipperhouse/uax29/v2 | v2.7.0 | MIT (`uax29-LICENSE.txt`) |
| hhrutter/tiff | v1.0.7 | BSD-3-Clause (`tiff-LICENSE.txt`) |
| mattn/go-runewidth | v0.0.30 | MIT (`runewidth-LICENSE.txt`) |
| go.yaml.in/yaml/v3 | v3.0.5 | MIT + Apache-2.0 upstream notice (`yaml-LICENSE.txt`) |
| golang.org/x/crypto | v0.57.0 | BSD-3-Clause (`x-crypto-LICENSE.txt`) |
| golang.org/x/image | v0.46.0 | BSD-3-Clause (`x-image-LICENSE.txt`) |
| golang.org/x/text | v0.42.0 | BSD-3-Clause (`x-text-LICENSE.txt`) |
| Go compiler and linked standard library | go1.26.0 darwin/arm64 | BSD-3-Clause (`go-LICENSE.txt`); toolchain archive SHA256 b1640525dfe68f066d56f200bef7bf4dce955a1a893bd061de6754c211431023 |

`go.mod` and `go.sum` are the dependency resolution/integrity authority. google/jsonschema-go is in upstream's module graph and sum file but is not imported/linked by this helper. Cobra, pflag and mousetrap belong to upstream's CLI and are not imported by this helper. No upstream sample/media/AFM files are distributed as application assets; only applicable permission/copyright text is retained here.
