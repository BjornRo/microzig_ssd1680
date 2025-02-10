const std = @import("std");
const mz = @import("microzig");
// const mdf = @import("framework.zig");
const mdf = mz.drivers;
// const mdf = @import("../framework.zig");
// const DigitalIO_ = mdf.base.Digital_IO;
// const DatagramDevice_ = @import("base/Datagram_Device.zig");
// const Pin = mz.hal.gpio.Pin;
pub const delayus_callback = fn (delay: u32) void;

// copied from https://github.com/mbv/ssd1680
// and https://github.com/marko-pi/parallel/blob/main/SSD1680.py

const Command = enum(u8) {
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
    WRITE_WHITE_DATA = 0x24,
    WRITE_RED_DATA = 0x26,
    UPDATE_DISPLAY_CTRL2 = 0x22,
    MASTER_ACTIVATE = 0x20,
};

const TempSensor = enum(u8) {
    External = 0x48,
    Internal = 0x80,
};

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

pub const DriverMode = enum {
    /// The driver operates in the 3-wire SPI mode, which requires a 9 bit datagram device.
    spi_3wire,

    /// The driver operates in the 4-wire SPI mode, which requires an 8 bit datagram device
    /// as well as a command/data digital i/o.
    spi_4wire,

    /// The driver can be initialized with one of the other options and receives
    /// the mode with initialization.
    dynamic,
};

pub const SSD1680_Options = struct {
    /// Defines the operation of the SSD1680 driver.
    mode: DriverMode,

    /// Which datagram device interface should be used.
    Datagram_Device: type = mdf.base.Datagram_Device,

    /// Which digital i/o interface should be used.
    Digital_IO: type = mdf.base.Digital_IO,
};

const RESET_DELAY_MS = std.time.ns_per_ms * 10;

