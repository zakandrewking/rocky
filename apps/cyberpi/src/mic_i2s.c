// See mic_i2s.h.
#include "mic_i2s.h"

#include "driver/i2s_std.h"
#include "esp_check.h"

// Pin facts from CyberPi::begin_microphone() (GPL-3.0
// CyberPi-Library-for-Arduino): the ESP32 is the I2S bus master, driving
// MCLK/BCK/WS into the ES8218E, which replies on DIN.
#define MIC_I2S_MCLK_GPIO 0
#define MIC_I2S_BCK_GPIO 13
#define MIC_I2S_WS_GPIO 14
#define MIC_I2S_DIN_GPIO 35

static const char *TAG = "mic_i2s";

static i2s_chan_handle_t s_rx_chan;

esp_err_t mic_i2s_init(void) {
  i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_1, I2S_ROLE_MASTER);
  ESP_RETURN_ON_ERROR(i2s_new_channel(&chan_cfg, NULL, &s_rx_chan), TAG, "new channel");

  i2s_std_config_t std_cfg = {
      .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(MIC_I2S_SAMPLE_RATE_HZ),
      .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT,
                                                       I2S_SLOT_MODE_MONO),
      .gpio_cfg =
          {
              .mclk = MIC_I2S_MCLK_GPIO,
              .bclk = MIC_I2S_BCK_GPIO,
              .ws = MIC_I2S_WS_GPIO,
              .dout = I2S_GPIO_UNUSED,
              .din = MIC_I2S_DIN_GPIO,
              .invert_flags = {.mclk_inv = false, .bclk_inv = false, .ws_inv = false},
          },
  };
  // The codec puts its one mic channel on the I2S right slot (vendor's
  // I2S_CHANNEL_FMT_ONLY_RIGHT); the PHILIPS mono macro defaults to LEFT.
  std_cfg.slot_cfg.slot_mask = I2S_STD_SLOT_RIGHT;

  ESP_RETURN_ON_ERROR(i2s_channel_init_std_mode(s_rx_chan, &std_cfg), TAG, "init std mode");
  ESP_RETURN_ON_ERROR(i2s_channel_enable(s_rx_chan), TAG, "enable");

  return ESP_OK;
}

esp_err_t mic_i2s_read(int16_t *out_samples, size_t sample_count, TickType_t timeout) {
  size_t bytes_read = 0;
  size_t bytes_wanted = sample_count * sizeof(int16_t);
  esp_err_t err = i2s_channel_read(s_rx_chan, out_samples, bytes_wanted, &bytes_read,
                                    pdTICKS_TO_MS(timeout));
  if (err != ESP_OK) {
    return err;
  }
  return bytes_read == bytes_wanted ? ESP_OK : ESP_ERR_TIMEOUT;
}
