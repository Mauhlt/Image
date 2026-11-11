# BMP test files

The `.bmp` files are from BMP Suite 2.8 by Jason Summers
(https://entropymine.com/jason/bmpsuite/). The suite's generator is GPL-3, but
the images it generates are in the public domain (see its readme.txt).

Each `<name>.bmp.wic.png` is Windows' own decode of `<name>.bmp`: WIC
(`System.Windows.Media.Imaging.BitmapDecoder`, PreservePixelFormat), converted to
Bgra32 with `FormatConvertedBitmap` and saved with `PngBitmapEncoder`.

| File | Covers |
| --- | --- |
| pal4rle, pal8rle | RLE4 / RLE8 |
| pal8rletrns, pal4rlecut | RLE delta and early end-of-line / end-of-bitmap |
| rletopdown | RLE8 stored top-down (invalid, but Windows reads it) |
| pal8os2 | OS/2 BITMAPCOREHEADER, 3-byte palette entries |
| pal8topdown | uncompressed top-down |
| rgb16, rgb16-565 | 16-bit default X1R5G5B5 and BI_BITFIELDS 565 |
| rgb32bf, rgb32-7187 | 32-bit BI_BITFIELDS: shuffled channels, 7/18/7-bit channels |
| rgba32-1 | V5 header with an alpha mask |
| rgba32abf | BI_ALPHABITFIELDS (same picture as rgba32-1; WIC can't read it) |
| rgba16-4444 | 16-bit with a 4-bit alpha mask (WIC ignores the alpha) |
| badrle, badrle4, badrle4bis | invalid RLE that writes outside the image (must not crash) |

Where WIC differs from us, by design:
- RLE pixels skipped by delta / early end-of-line: WIC makes them black, we use
  palette index 0 (bmpsuite lists both as acceptable).
- 5/6-bit channels: WIC widens by bit replication, we round `v * 255 / max`;
  off by at most 1.
