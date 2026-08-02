// See es8218e.h. Register sequence transcribed from es8218e_start() in
// Makeblock's GPL-3.0 CyberPi-Library-for-Arduino
// (lib/cyberpi/src/microphone/es8218e.c) - the exact writes and their order
// are hardware facts (what configures this specific chip on this specific
// board), preserved verbatim including the vendor's own numbers even where
// the reasoning behind a given constant isn't obvious from the register
// datasheet alone.
#include "es8218e.h"

#include "esp_check.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "i2c_bus.h"

#define REG_RESET 0x00
#define REG_CLOCK_MANAGER1 0x01
#define REG_CLOCK_MANAGER2 0x02
#define REG_CLOCK_MANAGER3 0x03
#define REG_SERIAL_DATA_PORT 0x07
#define REG_SYSTEM_CONTROL1 0x08
#define REG_SYSTEM_CONTROL6 0x0d
#define REG_SYSTEM_CONTROL7 0x0e
#define REG_ADC_CONTROL1 0x0f
#define REG_ADC_CONTROL2 0x10
#define REG_ADCVOLUMEL 0x11
#define REG_ADC_CONTROL4 0x12
#define REG_ADC_CONTROL10 0x18
#define REG_ADC_CONTROL11 0x19

static const char *TAG = "es8218e";

static i2c_master_dev_handle_t s_dev;

static esp_err_t write_reg(uint8_t reg, uint8_t value) {
  uint8_t payload[2] = {reg, value};
  return i2c_master_transmit(s_dev, payload, sizeof(payload), 1000);
}

esp_err_t es8218e_init(void) {
  ESP_RETURN_ON_ERROR(cyberpi_i2c_bus_init(), TAG, "shared bus init");

  i2c_device_config_t dev_config = {
      .dev_addr_length = I2C_ADDR_BIT_LEN_7,
      .device_address = ES8218E_I2C_ADDR,
      .scl_speed_hz = 100000,
  };
  ESP_RETURN_ON_ERROR(i2c_master_bus_add_device(cyberpi_i2c_bus(), &dev_config, &s_dev), TAG,
                       "add device");

  ESP_RETURN_ON_ERROR(write_reg(REG_RESET, 0x3f), TAG, "reset assert");
  ESP_RETURN_ON_ERROR(write_reg(REG_RESET, 0x00), TAG, "reset deassert");
  ESP_RETURN_ON_ERROR(write_reg(REG_CLOCK_MANAGER1, 0x10), TAG, "clock manager1 a");
  vTaskDelay(pdMS_TO_TICKS(1));
  ESP_RETURN_ON_ERROR(write_reg(REG_CLOCK_MANAGER1, 0x00), TAG, "clock manager1 b");
  ESP_RETURN_ON_ERROR(write_reg(REG_CLOCK_MANAGER1, 0x0f), TAG, "clock manager1 slave mode");
  ESP_RETURN_ON_ERROR(write_reg(REG_CLOCK_MANAGER2, 0x01), TAG, "clock manager2");
  // 4.096 MHz MCLK / 16 kHz / 8 = 32 (vendor's own comment for this constant).
  ESP_RETURN_ON_ERROR(write_reg(REG_CLOCK_MANAGER3, 0x20), TAG, "clock manager3");
  ESP_RETURN_ON_ERROR(write_reg(REG_SERIAL_DATA_PORT, 0x0c), TAG,
                       "16-bit i2s format");
  ESP_RETURN_ON_ERROR(write_reg(REG_ADC_CONTROL2, 0x18), TAG,
                       "adc soft ramp + high pass filter");
  ESP_RETURN_ON_ERROR(write_reg(0x14, 0xA0), TAG, "ALCLVL=-1.5db");  // ADC_CONTROL6
  ESP_RETURN_ON_ERROR(write_reg(REG_SYSTEM_CONTROL6, 0x30), TAG, "power-init time");
  ESP_RETURN_ON_ERROR(write_reg(REG_SYSTEM_CONTROL7, 0x20), TAG, "power-up time");
  ESP_RETURN_ON_ERROR(write_reg(REG_ADC_CONTROL10, 0x04), TAG, "hpf slow coeff");
  ESP_RETURN_ON_ERROR(write_reg(REG_ADC_CONTROL11, 0x04), TAG, "hpf fast coeff");
  ESP_RETURN_ON_ERROR(write_reg(REG_ADC_CONTROL1, 0x32), TAG,
                       "LIN2/RIN2, PGA=+18db");
  ESP_RETURN_ON_ERROR(write_reg(REG_SYSTEM_CONTROL1, 0x00), TAG, "power on");
  ESP_RETURN_ON_ERROR(write_reg(REG_RESET, 0x80), TAG, "ic start");

  uint8_t pga_gain = 0xc0 | (uint8_t)((20.5 + 6.5) / 1.5);
  ESP_RETURN_ON_ERROR(write_reg(REG_ADC_CONTROL4, pga_gain), TAG, "alc on");
  ESP_RETURN_ON_ERROR(write_reg(REG_ADCVOLUMEL, 0x00), TAG, "adc volume 0db");

  return ESP_OK;
}
