# ESP32 WebSocket Client Sample (Arduino)

This is an ESP32 sketch that acts as a **WebSocket client** connected to the FastAPI server. The server forwards commands via WebSocket.

## Architecture
```
[Flutter App] → [FastAPI Server (PC)] → [ESP32 WebSocket Client]
                                      ↑
                                      └── Commands over WebSocket
```

## Dependencies
- Arduino core for ESP32
- ArduinoJson library (v6+)
- WebSocketsClient library (Links2004)

## Sketch

```cpp
#include <WiFi.h>
#include <WebSocketsClient.h>
#include <ArduinoJson.h>

const char* WIFI_SSID = "YOUR_WIFI_SSID";
const char* WIFI_PASS = "YOUR_WIFI_PASSWORD";
const char* SERVER_HOST = "192.168.1.100";  // PC running FastAPI server
const uint16_t SERVER_PORT = 5000;           // FastAPI server port

WebSocketsClient webSocket;

struct Device {
  const char* id;
  const char* name;
  const char* type;
  bool isOn;
};

Device devices[] = {
  {"lamp-1", "Living Room Lamp", "light"},
  {"fan-1", "Bedroom Fan", "fan"},
};

const size_t deviceCount = sizeof(devices) / sizeof(Device);

const int GPIO_LAMP = 4;    // GPIO 4 for lamp relay
const int GPIO_FAN = 5;     // GPIO 5 for fan relay

void setupGPIO() {
  pinMode(GPIO_LAMP, OUTPUT);
  pinMode(GPIO_FAN, OUTPUT);
  digitalWrite(GPIO_LAMP, LOW);
  digitalWrite(GPIO_FAN, LOW);
}

void setDeviceState(const String& id, bool isOn) {
  if (id == "lamp-1") {
    digitalWrite(GPIO_LAMP, isOn ? HIGH : LOW);
    devices[0].isOn = isOn;
    Serial.printf("Lamp toggled to %s\n", isOn ? "ON" : "OFF");
  } else if (id == "fan-1") {
    digitalWrite(GPIO_FAN, isOn ? HIGH : LOW);
    devices[1].isOn = isOn;
    Serial.printf("Fan toggled to %s\n", isOn ? "ON" : "OFF");
  }
}

void handleWebSocketMessage(uint8_t* payload, size_t length) {
  StaticJsonDocument<256> doc;
  DeserializationError error = deserializeJson(doc, payload, length);
  
  if (error) {
    Serial.printf("JSON parse error: %s\n", error.c_str());
    return;
  }

  const char* action = doc["action"];
  if (!action) {
    return;
  }

  if (strcmp(action, "set_state") == 0) {
    const char* deviceId = doc["deviceId"];
    bool isOn = doc["isOn"] | false;
    if (deviceId) {
      setDeviceState(String(deviceId), isOn);
    }
  }
}

void webSocketEvent(WStype_t type, uint8_t* payload, size_t length) {
  switch (type) {
    case WStype_DISCONNECTED:
      Serial.println("[WebSocket] Disconnected from server");
      break;
    
    case WStype_CONNECTED:
      Serial.printf("[WebSocket] Connected to %s:%u\n", SERVER_HOST, SERVER_PORT);
      break;
    
    case WStype_TEXT:
      Serial.printf("[WebSocket] Received: %s\n", payload);
      handleWebSocketMessage(payload, length);
      break;

    case WStype_ERROR:
      Serial.printf("[WebSocket] Error: %s\n", payload);
      break;

    default:
      break;
  }
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  setupGPIO();

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);

  Serial.print("Connecting to WiFi");
  int attempts = 0;
  while (WiFi.status() != WL_CONNECTED && attempts < 20) {
    delay(500);
    Serial.print(".");
    attempts++;
  }

  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("\nFailed to connect to WiFi");
    return;
  }

  Serial.println();
  Serial.print("IP address: ");
  Serial.println(WiFi.localIP());

  webSocket.begin(SERVER_HOST, SERVER_PORT, "/ws/esp32");
  webSocket.onEvent(webSocketEvent);
  webSocket.setReconnectInterval(5000);
}

void loop() {
  webSocket.loop();
  delay(100);
}
```

## Setup Steps
1. Install WebSocketsClient library via Arduino IDE: Sketch → Include Library → Manage Libraries, search for "websockets" by Links2004.
2. Update `WIFI_SSID`, `WIFI_PASS`, `SERVER_HOST`, `SERVER_PORT`.
3. Adjust GPIO pins for your relays.
4. Upload to ESP32.
5. Open Serial Monitor to verify WebSocket connection.

## GPIO Mapping
- GPIO 4: Lamp relay (device "lamp-1")
- GPIO 5: Fan relay (device "fan-1")

Adjust as needed for your setup.

## Notes
- ESP32 connects to server on startup and maintains WebSocket connection.
- All commands come from the FastAPI server over WebSocket.
- Device state is updated locally when GPIO is toggled.
- If the connection drops, ESP32 will auto-reconnect every 5 seconds.
