# TGA conformance files

Used by the `tga conformance files` test in `src/Formats/tga/tga.zig`.
All files were copied unmodified from the image-rs repository
(https://github.com/image-rs/image, `tests/images/tga/testsuite/` and
`tests/reference/tga/testsuite/`).

## Truevision sample images

`cbw8.tga`, `ccm8.tga`, `ctc24.tga`, `utc16.tga`: 128x128 samples from Truevision's
TGA 2.0 conformance suite (RLE gray, RLE color-mapped, RLE 24-bit, raw 16-bit; all
with an image ID and a TGA 2.0 extension area). Originally published free of charge
and under no specific licensing terms on Truevision, Inc.'s FTP server
(`ftp://ftp.truevision.com/pub/TGA.File.Format.Spec/PC.Version/`); copyright
Truevision, Inc. A back-up is kept at http://googlesites.inequation.org/tgautilities.

## image-rs test images

`b5-*.tga` (4x4 16-bit: alpha bit counted or not, color-mapped, unused color map),
`cmap_offset.tga` (color map with a non-zero first index), `bottom_left.tga`,
`bottom_right.tga`, `top_left.tga`, `top_right.tga` (the four origins), and the
`*.tga.png` files, which are image-rs' decodes of the matching `.tga`.
Licensed MIT OR Apache-2.0, like the image-rs project.