pub fn SSD1680(comptime options: SSD1680_Options, height: u16, width: u16, delay_callback: delayus_callback) type {
    switch (options.mode) {
        .spi_4wire => {},
        .spi_3wire, .dynamic => @compileError("3-wire SPI / .dynamic operation is not supported yet!"),
    }

    return struct {
        const Self = @This();

        const DatagramDevice = options.Datagram_Device;
        const DigitalIO = switch (options.mode) {
            // 4-wire SPI mode uses a dedicated command/data control pin:
            .spi_4wire, .dynamic => options.Digital_IO,

            // The other two modes don't use that, so we use a `void` pin here to save
            // memory:
            .spi_3wire => void,
        };

        pub const DriverInitMode = union(enum) {
            spi_3wire: noreturn,
            spi_4wire: struct {
                device: DatagramDevice,
                dc_pin: DigitalIO,
            },
        };

        const Mode = switch (options.mode) {
            .dynamic => DriverMode,
            else => void,
        };

        height: @TypeOf(height) = height,
        width: @TypeOf(width) = width,
        internal_delay: *const delayus_callback = delay_callback,

        dd: DatagramDevice,
        mode: Mode,
        busy_pin: DigitalIO,
        rst_pin: DigitalIO,
        dc_pin: DigitalIO,

        /// Initializes the device and sets up sane defaults.
        pub const init = switch (options.mode) {
            .spi_3wire => initWithoutIO,
            .spi_4wire => initWithIO,
            .dynamic => initWithMode,
        };

        /// Creates an instance with only a datagram device.
        /// `init` will be an alias to this if the init requires no D/C pin.
        fn initWithoutIO(dev: DatagramDevice, busy_pin: DigitalIO, rst_pin: DigitalIO) !Self {
            var self = Self{
                .dd = dev,
                .busy_pin = busy_pin,
                .rst_pin = rst_pin,
                .dc_pin = {},
                .mode = {},
            };
            try busy_pin.set_direction(.input);
            try rst_pin.set_direction(.output);

            try self.initSequence();
            return self;
        }

        /// Creates an instance with a datagram device and the D/C pin.
        /// `init` will be an alias to this if the init requires a D/C pin.
        fn initWithIO(dev: DatagramDevice, dc_pin: DigitalIO, busy_pin: DigitalIO, rst_pin: DigitalIO) !Self {
            var self = Self{
                .dd = dev,
                .busy_pin = busy_pin,
                .rst_pin = rst_pin,
                .dc_pin = dc_pin,
                .mode = {},
            };

            try busy_pin.set_direction(.input);
            try rst_pin.set_direction(.output);
            try dc_pin.set_direction(.output);

            try self.initSequence();
            return self;
        }

        fn initWithMode(mode: DriverInitMode, busy_pin: DigitalIO, rst_pin: DigitalIO) !Self {
            var self = Self{
                .dd = switch (mode) {
                    .spi_3wire => @compileError("TODO"),
                    .spi_4wire => |opt| opt.device,
                },
                .dc_pin = switch (mode) {
                    .spi_3wire => @compileError("TODO"),
                    .spi_4wire => |opt| opt.dc_pin,
                },
                .mode = switch (mode) {
                    .spi_3wire => .spi_3wire,
                    .spi_4wire => .spi_4wire,
                },
                .busy_pin = busy_pin,
                .rst_pin = rst_pin,
            };

            if (self.mode == .spi_4wire) {
                try self.busy_pin.set_direction(.input);
                try self.rst_pin.set_direction(.output);
                try self.dc_pin.set_direction(.output);
            }

            try self.initSequence();
            return self;
        }

        /// If present, sets the D/C pin to the required mode.
        /// NOTE: This function must be called *before* activating the device
        ///       via chip select, so before calling `(..).connect`!
        fn setDcPin(self: Self, mode: enum { command, data }) !void {
            try self.dc_pin.write(switch (mode) {
                .command => .low,
                .data => .high,
            });
        }

        fn control(self: Self, cmd: Command) !void {
            try self.setDcPin(.command);

            try self.dd.connect();
            defer self.dd.disconnect();

            try self.dd.write(&.{@intFromEnum(cmd)});
        }

        fn command(self: Self, cmd: Command, data: []const u8) !void {
            try self.control(cmd);
            try self.setDcPin(.data);

            try self.dd.connect();
            defer self.dd.disconnect();

            try self.dd.write(data);
        }

        fn commandRepeat(self: Self, cmd: Command, value: u8, repeats: u16) !void {
            try self.control(cmd);
            try self.setDcPin(.data);

            try self.dd.connect();
            defer self.dd.disconnect();

            for (0..repeats) |_| {
                try self.dd.write(&[_]u8{value});
            }
        }

        fn waitUntilIdle(self: Self) !void {
            while (try self.busy_pin.read() == .high) {
                self.internal_delay(std.time.ns_per_ms);
            }
        }

        fn useFullAddressRange(self: Self) !void {
            try self.setRamArea(0, self.width - 1, 0, self.height - 1);
        }

        fn resetHW(self: Self) !void {
            try self.setDcPin(.data);

            try self.rst_pin.write(.high);
            self.internal_delay(RESET_DELAY_MS);

            try self.rst_pin.write(.low);
            self.internal_delay(RESET_DELAY_MS);

            try self.rst_pin.write(.high);
        }

        fn initSequence(self: Self) !void {
            try self.resetHW();
            try self.control(.SW_RESET);
            try self.waitUntilIdle();

            const left, const right = u16To2u8(self.height - 1);
            try self.command(.DRIVER_OUTPUT_CONTROL, &[_]u8{ left, right, 0 });
            try self.command(.BORDER_WAVEFORM_CONTROL, &[_]u8{borderWaveFormControl(.LUT1, .FOLLOW_LUT, .VSS, .GS_TRANSITION)});
            try self.command(.DISPLAY_UPDATE_CONTROL, &[_]u8{ 0x00, 0x80 });
            try self.command(.TEMP_SENSOR, &[_]u8{@intFromEnum(TempSensor.Internal)});

            try self.command(.DATA_ENTRY_MODE, &[_]u8{0x3});
            try self.useFullAddressRange(); // 0x44, 0x45
            try self.setRamAddress(0, 0);

            try self.waitUntilIdle();
        }

        pub fn setRamAddress(self: Self, x: u16, y: u16) !void {
            try self.command(.SET_RAMX_ADDRESS, &[_]u8{@truncate(x >> 3)});
            try self.command(.SET_RAMY_ADDRESS, &u16To2u8(y));
        }

        pub fn setRamArea(self: Self, start_x: u16, end_x: u16, start_y: u16, end_y: u16) !void {
            try self.command(.SET_RAMX_RANGE, &[_]u8{ @truncate(start_x >> 3), @truncate(end_x >> 3) });
            const start = u16To2u8(start_y);
            const end = u16To2u8(end_y);
            try self.command(.SET_RAMY_RANGE, &[_]u8{ start[0], start[1], end[0], end[1] });
        }

        pub fn clearColorBuffer(self: Self, color: enum { Red, White }) !void {
            const ScreenColor = enum(u1) {
                Black = 0,
                White = 1,
            };
            try self.useFullAddressRange();
            const opt: struct { cmd: Command, color: ScreenColor } = if (color == .Red)
                .{ .cmd = .WRITE_RED_DATA, .color = .Black }
            else
                .{ .cmd = .WRITE_WHITE_DATA, .color = .White };
            try self.control(opt.cmd);
            try self.commandRepeat(@intFromEnum(opt.color), (self.width / 8) * self.height);
        }

        pub fn writeColorFullscreen(self: Self, color: enum { Red, White }, data: []const u8) !void {
            try self.useFullAddressRange();
            try self.command(if (color == .Red) .WRITE_RED_DATA else .WRITE_WHITE_DATA, data);
        }

        pub fn display(self: Self) !void {
            try self.command(.UPDATE_DISPLAY_CTRL2, &[_]u8{0xF7});
            try self.control(.MASTER_ACTIVATE);
            try self.waitUntilIdle();
        }
    };
}

// pub const SSD1680_Pins_Config = struct {
//     BUSY: DigitalIO,
//     RST: DigitalIO,
//     DC: DigitalIO,
//     CS: DigitalIO,
//     SCL: DigitalIO,
//     SDA: DatagramDevice,
// };

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
