# PNG test fixtures

## PngSuite (`*.png` without `.wic`)

From PngSuite by Willem van Schaik, release 2017-07-19
(http://www.schaik.com/pngsuite/, `PngSuite-2017jul19.tgz`), unmodified. License:

> Permission to use, copy, modify and distribute these images for any
> purpose and without fee is hereby granted.
>
> (c) Willem van Schaik, 1996, 2011

- `basn*` / `basi*`: every color type and bit depth, non-interlaced / Adam7.
  Each pair holds the same picture, so they must decode identically.
- `s01n`..`s09n`, `s33n`..`s39n` / `s01i`..`s39i`: odd sizes (1x1 to 39x39), where
  some Adam7 passes are empty or a single pixel wide.
- `tbbn0g04`, `tbwn0g16`, `tbrn2c08`, `tbbn3p08`, `tm3n3p02`: tRNS for gray
  (4- and 16-bit), rgb and palette images.

## `BasicArt16i.png`

`../BasicArt.png` as 16-bit RGBA (each sample times 257), Adam7, with the
filter chosen per row by the minimum-sum-of-absolutes heuristic and 64 KiB IDAT
chunks. Written by a throwaway
Zig generator for the decode benchmark; it must decode to exactly BasicArt's
pixels, since the high byte of v * 257 is v.

## Windows references (`*.wic.png`)

The PngSuite file of the same name decoded by Windows' WIC decoder
(`BitmapDecoder` + `FormatConvertedBitmap` to `Bgra32`) and saved with
`PngBitmapEncoder` as non-interlaced 8-bit RGBA. WIC applies no gamma to these
files. The only intentional difference: for 16-bit samples we keep the high byte
while WIC rounds, so `basi0g16` is off by at most 1.
