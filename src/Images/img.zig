const vk = @import("Vulkan");

width: u32 = 1,
height: u32 = 1,
depth: u32 = 1,
pixels: []u8 = undefined,
format: vk.Format = .r8g8b8a8_srgb, // need to abstract from backend
