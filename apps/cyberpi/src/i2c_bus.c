#include "i2c_bus.h"

static i2c_master_bus_handle_t s_bus;

esp_err_t cyberpi_i2c_bus_init(void) {
  if (s_bus != NULL) {
    return ESP_OK;  // already initialized
  }
  i2c_master_bus_config_t bus_config = {
      .i2c_port = -1,
      .sda_io_num = CYBERPI_I2C_SDA_GPIO,
      .scl_io_num = CYBERPI_I2C_SCL_GPIO,
      .clk_source = I2C_CLK_SRC_DEFAULT,
      .glitch_ignore_cnt = 7,
  };
  return i2c_new_master_bus(&bus_config, &s_bus);
}

i2c_master_bus_handle_t cyberpi_i2c_bus(void) { return s_bus; }
