# SIMD decode speedups

`zig build bench`, ReleaseFast, median time per decode, i5-14400F (AVX2).
"Before" is the branch point 2ce8527. Every change is bit-identical to the
code it replaced (the old paths are kept as test oracles).
The agents ran in parallel on one machine, so single numbers carry some noise.

## JPEG (merged from `simd/jpeg`, f22d71f)

| File | Before (ms) | After (ms) | Speedup |
|---|---:|---:|---:|
| BasicArt.jpg (1536x864, 4:2:0, baseline) | 9.89 | 1.37 | 7.2x |
| IjgProgressive.jpg (227x149) | 0.49 | 0.26 | 1.9x |

Main wins: integer chroma upsampling in u16 vectors (8.9 -> 2.4 ms), DC-only
and zero-row IDCT shortcuts, 16-bit YCbCr->RGB, faster Huffman lookups.

## BMP, TGA, netpbm, pixel conversions (merged from `simd/raster`, 5dd1766)

| Case | Before (ms) | After (ms) | Speedup |
|---|---:|---:|---:|
| BasicArt.tga (RLE 24-bit) | 3.23 | 0.37 | 8.7x |
| tga raw 24-bit | 4.27 | 0.19 | 22x |
| tga raw 32-bit bottom-up | 4.83 | 0.26 | 19x |
| tga raw 16-bit | 5.91 | 0.31 | 19x |
| tga 8-bit color-mapped | 3.89 | 0.28 | 14x |
| bmp 16-bit 565 | 1.66 | 0.54 | 3.1x |
| bmp 32-bit bitfields (BGRA) | 2.06 | 0.25 | 8.2x |
| bmp 8-bit palette | 0.72 | 0.28 | 2.6x |
| bmp RLE8 | 0.79 | 0.34 | 2.3x |
| bmp 4-bit palette | 2.69 | 0.39 | 6.9x |
| bmp 1-bit palette | 2.67 | 0.30 | 8.9x |
| BasicArt.bmp / .ppm (already memcpy) | 0.21 / 0.20 | 0.21 / 0.21 | 1x |
| ppm ASCII (P3) | 17.28 | 8.67 | 2.0x |
| pgm 16-bit (P5) | 5.32 | 0.52 | 10x |
| ppm P6, maxval 100 | 6.54 | 0.45 | 15x |
| pbm P4 | 0.53 | 0.04 | 13x |
| convertV rgb -> rgba | 0.81 | 0.23 | 3.5x |
| convertV bgr -> rgba | 0.81 | 0.22 | 3.7x |
| convertV g -> rgba | 0.79 | 0.16 | 4.9x |

Other conversions (rgba->rgb, rgb->bgr, rgb->g, ycbcr) were unchanged within noise.

## PNG / QOI (merged from `simd/png-qoi`, d6b1944)

| File | Before (ms) | After (ms) | Speedup |
|---|---:|---:|---:|
| BasicArt.png (rgba8) | 2.59 | 0.77 | 3.4x |
| png/BasicArt16i.png (16-bit rgba, Adam7) | 13.0 | 2.94 | 4.4x |
| BasicArt.qoi | 0.90 | 0.53 | 1.7x |

Main wins: inflate straight into the row buffer (no 64 KiB window copy),
slicing-by-16 CRC-32 (~4.5x std), vector defilters (Paeth rgba 17.1 -> 3.2 ms
per-row cost; two Avg/Paeth rows interleaved), per-image row-expansion kernels;
QOI: unchecked fast loop with a fully checked tail, 4-byte pixel stores.
On a large photo-like PNG our share fell from 31.8 to 5.0 ms; std's inflate
(~35 ms) now dominates. QOI on pure noise (diff/luma ops only) is not faster.

## All files on the merged branch (`zig build bench`, 3171b33 + png-qoi)

| File | Before (ms) | After (ms) | Speedup |
|---|---:|---:|---:|
| BasicArt.tga | 3.23 | 0.36 | 9.0x |
| BasicArt.jpg | 9.89 | 1.33 | 7.4x |
| png/BasicArt16i.png | 13.0 | 2.93 | 4.4x |
| BasicArt.png | 2.59 | 0.76 | 3.4x |
| BasicArt.webp | 1.74 | 0.57 | 3.1x |
| blue-purple-pink normal-filter lossy webp | 4.65 | 1.74 | 2.7x |
| yellow_rose lossy-with-alpha webp | 2.31 | 0.97 | 2.4x |
| blue-purple-pink simple-filter lossy webp | 3.62 | 1.66 | 2.2x |
| IjgProgressive.jpg | 0.49 | 0.26 | 1.9x |
| BasicArt.qoi | 0.90 | 0.54 | 1.7x |
| BasicArt.bmp / .ppm | 0.21 | 0.21 | 1x (already memcpy) |

## WebP (merged from `simd/webp`, bfe7767)

| File | Before (ms) | After (ms) | Speedup |
|---|---:|---:|---:|
| BasicArt.webp (lossless, 1536x864, 2-colour palette) | 1.74 | 0.58 | 3.0x |
| blue-purple-pink-large.normal-filter.lossy.webp (600x400) | 4.65 | 1.87 | 2.5x |
| blue-purple-pink-large.simple-filter.lossy.webp (600x400) | 3.62 | 1.69 | 2.1x |
| yellow_rose.lossy-with-alpha.webp (400x301, RGBA) | 2.31 | 1.02 | 2.3x |
| yellow_rose re-encoded lossless (scratch only, not in bench) | 1.51 | 0.94 | 1.6x |

Main wins: loop filters on 16 lines at once (normal filter 1.4 -> 0.26 ms),
7-byte bool-decoder refills with lzcnt renormalisation, 4-lane IDCT,
16-pixel YUV->RGB (1.1 -> 0.21 ms); lossless: two-level Huffman tables,
per-mode predictors, table-driven colour-index unpacking.
Lossy decode is now 55-65% coefficient parsing (bool-decoder latency).

## HEIC

No SIMD work yet. Baseline: an 8256x5504 10-bit photo decodes in about 2.45 s.
