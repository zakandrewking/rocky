// See speaker_dac.h.
#include "speaker_dac.h"

#include <math.h>
#include <stdlib.h>

#include "driver/dac_continuous.h"
#include "esp_check.h"

#define SPEAKER_SAMPLE_RATE_HZ 16000

static const char *TAG = "speaker_dac";

static dac_continuous_handle_t s_dac;

esp_err_t speaker_dac_init(void) {
  dac_continuous_config_t cont_cfg = {
      .chan_mask = DAC_CHANNEL_MASK_CH0,  // GPIO25, matching the vendor's right-channel DAC
      .desc_num = 4,
      .buf_size = 2048,
      .freq_hz = SPEAKER_SAMPLE_RATE_HZ,
      .offset = 0,
      .clk_src = DAC_DIGI_CLK_SRC_DEFAULT,
      .chan_mode = DAC_CHANNEL_MODE_SIMUL,
  };
  ESP_RETURN_ON_ERROR(dac_continuous_new_channels(&cont_cfg, &s_dac), TAG, "new channels");
  ESP_RETURN_ON_ERROR(dac_continuous_enable(s_dac), TAG, "enable");
  return ESP_OK;
}

esp_err_t speaker_dac_play_tone(uint32_t freq_hz, uint32_t duration_ms) {
  size_t sample_count = (size_t)SPEAKER_SAMPLE_RATE_HZ * duration_ms / 1000;
  uint8_t *samples = malloc(sample_count);
  if (samples == NULL) {
    return ESP_ERR_NO_MEM;
  }

  for (size_t i = 0; i < sample_count; i++) {
    float phase = 2.0f * (float)M_PI * (float)freq_hz * (float)i / SPEAKER_SAMPLE_RATE_HZ;
    samples[i] = (uint8_t)(128.0f + 127.0f * sinf(phase));  // unsigned 8-bit, centered at 128
  }

  size_t bytes_loaded = 0;
  esp_err_t err = dac_continuous_write(s_dac, samples, sample_count, &bytes_loaded, 5000);
  free(samples);
  return err;
}
