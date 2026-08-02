// ES8218E microphone codec (I2C register control only; the audio samples
// themselves travel over a separate I2S bus, see mic_i2s.h). Register
// addresses, reset values, and the exact init sequence come from Makeblock's
// GPL-3.0 CyberPi-Library-for-Arduino (facts only - see
// docs/upstream-sources.md); this implementation is written independently.
//
// The chip is ADC (mic) only: it has no DAC output path, which matches the
// vendor library's own speaker code using the ESP32's built-in DAC over a
// different bus entirely (see speaker_dac.h). "Codec" here means "the mic
// input chain," not full duplex audio.
#pragma once

#include "esp_err.h"

#define ES8218E_I2C_ADDR 0x10  // 0x11 when the board's CE pin is tied high

// Configures the codec as an I2S slave (clocked by the ESP32) for 16 kHz,
// 16-bit mono capture, and powers up the ADC path. Call after
// cyberpi_i2c_bus_init() (see i2c_bus.h) and before starting the I2S RX
// channel in mic_i2s.h - the codec must be listening before its bit/word
// clocks start toggling.
esp_err_t es8218e_init(void);
