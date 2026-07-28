// Minimal ST7789 driver for the CyberPi's 128x128 display. SPI pins
// (MOSI/CLK/CS) and the panel geometry/offset are hardware facts checked in
// Makeblock's GPL-3.0 CyberPi-Library-for-Arduino (upstream-sources.md);
// this implementation is written fresh against ESP-IDF's spi_master driver
// and the ST7789's own public command set (the same opcodes appear
// identically in Adafruit's, TFT_eSPI's, and ESP-IDF's own Apache-2.0
// esp_lcd_panel_st7789.c - they are the chip's documented protocol, not
// copyrightable expression). DC/RESET/backlight are driven through the
// AW9523B I2C GPIO expander, not raw ESP32 pins - see aw9523b.h.
#pragma once

#include <stdint.h>

#include "esp_err.h"

#define ST7789_WIDTH 128
#define ST7789_HEIGHT 128

#define ST7789_MOSI_GPIO 2
#define ST7789_CLK_GPIO 4
#define ST7789_CS_GPIO 12

esp_err_t st7789_init(void);

// Fills the whole screen with a single RGB565 color.
esp_err_t st7789_fill(uint16_t color565);
