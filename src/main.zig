const std = @import("std");
const disp = @import("ssd1680.zig");
const mdf = @import("framework.zig");
const dp = @import("dp.zig");
const DigitalIO = mdf.base.Digital_IO;


// SCK (Serial Clock): GPIO 18
// MOSI (Master Out Slave In): GPIO 19
// MISO (Master In Slave Out): GPIO 16
// CS (Chip Select): GPIO 17


pub fn main() !void {
    DigitalIO{.object = }
}
