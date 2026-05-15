/*
 * ESP32 WebSocket Client for Smart Home
 * 
 * Connects to FastAPI server via WebSocket and receives commands.
 * Controls GPIO relays based on device state commands.
 * 
 * Dependencies:
 * - WebSocketsClient library by Links2004 (install via Arduino IDE)
 * - ArduinoJson library v6+ (install via Arduino IDE)
 */

#include <WiFi.h>
#include <WebSocketsClient.h>
#include <ArduinoJson.h>

// ============ CONFIGURATION ============
const char* WIFI_SSID = "YOUR_WIFI_SSID";
const char* WIFI_PASS = "YOUR_WIFI_PASSWORD";

// PC running FastAPI server
const char* SERVER_HOST = "10.177.241.10";
const uint16_t SERVER_PORT = 5000;
const char* SERVER_PATH = "/ws/esp32";

// GPIO pin mapping
const int GPIO_LAMP = 4;
const int GPIO_FAN = 5;
const int GPIO_LAMP_BED1 = 12;
const int GPIO_LAMP_BED2 = 14;

// ============ GLOBALS ============
WebSocketsClient webSocket;

struct Device {
  const char* id;
  const char* name;
  int gpio;
  bool isOn;
};

Device devices[] = {
  {"lamp-1", "Phong khach", GPIO_LAMP, false},
  {"fan-1", "Quat", GPIO_FAN, false},
  {"lamp-bed1", "Phong ngu 1", GPIO_LAMP_BED1, false},
  {"lamp-bed2", "Phong ngu 2", GPIO_LAMP_BED2, false},
};

const size_t DEVICE_COUNT = sizeof(devices) / sizeof(Device);

// ============ GPIO CONTROL ============
void setupGPIO() {
  pinMode(GPIO_LAMP, OUTPUT);
  pinMode(GPIO_FAN, OUTPUT);
  pinMode(GPIO_LAMP_BED1, OUTPUT);
  pinMode(GPIO_LAMP_BED2, OUTPUT);
  digitalWrite(GPIO_LAMP, LOW);
  digitalWrite(GPIO_FAN, LOW);
  digitalWrite(GPIO_LAMP_BED1, LOW);
  digitalWrite(GPIO_LAMP_BED2, LOW);
  
  Serial.println("GPIO initialized");
}

Device* findDeviceById(const String& id) {
  for (size_t i = 0; i < DEVICE_COUNT; i++) {
    if (id == devices[i].id) {
      return &devices[i];
    }
  }
  return nullptr;
}

void setDeviceState(const String& id, bool isOn) {
  Device* device = findDeviceById(id);
  if (!device) {
    Serial.printf("Device not found: %s\n", id.c_str());
    return;
  }

  digitalWrite(device->gpio, isOn ? HIGH : LOW);
  device->isOn = isOn;
  
  Serial.printf("[GPIO] %s -> %s\n", device->name, isOn ? "ON" : "OFF");
}

// ============ WEBSOCKET HANDLERS ============
void handleWebSocketMessage(uint8_t* payload, size_t length) {
  StaticJsonDocument<256> doc;
  DeserializationError error = deserializeJson(doc, payload, length);

  if (error) {
    Serial.printf("[JSON] Parse error: %s\n", error.c_str());
    return;
  }

  const char* action = doc["action"];
  if (!action) {
    Serial.println("[JSON] Missing action field");
    return;
  }

  if (strcmp(action, "set_state") == 0) {
    const char* deviceId = doc["deviceId"];
    bool isOn = doc["isOn"] | false;
    
    if (!deviceId) {
      Serial.println("[JSON] Missing deviceId");
      return;
    }
    
    setDeviceState(String(deviceId), isOn);
  } else {
    Serial.printf("[WebSocket] Unknown action: %s\n", action);
  }
}

void webSocketEvent(WStype_t type, uint8_t* payload, size_t length) {
  switch (type) {
    case WStype_DISCONNECTED:
      Serial.println("[WebSocket] Disconnected");
      break;

    case WStype_CONNECTED:
      Serial.printf("[WebSocket] Connected to %s:%u\n", SERVER_HOST, SERVER_PORT);
      Serial.println("[WebSocket] Waiting for commands...");
      break;

    case WStype_TEXT:
      Serial.printf("[WebSocket] RX: %s\n", payload);
      handleWebSocketMessage(payload, length);
      break;

    case WStype_ERROR:
      Serial.printf("[WebSocket] Error: %s\n", payload);
      break;

    default:
      break;
  }
}

// ============ WIFI SETUP ============
void setupWiFi() {
  Serial.print("[WiFi] Connecting to ");
  Serial.println(WIFI_SSID);

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);

  int attempts = 0;
  while (WiFi.status() != WL_CONNECTED && attempts < 20) {
    delay(500);
    Serial.print(".");
    attempts++;
  }

  Serial.println();

  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[WiFi] Failed to connect!");
    return;
  }

  Serial.println("[WiFi] Connected!");
  Serial.print("[WiFi] IP: ");
  Serial.println(WiFi.localIP());
}

// ============ WEBSOCKET SETUP ============
void setupWebSocket() {
  webSocket.begin(SERVER_HOST, SERVER_PORT, SERVER_PATH);
  webSocket.onEvent(webSocketEvent);
  webSocket.setReconnectInterval(5000);
  webSocket.enableHeartbeat(15000, 3000, 2);
  
  Serial.printf("[WebSocket] Connecting to ws://%s:%u%s\n", SERVER_HOST, SERVER_PORT, SERVER_PATH);
}

// ============ SETUP & LOOP ============
void setup() {
  Serial.begin(115200);
  delay(1000);

  Serial.println("\n\n=== Smart Home ESP32 Client ===");
  
  setupGPIO();
  setupWiFi();
  setupWebSocket();
}

void loop() {
  webSocket.loop();
  delay(100);
}
