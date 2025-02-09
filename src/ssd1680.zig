const std = @import("std");
const mz = @import("microzig");
const mdf = @import("framework.zig");
const DigitalIO = mdf.base.Digital_IO;
const DatagramDevice = mdf.base.Datagram_Device;
const Pin = mz.hal.gpio.Pin;
pub const delayus_callback = fn (delay: u32) void;

// copied from https://github.com/mbv/ssd1680

pub const SSD1680_Pins_Config = struct {
    BUSY: DigitalIO,
    RST: DigitalIO,
    DC: DigitalIO,
    CS: DigitalIO,
    SCL: DigitalIO,
    SDA: DatagramDevice,
};

const RESET_DELAY_MS = std.time.ns_per_ms * 10;

const Commands = enum(u4) {
    // Init
    SW_RESET = 0x12,
    DRIVER_CONTROL = 0x01,
    DATA_ENTRY_MODE = 0x11,
    TEMP_CONTROL = 0x18,
    BORDER_WAVEFORM_CONTROL = 0x3C,
    DISPLAY_UPDATE_CONTROL = 0x21,
    SET_RAMXPOS = 0x44,
    SET_RAMYPOS = 0x45,

    // Update
    SET_RAMX_COUNTER = 0x4E,
    SET_RAMY_COUNTER = 0x4F,
    WRITE_BW_DATA = 0x24,
    WRITE_RED_DATA = 0x26,
    UPDATE_DISPLAY_CTRL2 = 0x22,
    MASTER_ACTIVATE = 0x20,
};

const Flag = enum(u3) {
    DATA_ENTRY_INCRY_INCRX = 0b11,
    INTERNAL_TEMP_SENSOR = 0x80,
    BORDER_WAVEFORM_FOLLOW_LUT = 0b0100,
    BORDER_WAVEFORM_LUT1 = 0b0001,
    DISPLAY_MODE_1 = 0xF7,
};

const Color = enum(u1) {
    Black = 0,
    White = 1,
};

pub fn SSD1680(comptime pins: SSD1680_Pins_Config, height: u16, width: u16, delay_callback: delayus_callback) type {
    return struct {
        height: @TypeOf(height) = height,
        width: @TypeOf(width) = width,
        pins: SSD1680_Pins_Config = pins,
        internal_delay: *const delay_callback,

        const Self = @This();

        fn init(self: Self) !void {
            try self.reset();
            try self.cmd(.SW_RESET);
            try self.waitUntilIdle();

            const payload: [2]u8 = @bitCast(self.height - 1);
            try self.cmdSendData(.DRIVER_CONTROL, &[_]u8{ payload[0], payload[1], 0 });
            try self.cmdSendData(.DATA_ENTRY_MODE, &[_]u8{@intFromEnum(Flag.DATA_ENTRY_INCRY_INCRX)});
            try self.cmdSendData(.BORDER_WAVEFORM_CONTROL, &[_]u8{
                @intFromEnum(Flag.BORDER_WAVEFORM_FOLLOW_LUT) | @intFromEnum(Flag.BORDER_WAVEFORM_LUT1),
            });
            try self.cmdSendData(.TEMP_CONTROL, &[_]u8{@intFromEnum(Flag.INTERNAL_TEMP_SENSOR)});
            try self.cmdSendData(.DISPLAY_UPDATE_CONTROL, &[_]u8{ 0x00, 0x80 });

            try self.useFullFrame();
            try self.waitUntilIdle();
        }

        fn useFullFrame(self: Self) !void {
            try self.setRamArea(0, 0, self.width - 1, self.height - 1);
        }

        fn setRamArea(self: Self, start_x: u16, start_y: u16, end_x: u16, end_y: u16) !void {
            try self.cmdSendData(.SET_RAMXPOS, &[_]u8{ @truncate(start_x >> 3), @truncate(end_x >> 3) });
            try self.cmdSendData(.SET_RAMYPOS, &[_]u8{
                @truncate(start_y),
                @truncate(start_y >> 8),
                @truncate(end_y),
                @truncate(end_y >> 8),
            });
        }

        fn cmd(self: Self, command: Commands) !void {
            try self.pins.DC.write(.low);
            try self.pins.SDA.write(&.{@intFromEnum(command)});
        }

        fn cmdSendData(self: Self, command: Commands, data: []const u8) !void {
            try self.cmd(command);
            try self.sendData(data);
        }

        fn sendData(self: Self, data: []const u8) !void {
            try self.pins.DC.write(.high);
            try self.pins.SDA.write(data);
        }

        fn sendNdata(self: Self, value: u8, repeats: u32) !void {
            try self.pins.DC.write(.high);
            for (0..repeats) |_| {
                try self.pins.SDA.write(&[_]u8{value});
            }
        }

        fn waitUntilIdle(self: Self) !void {
            while (try self.pins.BUSY.read() == .high) {
                self.internal_delay(std.time.ns_per_ms);
            }
        }

        fn reset(self: Self) !void {
            try self.pins.RST.write(.low);
            self.internal_delay(RESET_DELAY_MS);
            try self.pins.RST.write(.high);
            self.internal_delay(RESET_DELAY_MS);
        }

        pub fn clearBwFrame(self: Self) !void {
            try self.useFullFrame();
            try self.cmd(.WRITE_BW_DATA);
            try self.sendNdata(@intFromEnum(Color.White), self.width / (self.height * 8));
        }

        pub fn clearRedFrame(self: Self) !void {
            try self.useFullFrame();
            try self.cmd(.WRITE_RED_DATA);
            try self.sendNdata(@intFromEnum(Color.Black), self.width / (self.height * 8));
        }

        pub fn updateBwFrame(self: Self, data: []const u8) !void {
            try self.useFullFrame();
            try self.cmdSendData(.WRITE_BW_DATA, data);
        }

        pub fn updateRedFrame(self: Self, data: []const u8) !void {
            try self.useFullFrame();
            try self.cmdSendData(.WRITE_RED_DATA, data);
        }

        pub fn displayFrame(self: Self) !void {
            try self.cmdSendData(.UPDATE_DISPLAY_CTRL2, &[]u8{@intFromEnum(Flag.DISPLAY_MODE_1)});
            try self.cmd(.MASTER_ACTIVATE);
            try self.waitUntilIdle();
        }

        pub fn setRamCounter(self: Self, x: u16, y: u16) !void {
            try self.cmdSendData(.SET_RAMX_COUNTER, &[]u8{@truncate(x >> 3)});
            try self.cmdSendData(.SET_RAMY_COUNTER, &[]u8{ @truncate(y), @truncate(y >> 8) });
        }
    };
}
