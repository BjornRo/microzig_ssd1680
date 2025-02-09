const std = @import("std");
const mz = @import("microzig");
const mdf = @import("framework.zig");
const DigitalIO = mdf.base.Digital_IO;
const DatagramDevice = mdf.base.Datagram_Device;
const Pin = mz.hal.gpio.Pin;
pub const delayus_callback = fn (delay: u32) void;

// copied from https://github.com/mbv/ssd1680
// and https://github.com/marko-pi/parallel/blob/main/SSD1680.py

const Command = enum(u4) {
    SW_RESET = 0x12,
    DRIVER_OUTPUT_CONTROL = 0x01,
    DATA_ENTRY_MODE = 0x11,
    TEMP_SENSOR = 0x18,
    BORDER_WAVEFORM_CONTROL = 0x3C,
    DISPLAY_UPDATE_CONTROL = 0x21,
    SET_RAMX_RANGE = 0x44,
    SET_RAMY_RANGE = 0x45,

    SET_RAMX_ADDRESS = 0x4E,
    SET_RAMY_ADDRESS = 0x4F,
    WRITE_BW_DATA = 0x24,
    WRITE_RED_DATA = 0x26,
    UPDATE_DISPLAY_CTRL2 = 0x22,
    MASTER_ACTIVATE = 0x20,
};

const TempSensor = enum(u1) {
    External = 0x48,
    Internal = 0x80,
};

// const BorderWaveFormControl = union {
//     const VBDTransitionSetting = enum(u8) { // Vertical blanking display
//         LUT0 = 0b00,
//         LUT1 = 0b01,
//         LUT2 = 0b10,
//         LUT3 = 0b11,
//     };
//     const GSTransitionControl = enum(u8) { // Gate Start
//         FOLLOW_LUT_VCOM = 0,
//         FOLLOW_LUT = 1 << 2,
//     };
//     const VBDLevel = enum(u8) {
//         VSS = 0b00 << 4,
//         VSH1 = 0b01 << 4,
//         VSL = 0b10 << 4,
//         VSH2 = 0b11 << 4,
//     };
//     const VBDOption = enum(u8) {
//         GS_TRANSITION = 0b00 << 6,
//         FIX_LEVEL = 0b01 << 6,
//         VCOM = 0b10 << 6,
//         HiZ = 0b11 << 6,
//     };
// };

fn u16To2u8(value: u16) [2]u8 {
    return .{ @truncate(value & 0xFF), @truncate(value >> 8) };
}

fn borderWaveFormControl(
    VBD_transition: enum(u8) { // Vertical blanking display
        LUT0 = 0b00,
        LUT1 = 0b01,
        LUT2 = 0b10,
        LUT3 = 0b11,
    },
    GS_transition_control: enum(u8) { // Gate Start
        FOLLOW_LUT_VCOM = 0,
        FOLLOW_LUT = 1,
    },
    VBD_level: enum(u8) {
        VSS = 0b00,
        VSH1 = 0b01,
        VSL = 0b10,
        VSH2 = 0b11,
    },
    VBD_option: enum(u8) {
        GS_TRANSITION = 0b00,
        FIX_LEVEL = 0b01,
        VCOM = 0b10,
        HiZ = 0b11,
    },
) u8 {
    return (@intFromEnum(VBD_option) << 6) | (@intFromEnum(VBD_level) << 4) |
        (@intFromEnum(GS_transition_control) << 2) | @intFromEnum(VBD_transition);
}

const Color = enum(u1) {
    Black = 0,
    White = 1,
};

pub const SSD1680_Pins_Config = struct {
    BUSY: DigitalIO,
    RST: DigitalIO,
    DC: DigitalIO,
    CS: DigitalIO,
    SCL: DigitalIO,
    SDA: DatagramDevice,
};

const RESET_DELAY_MS = std.time.ns_per_ms * 10;

