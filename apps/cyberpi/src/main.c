// Stage 2 bring-up: display first (fastest visible confirmation of custom
// firmware), then audio (PLAN.md step 5 - ES8218E mic + built-in-DAC
// speaker, neither needs the network), then Wi-Fi, then a minimal HTTP OTA
// receiver (PLAN.md step 3) that writes a POSTed binary to the inactive OTA
// slot and reboots into it.

#include <stdlib.h>
#include <string.h>
#include <sys/param.h>

#include "aw9523b.h"
#include "es8218e.h"
#include "esp_event.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_ota_ops.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/task.h"
#include "mic_i2s.h"
#include "nvs_flash.h"
#include "speaker_dac.h"
#include "st7789.h"

#include "wifi_credentials.h"

static const char *TAG = "rocky";

static EventGroupHandle_t wifi_event_group;
#define WIFI_CONNECTED_BIT BIT0
static esp_ip4_addr_t last_got_ip;

static void wifi_event_handler(void *arg, esp_event_base_t event_base,
                                int32_t event_id, void *event_data) {
  if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_START) {
    esp_wifi_connect();
  } else if (event_base == WIFI_EVENT &&
             event_id == WIFI_EVENT_STA_DISCONNECTED) {
    ESP_LOGW(TAG, "Wi-Fi disconnected, retrying");
    xEventGroupClearBits(wifi_event_group, WIFI_CONNECTED_BIT);
    esp_wifi_connect();
  } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
    ip_event_got_ip_t *event = (ip_event_got_ip_t *)event_data;
    last_got_ip = event->ip_info.ip;
    ESP_LOGI(TAG, "Got IP: " IPSTR, IP2STR(&last_got_ip));
    xEventGroupSetBits(wifi_event_group, WIFI_CONNECTED_BIT);
  }
}

static void wifi_init_sta(void) {
  wifi_event_group = xEventGroupCreate();

  ESP_ERROR_CHECK(esp_netif_init());
  ESP_ERROR_CHECK(esp_event_loop_create_default());
  esp_netif_create_default_wifi_sta();

  wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
  ESP_ERROR_CHECK(esp_wifi_init(&cfg));

  ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                              &wifi_event_handler, NULL));
  ESP_ERROR_CHECK(esp_event_handler_register(
      IP_EVENT, IP_EVENT_STA_GOT_IP, &wifi_event_handler, NULL));

  wifi_config_t wifi_config = {
      .sta =
          {
              .ssid = CYBERPI_WIFI_SSID,
              .password = CYBERPI_WIFI_PASSWORD,
          },
  };
  ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
  ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wifi_config));
  ESP_ERROR_CHECK(esp_wifi_start());

  ESP_LOGI(TAG, "connecting to Wi-Fi SSID '%s'", CYBERPI_WIFI_SSID);
}

// Writes the request body to the inactive OTA partition and reboots into it
// on success. No auth: this is a LAN-only bring-up tool, not a shipped
// feature - see TODOS.md before this ever leaves a trusted network.
static esp_err_t ota_post_handler(httpd_req_t *req) {
  const esp_partition_t *update_partition = esp_ota_get_next_update_partition(NULL);
  if (update_partition == NULL) {
    httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR,
                         "no OTA partition available");
    return ESP_FAIL;
  }
  ESP_LOGI(TAG, "OTA update starting, target partition '%s' at 0x%lx",
           update_partition->label, (unsigned long)update_partition->address);

  esp_ota_handle_t ota_handle = 0;
  esp_err_t err = esp_ota_begin(update_partition, OTA_SIZE_UNKNOWN, &ota_handle);
  if (err != ESP_OK) {
    ESP_LOGE(TAG, "esp_ota_begin failed: %s", esp_err_to_name(err));
    httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "esp_ota_begin failed");
    return ESP_FAIL;
  }

  char buf[1024];
  int remaining = req->content_len;
  int total_written = 0;
  while (remaining > 0) {
    int received = httpd_req_recv(req, buf, MIN(remaining, (int)sizeof(buf)));
    if (received <= 0) {
      if (received == HTTPD_SOCK_ERR_TIMEOUT) {
        continue;
      }
      ESP_LOGE(TAG, "OTA body read failed");
      esp_ota_abort(ota_handle);
      httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "read failed");
      return ESP_FAIL;
    }
    err = esp_ota_write(ota_handle, buf, received);
    if (err != ESP_OK) {
      ESP_LOGE(TAG, "esp_ota_write failed: %s", esp_err_to_name(err));
      esp_ota_abort(ota_handle);
      httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "esp_ota_write failed");
      return ESP_FAIL;
    }
    total_written += received;
    remaining -= received;
  }

  err = esp_ota_end(ota_handle);
  if (err != ESP_OK) {
    ESP_LOGE(TAG, "esp_ota_end failed: %s", esp_err_to_name(err));
    httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR,
                         err == ESP_ERR_OTA_VALIDATE_FAILED
                             ? "image validation failed"
                             : "esp_ota_end failed");
    return ESP_FAIL;
  }

  err = esp_ota_set_boot_partition(update_partition);
  if (err != ESP_OK) {
    ESP_LOGE(TAG, "esp_ota_set_boot_partition failed: %s", esp_err_to_name(err));
    httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR,
                         "esp_ota_set_boot_partition failed");
    return ESP_FAIL;
  }

  ESP_LOGI(TAG, "OTA update wrote %d bytes, rebooting into '%s'", total_written,
           update_partition->label);
  httpd_resp_sendstr(req, "OK, rebooting\n");

  vTaskDelay(pdMS_TO_TICKS(500));  // let the response flush before reset
  esp_restart();
  return ESP_OK;  // unreachable
}

