# VP8 (lossy WebP) golden files

From golang.org/x/image/testdata (Copyright The Go Authors, BSD-style license).

Each `*.ycbcr.png` / `*.nycbcra.png` is a grayscale image holding the planes
libwebp decodes from the matching `.webp`: Y on top, then U | V side by side,
then alpha (for `-with-alpha`). The Image tests require an exact match.
