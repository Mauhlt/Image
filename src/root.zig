const std = @import("std");
// 5 Image Formats To Support:
// Jpeg, PNG, BMP, TGA, DDS, SVG, Webp, QOI, HEIF
// BMP/TIFF = faster due to less processing but more memory
// Jpeg for lossy, png for non-lossy
// HEIF for memory compression
