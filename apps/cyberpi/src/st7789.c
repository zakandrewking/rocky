#include "st7789.h"

#include <stdlib.h>
#include <string.h>

#include "aw9523b.h"
#include "driver/spi_master.h"
#include "esp_check.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

// This panel's 128x128 active area sits inside the ST7789's 240x320
// controller RAM starting at this offset - a fact of this specific module,
// not a general ST7789 constant.
#define PANEL_X_OFFSET 3
#define PANEL_Y_OFFSET 2

#define CMD_SWRESET 0x01
#define CMD_SLPOUT 0x11
#define CMD_INVON 0x21
#define CMD_NORON 0x13
#define CMD_DISPON 0x29
#define CMD_CASET 0x2a
#define CMD_RASET 0x2b
#define CMD_RAMWR 0x2c
#define CMD_MADCTL 0x36
#define CMD_COLMOD 0x3a

static const char *TAG = "st7789";
static spi_device_handle_t s_spi;

static esp_err_t send(const uint8_t *bytes, size_t len, bool is_data) {
  ESP_RETURN_ON_ERROR(aw9523b_write_pin(AW9523B_P1_4_LCD_DC, is_data), TAG,
                       "set dc");
  spi_transaction_t t = {
      .length = len * 8,
      .tx_buffer = bytes,
  };
  return spi_device_polling_transmit(s_spi, &t);
}

static esp_err_t write_cmd(uint8_t cmd) { return send(&cmd, 1, false); }

static esp_err_t write_data(const uint8_t *data, size_t len) {
  return send(data, len, true);
}

static esp_err_t set_addr_window(uint16_t x0, uint16_t y0, uint16_t x1,
                                  uint16_t y1) {
  x0 += PANEL_X_OFFSET;
  x1 += PANEL_X_OFFSET;
  y0 += PANEL_Y_OFFSET;
  y1 += PANEL_Y_OFFSET;

  uint8_t caset[4] = {x0 >> 8, x0 & 0xff, x1 >> 8, x1 & 0xff};
  uint8_t raset[4] = {y0 >> 8, y0 & 0xff, y1 >> 8, y1 & 0xff};

  ESP_RETURN_ON_ERROR(write_cmd(CMD_CASET), TAG, "caset cmd");
  ESP_RETURN_ON_ERROR(write_data(caset, sizeof(caset)), TAG, "caset data");
  ESP_RETURN_ON_ERROR(write_cmd(CMD_RASET), TAG, "raset cmd");
  ESP_RETURN_ON_ERROR(write_data(raset, sizeof(raset)), TAG, "raset data");
  return write_cmd(CMD_RAMWR);
}

esp_err_t st7789_init(void) {
  ESP_RETURN_ON_ERROR(aw9523b_set_pin_output(AW9523B_P1_4_LCD_DC), TAG,
                       "dc as output");
  ESP_RETURN_ON_ERROR(aw9523b_set_pin_output(AW9523B_P1_5_LCD_RESET), TAG,
                       "reset as output");
  ESP_RETURN_ON_ERROR(aw9523b_set_pin_output(AW9523B_P1_7_LCD_BACKLIGHT), TAG,
                       "backlight as output");

  spi_bus_config_t bus_config = {
      .mosi_io_num = ST7789_MOSI_GPIO,
      .miso_io_num = -1,
      .sclk_io_num = ST7789_CLK_GPIO,
      .quadwp_io_num = -1,
      .quadhd_io_num = -1,
      .max_transfer_sz = ST7789_WIDTH * ST7789_HEIGHT * 2,
  };
  ESP_RETURN_ON_ERROR(spi_bus_initialize(SPI2_HOST, &bus_config, SPI_DMA_CH_AUTO),
                       TAG, "spi bus init");

  spi_device_interface_config_t dev_config = {
      .clock_speed_hz = 20 * 1000 * 1000,
      .mode = 0,
      .spics_io_num = ST7789_CS_GPIO,
      .queue_size = 1,
  };
  ESP_RETURN_ON_ERROR(spi_bus_add_device(SPI2_HOST, &dev_config, &s_spi), TAG,
                       "spi add device");

  ESP_RETURN_ON_ERROR(aw9523b_write_pin(AW9523B_P1_5_LCD_RESET, true), TAG,
                       "reset high");
  vTaskDelay(pdMS_TO_TICKS(10));
  ESP_RETURN_ON_ERROR(aw9523b_write_pin(AW9523B_P1_5_LCD_RESET, false), TAG,
                       "reset low");
  vTaskDelay(pdMS_TO_TICKS(10));
  ESP_RETURN_ON_ERROR(aw9523b_write_pin(AW9523B_P1_5_LCD_RESET, true), TAG,
                       "reset release");
  vTaskDelay(pdMS_TO_TICKS(150));

  ESP_RETURN_ON_ERROR(write_cmd(CMD_SWRESET), TAG, "swreset");
  vTaskDelay(pdMS_TO_TICKS(150));
  ESP_RETURN_ON_ERROR(write_cmd(CMD_SLPOUT), TAG, "slpout");
  vTaskDelay(pdMS_TO_TICKS(120));

  uint8_t colmod = 0x55;  // 16 bits/pixel (RGB565)
  ESP_RETURN_ON_ERROR(write_cmd(CMD_COLMOD), TAG, "colmod cmd");
  ESP_RETURN_ON_ERROR(write_data(&colmod, 1), TAG, "colmod data");

  uint8_t madctl = 0x00;  // default orientation
  ESP_RETURN_ON_ERROR(write_cmd(CMD_MADCTL), TAG, "madctl cmd");
  ESP_RETURN_ON_ERROR(write_data(&madctl, 1), TAG, "madctl data");

  // ST7789 panels commonly need color inversion on to render true colors -
  // a documented quirk of the panel, not optional.
  ESP_RETURN_ON_ERROR(write_cmd(CMD_INVON), TAG, "invon");
  ESP_RETURN_ON_ERROR(write_cmd(CMD_NORON), TAG, "noron");
  vTaskDelay(pdMS_TO_TICKS(10));
  ESP_RETURN_ON_ERROR(write_cmd(CMD_DISPON), TAG, "dispon");
  vTaskDelay(pdMS_TO_TICKS(100));

  ESP_RETURN_ON_ERROR(aw9523b_write_pin(AW9523B_P1_7_LCD_BACKLIGHT, true),
                       TAG, "backlight on");

  return ESP_OK;
}

esp_err_t st7789_fill(uint16_t color565) {
  ESP_RETURN_ON_ERROR(
      set_addr_window(0, 0, ST7789_WIDTH - 1, ST7789_HEIGHT - 1), TAG,
      "set addr window");

  size_t pixel_count = (size_t)ST7789_WIDTH * ST7789_HEIGHT;
  uint8_t *buf = malloc(pixel_count * 2);
  if (buf == NULL) {
    return ESP_ERR_NO_MEM;
  }
  // Byte order determined empirically: a pure-green test fill (0x07E0, zero
  // in both the R and B fields) rendered solid purple/red - the signature of
  // the two pixel bytes arriving swapped, not a channel-order (RGB/BGR)
  // issue, which a zero-R/zero-B test color can't distinguish.
  uint8_t hi = color565 >> 8;
  uint8_t lo = color565 & 0xff;
  for (size_t i = 0; i < pixel_count; i++) {
    buf[i * 2] = lo;
    buf[i * 2 + 1] = hi;
  }

  esp_err_t err = write_data(buf, pixel_count * 2);
  free(buf);
  return err;
}
