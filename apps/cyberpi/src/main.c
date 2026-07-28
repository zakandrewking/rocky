// Stage 2 toolchain bring-up: proves the PlatformIO/ESP-IDF build+flash path
// works on the real board before anything touches audio or peripherals.
// Deliberately does nothing with GPIO or I2C - the CyberPi's front LEDs and
// buttons are behind I2C devices (AW9523B expander, a separate LED driver at
// 0x5B), not raw pins, so a print loop is the safe trivial test here.

#include <stdio.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

void app_main(void) {
  int tick = 0;
  while (1) {
    printf("Rocky native firmware alive - tick %d\n", tick++);
    vTaskDelay(pdMS_TO_TICKS(1000));
  }
}
