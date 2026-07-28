# Generated for a project without a default CMakeLists.txt, then hand-edited
# to declare the components main.c now uses (Wi-Fi + HTTP OTA) explicitly
# rather than relying on implicit resolution.

FILE(GLOB_RECURSE app_sources ${CMAKE_SOURCE_DIR}/src/*.*)

idf_component_register(
    SRCS ${app_sources}
    PRIV_REQUIRES nvs_flash esp_wifi esp_event esp_netif esp_http_server app_update
)