// Logs an averaged loudness reading every ~500ms, mirroring Stage 1's own
// step04_loudness at the native layer: proof that real PCM is moving,
// checkable by eye over serial (clap or talk near the mic and watch the
// number jump) without needing the network or a recording round trip.
static void mic_loudness_task(void *arg) {
  int16_t frame[MIC_I2S_FRAME_SAMPLES];
  int64_t sum_abs = 0;
  int frames_since_log = 0;

  while (1) {
    esp_err_t err = mic_i2s_read(frame, MIC_I2S_FRAME_SAMPLES, pdMS_TO_TICKS(100));
    if (err != ESP_OK) {
      ESP_LOGW(TAG, "mic read failed: %s", esp_err_to_name(err));
      continue;
    }

    int32_t frame_sum = 0;
    for (int i = 0; i < MIC_I2S_FRAME_SAMPLES; i++) {
      frame_sum += abs(frame[i]);
    }
    sum_abs += frame_sum;
    frames_since_log++;

    if (frames_since_log >= 50) {  // 50 * 10ms frames = ~500ms
      ESP_LOGI(TAG, "mic loudness: avg abs sample %lld",
               sum_abs / (frames_since_log * MIC_I2S_FRAME_SAMPLES));
      sum_abs = 0;
      frames_since_log = 0;
    }
  }
}

static const httpd_uri_t ota_uri = {
    .uri = "/ota",
    .method = HTTP_POST,
    .handler = ota_post_handler,
};

static void start_ota_server(void) {
  httpd_config_t config = HTTPD_DEFAULT_CONFIG();
  config.stack_size = 8192;

  httpd_handle_t server = NULL;
  ESP_ERROR_CHECK(httpd_start(&server, &config));
  ESP_ERROR_CHECK(httpd_register_uri_handler(server, &ota_uri));
  ESP_LOGI(TAG, "OTA HTTP server listening on :%d/ota", config.server_port);
}

void app_main(void) {
  esp_err_t nvs_err = nvs_flash_init();
  if (nvs_err == ESP_ERR_NVS_NO_FREE_PAGES ||
      nvs_err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
    ESP_ERROR_CHECK(nvs_flash_erase());
    nvs_err = nvs_flash_init();
  }
  ESP_ERROR_CHECK(nvs_err);

  ESP_ERROR_CHECK(aw9523b_init());
  ESP_ERROR_CHECK(st7789_init());
  ESP_ERROR_CHECK(st7789_fill(0x07e0));  // green: first pixels on screen
  ESP_LOGI(TAG, "display initialized and filled");

  ESP_ERROR_CHECK(es8218e_init());
  ESP_ERROR_CHECK(mic_i2s_init());
  ESP_ERROR_CHECK(speaker_dac_init());
  ESP_LOGI(TAG, "audio initialized, playing startup tone");
  ESP_ERROR_CHECK(speaker_dac_play_tone(440, 200));
  xTaskCreate(mic_loudness_task, "mic_loudness", 4096, NULL, 5, NULL);

  wifi_init_sta();

  ESP_LOGI(TAG, "waiting for Wi-Fi connection...");
  xEventGroupWaitBits(wifi_event_group, WIFI_CONNECTED_BIT, pdFALSE, pdTRUE,
                       portMAX_DELAY);

  start_ota_server();

  int tick = 0;
  while (1) {
    ESP_LOGI(TAG, "alive - tick %d - ip " IPSTR, tick++, IP2STR(&last_got_ip));
    vTaskDelay(pdMS_TO_TICKS(5000));
  }
}
