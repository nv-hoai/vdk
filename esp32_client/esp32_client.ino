#include <WiFi.h>
#include <WebSocketsClient.h>
#include <ArduinoJson.h>
#include <ESP32Servo.h>

// ============ CONFIGURATION ============
const char* WIFI_SSID = "nt";
const char* WIFI_PASS = "zxcvbnm@";

const char* SERVER_HOST = "10.155.121.10";
const uint16_t SERVER_PORT = 5000;
const char* SERVER_PATH = "/ws/esp32";

// ============ KHAI BÁO CHÂN ============
const int GPIO_FAN       = 13;
const int GPIO_LAMP      = 21;
const int GPIO_LAMP_BED1 = 25;
const int GPIO_LAMP_BED2 = 27;

// ============ ĐỊNH NGHĨA THIẾT BỊ ============
struct Device {
    const char* id;
    const char* name;
    int         gpio;
    bool        isOn;
    bool        isServo;
};

Device devices[] = {
    {"lamp-1",    "Phong khach", GPIO_LAMP,       false, false},
    {"fan-1",     "Quat",        GPIO_FAN,         false, true },
    {"lamp-bed1", "Phong ngu 1", GPIO_LAMP_BED1,  false, false},
    {"lamp-bed2", "Phong ngu 2", GPIO_LAMP_BED2,  false, false},
};

const size_t DEVICE_COUNT = sizeof(devices) / sizeof(Device);

// ============ SERVO / QUẠT ============
Servo fanServo;
bool  fanRunning   = false;
int   fanAngle     = 0;
bool  fanGoingUp   = true;   // ✅ fix: global thay vì static local
const int FAN_STEP     = 3;
const int FAN_INTERVAL = 15;
unsigned long lastFanUpdate = 0;

void updateFan() {
    if (!fanRunning) return;
    if (millis() - lastFanUpdate < (unsigned long)FAN_INTERVAL) return;
    lastFanUpdate = millis();

    if (fanGoingUp) {
        fanAngle += FAN_STEP;
        if (fanAngle >= 180) { fanAngle = 180; fanGoingUp = false; }
    } else {
        fanAngle -= FAN_STEP;
        if (fanAngle <= 0)   { fanAngle = 0;   fanGoingUp = true;  }
    }
    fanServo.write(fanAngle);
}

void setFan(bool isOn) {
    fanRunning  = isOn;
    fanGoingUp  = true;   // reset hướng mỗi lần bật lại
    if (!isOn) {
        fanServo.write(0);
        fanAngle = 0;
        Serial.println("[FAN] Dung quay, ve 0 do");
    } else {
        Serial.println("[FAN] Bat dau quay lien tuc 0<->180");
    }
}

// ============ WEBSOCKET ============
WebSocketsClient webSocket;

void printCommand(const char* action, const char* deviceId, bool isOn) {
    Serial.println();
    Serial.println(">>>>>>>>>> COMMAND RECEIVED <<<<<<<<<<");
    Serial.print  ("  Action   : "); Serial.println(action);
    Serial.print  ("  Device ID: "); Serial.println(deviceId);
    Serial.print  ("  State    : "); Serial.println(isOn ? "ON" : "OFF");
    Serial.println("<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<");
}

void setupGPIO() {
    int lampPins[] = {GPIO_LAMP, GPIO_LAMP_BED1, GPIO_LAMP_BED2};
    for (int pin : lampPins) {
        pinMode(pin, OUTPUT);
        digitalWrite(pin, LOW);
    }
    fanServo.attach(GPIO_FAN);
    fanServo.write(0);
    Serial.println("[INIT] GPIO & Servo initialized");
}

Device* findDeviceById(const String& id) {
    for (size_t i = 0; i < DEVICE_COUNT; i++) {
        if (id == devices[i].id) return &devices[i];
    }
    return nullptr;
}

void setDeviceState(const String& id, bool isOn) {
    Device* device = findDeviceById(id);
    if (!device) {
        Serial.printf("[ERROR] Device not found: %s\n", id.c_str());
        return;
    }
    device->isOn = isOn;
    if (device->isServo) {
        setFan(isOn);
    } else {
        digitalWrite(device->gpio, isOn ? HIGH : LOW);
        Serial.printf("[GPIO] %s -> %s (GPIO %d)\n",
                      device->name, isOn ? "ON" : "OFF", device->gpio);
    }
}

void sendAck(const String& deviceId, bool isOn) {
    StaticJsonDocument<128> ack;
    ack["type"]     = "ack";
    ack["deviceId"] = deviceId;
    ack["isOn"]     = isOn;
    String output;
    serializeJson(ack, output);
    webSocket.sendTXT(output);
    Serial.printf("[WS TX] ACK -> %s\n", output.c_str());
}

void sendAllStates() {
    StaticJsonDocument<512> doc;
    doc["type"] = "init_state";
    JsonArray arr = doc.createNestedArray("devices");
    for (size_t i = 0; i < DEVICE_COUNT; i++) {
        JsonObject d = arr.createNestedObject();
        d["id"]   = devices[i].id;
        d["isOn"] = devices[i].isOn;
    }
    String output;
    serializeJson(doc, output);
    webSocket.sendTXT(output);
    Serial.printf("[WS TX] init_state -> %s\n", output.c_str());
}

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
        printCommand(action, deviceId, isOn);
        setDeviceState(String(deviceId), isOn);
        sendAck(String(deviceId), isOn);
    } else if (strcmp(action, "get_state") == 0) {
        Serial.println("[CMD] get_state -> Sending all device states");
        sendAllStates();
    } else {
        Serial.printf("[CMD] Unknown action: %s\n", action);
    }
}

void webSocketEvent(WStype_t type, uint8_t* payload, size_t length) {
    switch (type) {
        case WStype_DISCONNECTED:
            Serial.println("[WS] Disconnected from server");
            break;
        case WStype_CONNECTED:
            Serial.printf("[WS] Connected to ws://%s:%u%s\n",
                          SERVER_HOST, SERVER_PORT, SERVER_PATH);
            sendAllStates();
            break;
        case WStype_TEXT:
            Serial.println();
            Serial.printf("[WS RX] Raw: %s\n", payload);
            handleWebSocketMessage(payload, length);
            break;
        case WStype_ERROR:
            Serial.printf("[WS] Error: %s\n", payload);
            break;
        default:
            break;
    }
}

// ============ WIFI ============
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
        Serial.println("[WiFi] Failed! Restarting in 3s...");
        delay(3000);
        ESP.restart();   // ✅ fix: restart thay vì return
    }
    Serial.println("[WiFi] Connected!");
    Serial.print("[WiFi] IP: ");
    Serial.println(WiFi.localIP());
}

void setupWebSocket() {
    webSocket.begin(SERVER_HOST, SERVER_PORT, SERVER_PATH);
    webSocket.onEvent(webSocketEvent);
    webSocket.setReconnectInterval(5000);
    webSocket.enableHeartbeat(15000, 3000, 2);
    Serial.printf("[WS] Connecting to ws://%s:%u%s\n",
                  SERVER_HOST, SERVER_PORT, SERVER_PATH);
}

// ============ SETUP & LOOP ============
void setup() {
    Serial.begin(115200);
    delay(1000);
    Serial.println("\n=== Smart Home ESP32 ===");
    setupGPIO();
    setupWiFi();
    setupWebSocket();
}

void loop() {
    webSocket.loop();
    updateFan();
}