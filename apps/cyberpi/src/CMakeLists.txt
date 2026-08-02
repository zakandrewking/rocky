# Generated for a project without a default CMakeLists.txt, then hand-edited
# to declare the components main.c now uses (Wi-Fi + HTTP OTA, AW9523B/ST7789
# display over I2C+SPI, ES8218E mic over I2C+I2S, speaker over the built-in
# DAC) explicitly rather than relying on implicit resolution.

FILE(GLOB_RECURSE app_sources ${CMAKE_SOURCE_DIR}/src/*.*)

idf_component_register(
    SRCS ${app_sources}
    PRIV_REQUIRES nvs_flash esp_wifi esp_event esp_netif esp_http_server app_update esp_driver_i2c esp_driver_spi esp_driver_i2s esp_driver_dac
)