pub fn SSD1680(comptime pins: SSD1680_Pins_Config, height: u16, width: u16, delay_callback: delayus_callback) type {
    return struct {
        height: @TypeOf(height) = height,
        width: @TypeOf(width) = width,
        pins: SSD1680_Pins_Config = pins,
        internal_delay: *const delay_callback,

        const Self = @This();

        /// If present, sets the D/C pin to the required mode.
        /// NOTE: This function must be called *before* activating the device
        ///       via chip select, so before calling `(..).connect`!
        fn setDcPin(self: Self, mode: enum { command, data }) !void {
            try self.pins.DC.write(switch (mode) {
                .command => .low,
                .data => .high,
            });
        }

        fn control(self: Self, cmd: Command) !void {
            try self.setDcPin(.command);
            try self.pins.SDA.write(&.{@intFromEnum(cmd)});
        }

        fn command(self: Self, cmd: Command, data: []const u8) !void {
            try self.control(cmd);
            try self.setDcPin(.data);
            try self.pins.SDA.write(data);
        }

        fn commandRepeat(self: Self, cmd: Command, value: u8, repeats: u16) !void {
            try self.control(cmd);
            try self.setDcPin(.data);
            for (0..repeats) |_| {
                try self.pins.SDA.write(&[_]u8{value});
            }
        }

        fn waitUntilIdle(self: Self) !void {
            while (try self.pins.BUSY.read() == .high) {
                self.internal_delay(std.time.ns_per_ms);
            }
        }

        fn useFullAddressRange(self: Self) !void {
            try self.setRamArea(0, self.width - 1, 0, self.height - 1);
        }

        fn resetHW(self: Self) !void {
            try self.setDcPin(.data);

            try self.pins.RST.write(.high);
            self.internal_delay(RESET_DELAY_MS);

            try self.pins.RST.write(.low);
            self.internal_delay(RESET_DELAY_MS);

            try self.pins.RST.write(.high);
        }

        pub fn init(self: Self) !void {
            try self.resetHW();
            try self.control(.SW_RESET);
            try self.waitUntilIdle();

            const left, const right = u16To2u8(self.height - 1);
            try self.command(.DRIVER_OUTPUT_CONTROL, &[]u8{ left, right, 0 });
            try self.command(.BORDER_WAVEFORM_CONTROL, &[]u8{borderWaveFormControl(.LUT1, .FOLLOW_LUT, .VSS, .GS_TRANSITION)});
            try self.command(.DISPLAY_UPDATE_CONTROL, &[]u8{ 0x00, 0x80 });
            try self.command(.TEMP_SENSOR, &[]u8{@intFromEnum(TempSensor.Internal)});

            try self.command(.DATA_ENTRY_MODE, &[]u8{0x3});
            try self.useFullAddressRange(); // 0x44, 0x45
            try self.setRamAddress(0, 0);

            try self.waitUntilIdle();
        }

        pub fn setRamAddress(self: Self, x: u16, y: u16) !void {
            try self.command(.SET_RAMX_ADDRESS, &[]u8{@truncate(x >> 3)});
            try self.command(.SET_RAMY_ADDRESS, &u16To2u8(y));
        }

        pub fn setRamArea(self: Self, start_x: u16, end_x: u16, start_y: u16, end_y: u16) !void {
            try self.command(.SET_RAMX_RANGE, &[]u8{ @truncate(start_x >> 3), @truncate(end_x >> 3) });
            const start = u16To2u8(start_y);
            const end = u16To2u8(end_y);
            try self.command(.SET_RAMY_RANGE, &[]u8{ start[0], start[1], end[0], end[1] });
        }

        pub fn clearBwFrame(self: Self) !void {
            try self.useFullAddressRange();
            try self.control(.WRITE_BW_DATA);
            try self.commandRepeat(@intFromEnum(Color.White), (self.width / 8) * self.height);
        }

        pub fn clearRedFrame(self: Self) !void {
            try self.useFullAddressRange();
            try self.control(.WRITE_RED_DATA);
            try self.commandRepeat(@intFromEnum(Color.Black), (self.width / 8) * self.height);
        }

        pub fn updateBwFrame(self: Self, data: []const u8) !void {
            try self.useFullAddressRange();
            try self.command(.WRITE_BW_DATA, data);
        }

        pub fn updateRedFrame(self: Self, data: []const u8) !void {
            try self.useFullAddressRange();
            try self.command(.WRITE_RED_DATA, data);
        }

        pub fn display(self: Self) !void {
            try self.command(.UPDATE_DISPLAY_CTRL2, &[]u8{0xF7});
            try self.control(.MASTER_ACTIVATE);
            try self.waitUntilIdle();
        }
    };
}
