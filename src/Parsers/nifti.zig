// .nii, .nii.gz, .hdr - read as nifti-1.1
// analyze 7.5 format: hdr = .hdr, image = .img
// both compressed using deflate algorithm - .gzip, .nii.gz
// dimensions: x, y, z, t, remaining dims = other stuff
// 5th dimension = voxel-specific distribution params or vector-based data
// 348 bytes hdr
const std = @import("std");

pub fn read(r: *std.Io.Reader) !void {
    const data = try r.take(348);
    // const size_of_hdr: i32 = @bitCast(data[0..4].*);
    // const dim_info = data[39];
    // const dim: []const u16 = @bitCast(data[40..][0..16].*); // array of dimensions
    // const intent_p1: f32 = @bitCast(data[56..][0..4].*);
    // const intent_p2: f32 = @bitCast(data[60..][0..4].*);
    // const intent_p3: f32 = @bitCast(data[64..][0..4].*);
    // const intent_code: u16 = @bitCast(data[68..][0..2].*);
    // const data_type: u16 = @bitCast(data[70..][0..2].*);
    // const bitpix: u16 = @bitCast(data[72..][0..2].*);
    // const slice_start: u16 = @bitCast(data[74..][0..2].*);
    // const pix_dim: f32 = @bitCast(data[76..][0..32].*);
    // const vox_offset: f32 = @bitCast(data[108..][0..4].*);
    // const scl_slope: f32 = @bitCast(data[112..][0..4].*);
    // const scl_inter: f32 = @bitCast(data[116..][0..4].*);
    // const slice_end: u16 = @bitCast(data[120..][0..2].*);
    // const slice_code = data[122];
    // const xyzt_units = data[123];
    // const cal_max: f32 = @bitCast(data[124..][0..4].*);
    // const cal_min: u32 = @bitCast(data[128..][0..4].*);
    // const slice_duration: f32 = @bitCast(data[132..][0..4].*);
    // const toffset: f32 = @bitCast(data[136..][0..4].*);
    // // const glmax: i32 = @bitCast(data[140..][0..4].*);
    // // const glmin: i32 = @bitCast(data[144..][0..4].*);
    // const descrip = data[148..][0..80];
    // const aux_file = data[228..][0..24];
    // // orientation:
    // // coordinates = center of voxels
    // // world coordinate system = ras: +x = right, +y = anterior, +z = superior = nifti
    // // analyze = las
    // // 3 methods to map voxels (i,j,k) to world coords (x,y,z)
    // const qform_code: u16 = @bitCast(data[252..][0..2].*);
    // const sform_code: u16 = @bitCast(data[254..][0..2].*);
    //
    // const quatern_b: f32 = @bitCast(data[256..][0..4].*);
    // const quatern_c: f32 = @bitCast(data[260..][0..4].*);
    // const quatern_d: f32 = @bitCast(data[264..][0..4].*);
    // const qoffset_x: f32 = @bitCast(data[268..][0..4].*);
    // const qoffset_y: f32 = @bitCast(data[272..][0..4].*);
    // const qoffset_z: f32 = @bitCast(data[276..][0..4].*);
    // const srow_x: [4]f32 = @bitCast(data[280..][0..16].*);
    // const srow_y: f32 = @bitCast(data[296..][0..16].*);
    // const srow_z: f32 = @bitCast(data[312..][0..16].*);
    // const intent_name = data[328..][0..16];
    const sig_str = data[344..][0..4];

    // check values
    const sig = std.meta.stringToEnum(Signature, sig_str) orelse {
        std.debug.print("{any}\n", .{sig_str});
        return error.UnsupportedSignature;
    };
    std.debug.print("Found: {t}\n", .{sig});

    // ni1 = hdr img pair
    // n+1 = single nifti img
    // var is_valid_sig: bool = false;
    // for ([_][]const u8{ "ni1", "n+1" }) |exp_sig| {
    //     if (std.mem.eql(u8, sig, exp_sig)) {
    //         is_valid = true;
    //         break;
    //     }
    // }

    // if (size_of_hdr != 348) return error.IncorrectHeaderSize;
    // if (dim_info > 3) return error.IncorrectDimInfo;
}

const Signature = enum {
    ni1,
    @"n+1",
};

const QFormCodes = enum(u16) {
    unknown = 0, // arbitrary coordinates, use method 1
    scanner_anat = 1, // scanner based coords
    aligned_anat = 2, // coords aligned to another file = truth
    talairach = 3, // tailarach space
    mni_152 = 4, // mni 152 space
};

const PixelCoord = struct {
    i: u32,
    j: u32,
    k: u32,
};

const ImageCoord = struct { x: u32, y: u32, z: u32 };

const Orientation = struct {
    /// Simple method, not the base use case
    fn method1(pixel_coords: PixelCoord, pix_dim: [3]u32) ImageCoord {
        return .{
            .x = pixel_coords.i * pix_dim[0],
            .y = pixel_coords.j * pix_dim[1],
            .z = pixel_coords.k * pix_dim[2],
        };
    }

    /// When qform > 0
    /// quats = b, c, d parts of quaternion
    /// construct rotation matrix from quaternion
    /// R pix_coords * pix dims + offsets
    fn method2(quats: *const [3]f32, pixel_coords: PixelCoord) ImageCoord {
        const b = quats[0];
        const c = quats[1];
        const d = quats[2];

        const b2 = b * b;
        const c2 = c * c;
        const d2 = d * d;

        const a = @sqrt(1 - b2 - c2 - d2);
        const a2 = a * a;

        const bc = b * c;
        const ad = a * d;
        const bd = b * d;
        const ac = a * c;
        const cd = c * d;
        const ab = a * b;

        // starts as rotation matrix
        var mat: [3][3]f32 = .{
            .{ a2 + b2 - c2 - d2, 2 * (bc - ad), 2 * (bd + ac) },
            .{ 2 * (bc + ad), a2 + c2 - b2 - d2, 2 * (cd - ab) },
            .{ 2 * (bd - ac), 2 * (cd + ab), a2 + d2 - b2 - c2 },
        };
        // matrix multiply vector
        var vec = [_]f32{0} ** 3;
        inline for (0..3) |l| {
            mat[l][0] *= pixel_coords.i;
            vec[0] += mat[l][0];
            mat[l][1] *= pixel_coords.j;
            vec[1] += mat[l][1];
            mat[l][2] *= pixel_coords.k;
            vec[2] += mat[l][2];
        }
    }
};

pub fn write(w: *std.Io.Writer) !void {}
