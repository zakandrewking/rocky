// I2S RX bus carrying microphone PCM from the ES8218E codec (es8218e.h
// configures the codec's registers over I2C; this is the separate data
// path). Pin numbers (BCK/WS/DIN/MCLK) come from Makeblock's GPL-3.0
// CyberPi-Library-for-Arduino, CyberPi::begin_microphone() - hardware facts,
// not guessed.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"
#include "freertos/FreeRTOS.h"

#define MIC_I2S_SAMPLE_RATE_HZ 16000
// 10 ms at 16 kHz - the frame size the whole Stage 2 pipeline is built
// around (see PLAN.md).
#define MIC_I2S_FRAME_SAMPLES 160

// Brings up the I2S RX channel as bus master (BCK/WS/MCLK are driven by the
// ESP32; the codec is the I2S slave). The codec itself must already be
// configured via es8218e_init() before this starts toggling clocks.
esp_err_t mic_i2s_init(void);

// Blocking read of exactly `sample_count` 16-bit samples. Returns ESP_OK
// only if the full count was read before `timeout` elapsed.
esp_err_t mic_i2s_read(int16_t *out_samples, size_t sample_count, TickType_t timeout);
