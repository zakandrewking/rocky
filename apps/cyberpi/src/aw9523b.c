// See aw9523b.h. Register facts (addresses, reset value, and the bit
// polarity of the config/work-mode registers - 0=output/GPIO-mode,
// 1=input/LED-mode) were confirmed by reading Makeblock's GPL-3.0 driver,
// not guessed; this implementation is written independently.
#include "aw9523b.h"

#include "driver/i2c_master.h"
#include "esp_check.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define REG_OUTPUT_P1 0x03
#define REG_CONFIG_P1 0x05
#define REG_WORK_MODE_P0 0x12
#define REG_WORK_MODE_P1 0x13
#define REG_SWRST 0x7f

static const char *TAG = "aw9523b";

static i2c_master_dev_handle_t s_dev;
// Shadow copies: the chip's registers are write-only from our side (we never
// read them back), so each write has to carry every pin's current state, not
// just the one bit that changed.
static uint8_t s_config_p1 = 0xff;  // power-on default: every pin an input
static uint8_t s_output_p1 = 0x00;

static esp_err_t write_reg(uint8_t reg, uint8_t value) {
  uint8_t payload[2] = {reg, value};
  return i2c_master_transmit(s_dev, payload, sizeof(payload), 1000);
}

esp_err_t aw9523b_init(void) {
  i2c_master_bus_config_t bus_config = {
      .i2c_port = -1,
      .sda_io_num = AW9523B_SDA_GPIO,
      .scl_io_num = AW9523B_SCL_GPIO,
      .clk_source = I2C_CLK_SRC_DEFAULT,
      .glitch_ignore_cnt = 7,
  };
  i2c_master_bus_handle_t bus;
  ESP_RETURN_ON_ERROR(i2c_new_master_bus(&bus_config, &bus), TAG, "bus init");

  i2c_device_config_t dev_config = {
      .dev_addr_length = I2C_ADDR_BIT_LEN_7,
      .device_address = AW9523B_I2C_ADDR,
      .scl_speed_hz = 100000,
  };
  ESP_RETURN_ON_ERROR(i2c_master_bus_add_device(bus, &dev_config, &s_dev), TAG,
                       "add device");

  ESP_RETURN_ON_ERROR(write_reg(REG_SWRST, 0x00), TAG, "soft reset");
  vTaskDelay(pdMS_TO_TICKS(10));

  // GPIO mode (not LED constant-current mode) on every pin we might drive.
  ESP_RETURN_ON_ERROR(write_reg(REG_WORK_MODE_P0, 0xff), TAG, "work mode p0");
  ESP_RETURN_ON_ERROR(write_reg(REG_WORK_MODE_P1, 0xff), TAG, "work mode p1");

  return ESP_OK;
}

esp_err_t aw9523b_set_pin_output(aw9523b_pin_t pin) {
  uint8_t bit = pin & 0x07;
  s_config_p1 &= ~(1 << bit);
  return write_reg(REG_CONFIG_P1, s_config_p1);
}

esp_err_t aw9523b_write_pin(aw9523b_pin_t pin, bool level) {
  uint8_t bit = pin & 0x07;
  if (level) {
    s_output_p1 |= (1 << bit);
  } else {
    s_output_p1 &= ~(1 << bit);
  }
  return write_reg(REG_OUTPUT_P1, s_output_p1);
}
