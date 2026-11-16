# TGA test files from image-rs

Used by the `tga image-rs files` test in `src/Formats/tga/tga.zig`.
All files were copied unmodified from the image-rs repository
(https://github.com/image-rs/image, `tests/images/tga/testsuite/` and
`tests/reference/tga/testsuite/`), licensed MIT OR Apache-2.0 like the
image-rs project.

`b5-*.tga` (4x4 16-bit: alpha bit counted or not, color-mapped, unused color map),
`cmap_offset.tga` (color map with a non-zero first index), `bottom_left.tga`,
`bottom_right.tga`, `top_left.tga`, `top_right.tga` (the four origins), and the
`*.tga.png` files, which are image-rs' decodes of the matching `.tga`.

Truevision's TGA 2.0 sample images (`cbw8.tga`, `ccm8.tga`, `ctc24.tga`,
`utc16.tga`) used to be here. Truevision published them with no licence terms,
so they were removed; the `tga 128x128 picture in four encodings` test now
generates the same cases (RLE gray, RLE color-mapped, RLE 24-bit, raw 16-bit
with an image ID and an extension area).
