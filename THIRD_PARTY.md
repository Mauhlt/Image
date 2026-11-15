# Third-party material

Image's own code is MIT licensed (see `LICENSE`). The material below comes
from other projects and keeps its own terms; it is not relicensed.

## Code

### VP8 (lossy WebP) decoder: golang.org/x/image/vp8

`src/Formats/webp/vp8.zig` is ported from, and `src/Formats/webp/vp8_tables.zig`
transcribes tables from, the Go package `golang.org/x/image/vp8`
(https://cs.opensource.google/go/x/image), Copyright 2011 The Go Authors,
under the BSD-style licence of the Go project:

```
Copyright 2009 The Go Authors.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

   * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
   * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.
   * Neither the name of Google LLC nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

Other decoders follow their specifications (ITU T.81 / T.87, H.265, RFC 1951
and 6386, the PNG, QOI, WebP lossless, BMP, TGA, netpbm, DDS and KTX2 formats).
libdeflate, libjpeg and libwebp are named in comments as design or
bit-exactness references; no code is copied from them.

## Test data (`src/Data/Read`, `src/inflate/testdata`)

| Files | Source | Terms |
| --- | --- | --- |
| `bmp/*.bmp` | BMP Suite 2.8, Jason Summers (https://entropymine.com/jason/bmpsuite/) | Public domain (the generator is GPL-3; the images it makes are not). See `bmp/README.md`. |
| `png/*.png` except `*.wic.png` and `BasicArt16i.png` | PngSuite 2017-07-19, Willem van Schaik (http://www.schaik.com/pngsuite/) | "Permission to use, copy, modify and distribute these images for any purpose and without fee is hereby granted. (c) Willem van Schaik, 1996, 2011". See `png/README.md`. |
| `tga/cbw8.tga`, `ccm8.tga`, `ctc24.tga`, `utc16.tga` | Truevision TGA 2.0 conformance samples, via image-rs | Copyright Truevision, Inc.; published free of charge with no specific licence. See `tga/README.md`. |
| other `tga/*` (`b5-*`, `cmap_offset`, the four origins, `*.tga.png`) | image-rs test suite (https://github.com/image-rs/image) | MIT OR Apache-2.0. |
| `vp8/*` | golang.org/x/image testdata; the golden planes are libwebp's decodes | Go BSD-style licence (text above). See `vp8/README.md`. |
| `IjgBaseline.jpg`, `IjgProgressive.jpg`, `IjgBaselineJpg.ref.ppm` | `testorig.jpg`, `testprog.jpg` and `testimg.ppm` from the Independent JPEG Group's libjpeg | IJG licence (libjpeg README, "LEGAL ISSUES"), copyright Thomas G. Lane and Guido Vollbeding. |
| `heic/C002.heic`, `C014.heic`, `C021.heic` | HEIF conformance samples; the origin is not recorded in this repository, but the names match Nokia's HEIF conformance files (https://github.com/nokiatech/heif_conformance) | **To confirm.** If they are Nokia's, they are under Nokia's HEIF licence, which is not an open-source licence. |
| `inflate/testdata/text1.gz`, `text9.gz` | gzip of `std/compress/flate/Decompress.zig` from the Zig standard library | MIT, Copyright (c) Zig contributors. |

Everything else in `src/Data` (BasicArt, Gradient and their encodings,
`*.wic.png` / `*.ref.*` decodes of the files above made with Windows' WIC or
Pillow, the other `inflate/testdata` streams, which compress `BasicArt.jpg`,
`Gradient.pgm` and generated pixels) is this project's own.
