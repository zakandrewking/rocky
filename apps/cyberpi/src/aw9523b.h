// Minimal driver for the AW9523B I2C GPIO expander that sits between the
// ESP32 and the CyberPi's ST7789 LCD control lines (DC/RESET/backlight) and
// front-panel buttons/joystick. Written fresh from register-map facts
// checked in Makeblock's GPL-3.0 CyberPi-Library-for-Arduino
// (apps/cyberpi/docs/upstream-sources.md) - addresses and register numbers
// are hardware facts, not copyrightable expression, so this implementation
// is independent of that GPL code.
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

#define AW9523B_I2C_ADDR 0x58

// Pin numbers: bit 0-7 = P0.0-P0.7, bit 8-15 = P1.0-P1.7 (matches the
// vendor library's own numbering so pin facts transfer directly).
typedef enum {
  AW9523B_P0_6_BUTTON_A = 0x06,
  AW9523B_P1_4_LCD_DC = 0x0c,
  AW9523B_P1_5_LCD_RESET = 0x0d,
  AW9523B_P1_7_LCD_BACKLIGHT = 0x0f,
} aw9523b_pin_t;

esp_err_t aw9523b_init(void);
esp_err_t aw9523b_set_pin_output(aw9523b_pin_t pin);
esp_err_t aw9523b_write_pin(aw9523b_pin_t pin, bool level);

// Reads an input pin. Buttons on this board are active-low (pressed pulls
// the pin to ground), so *pressed is true when the raw pin level is low.
esp_err_t aw9523b_read_pin(aw9523b_pin_t pin, bool *pressed);
