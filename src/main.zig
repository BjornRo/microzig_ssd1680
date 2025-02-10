const std = @import("std");
const mz = @import("microzig");
// const mdf = @import("framework.zig");
// const mdf = mz.framework;
// const mdf = @import("../framework.zig");
// const DigitalIO = mdf.base.Digital_IO;
const SSD1680 = @import("ssd1680.zig").SSD1680;
const rp2040 = mz.hal;
// const spi = rp2040.spi;
const SPIDevice = rp2040.drivers.SPI_Device;
const GPIODevice = rp2040.drivers.GPIO_Device;
const gpio = rp2040.gpio;
const timer = rp2040.time;

const spi0 = rp2040.spi.instance.SPI0;

pub fn delay_us(time_delay: u32) void {
    timer.sleep_us(time_delay);
}

// SCK (Serial Clock), SCL: GPIO 18
// MOSI (Master Out Slave In), SDA: GPIO 19
// MISO (Master In Slave Out): __GPIO 16__
// CS (Chip Select): GPIO 17

pub fn main() !void {
    var busy_pin = GPIODevice.init(gpio.num(0));
    var rst_pin = GPIODevice.init(gpio.num(1));
    var dc_pin = GPIODevice.init(gpio.num(2));

    const scl_pin = gpio.num(18);
    const sda_pin = gpio.num(19);
    const cs_pin = gpio.num(17);
    inline for (&.{ scl_pin, sda_pin, cs_pin }) |pin| {
        pin.set_function(.spi);
    }
    try spi0.apply(.{
        .clock_config = rp2040.clock_config,
        .data_width = .eight,
    });

    var spi_device = SPIDevice.init(spi0, cs_pin, .{});

    const ssd1680 = SSD1680(.{ .mode = .spi_4wire }, 296, 128, delay_us);
    _ = try ssd1680.init(
        spi_device.datagram_device(),
        dc_pin.digital_io(),
        busy_pin.digital_io(),
        rst_pin.digital_io(),
    );
}
