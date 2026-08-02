// Speaker playback via the ESP32's built-in DMA-driven DAC, not the ES8218E
// (that codec is mic input only - see es8218e.h). Matches
// CyberPi::begin_sound() in Makeblock's GPL-3.0 CyberPi-Library-for-Arduino:
// legacy I2S_MODE_DAC_BUILT_IN with the right channel enabled, which is
// GPIO25 (DAC channel 0) on this chip - the modern dac_continuous driver
// used here targets the same pin. 8-bit unsigned PCM, matching the format
// Stage 1 measured coming out of CyberOS's own play_raw_data().
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

esp_err_t speaker_dac_init(void);

// Generates and plays a sine tone for `duration_ms`, blocking until done.
esp_err_t speaker_dac_play_tone(uint32_t freq_hz, uint32_t duration_ms);
