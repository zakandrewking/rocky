// Shared I2C bus: the AW9523B GPIO expander (0x58) and the ES8218 mic codec
// (0x10) are both on this one bus, per Makeblock's GPL-3.0 CyberPi-Library-
// for-Arduino (facts only - address/pin numbers, see aw9523b.h/es8218.h).
#pragma once

#include "driver/i2c_master.h"
#include "esp_err.h"

#define CYBERPI_I2C_SDA_GPIO 19
#define CYBERPI_I2C_SCL_GPIO 18

esp_err_t cyberpi_i2c_bus_init(void);
i2c_master_bus_handle_t cyberpi_i2c_bus(void);
