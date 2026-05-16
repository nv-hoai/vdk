#include <WiFi.h>
#include <WebSocketsClient.h>
#include <ArduinoJson.h>
#include <ESP32Servo.h>
#include <DHT.h>
#include <SPI.h>
#include <MFRC522.h>

// ============================================================
//  CONFIGURATION
// ============================================================
const char* WIFI_SSID   = "nt";
const char* WIFI_PASS   = "zxcvbnm@";
const char* SERVER_HOST = "10.155.121.10";
const uint16_t SERVER_PORT = 5000;
const char* SERVER_PATH = "/ws/esp32";

// ============================================================
//  KHAI BÁO CHÂN
// ============================================================
// --- Thiết bị điều khiển (file 1) ---
const int GPIO_LAMP      = 21;
const int GPIO_LAMP_BED1 = 25;
const int GPIO_LAMP_BED2 = 27;
const int GPIO_FAN       = 13;   // Servo quạt (sweep 0<->180)

// --- Cảm biến (file 2) ---
#define PIR_PIN    4
#define LIGHT_PIN  34
#define DHT_PIN    14
#define SERVO_DOOR_PIN 26   // ⚠️ Đổi sang GPIO 26 để tránh xung đột GPIO 13 (quạt)
#define TRIG_PIN   16
#define ECHO_PIN   17
#define GAS_PIN    35

// --- RFID RC522 ---
#define SS_PIN   5
#define RST_PIN  22
#define SCK_PIN  18
#define MISO_PIN 19
#define MOSI_PIN 23

// ============================================================
//  ĐỊNH NGHĨA THIẾT BỊ (WebSocket)
// ============================================================
struct Device {
    const char* id;
    const char* name;
    int         gpio;
    bool        isOn;
    bool        isServo;   // true = servo quạt, false = GPIO thường
};

Device devices[] = {
    {"lamp-1",    "Phong khach", GPIO_LAMP,       false, false},
    {"fan-1",     "Quat",        GPIO_FAN,         false, true },
    {"lamp-bed1", "Phong ngu 1", GPIO_LAMP_BED1,  false, false},
    {"lamp-bed2", "Phong ngu 2", GPIO_LAMP_BED2,  false, false},
};
const size_t DEVICE_COUNT = sizeof(devices) / sizeof(Device);

// ============================================================
//  SERVO QUẠT (sweep liên tục)
// ============================================================
Servo fanServo;
bool  fanRunning   = false;
int   fanAngle     = 0;
bool  fanGoingUp   = true;
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
    fanRunning = isOn;
    fanGoingUp = true;
    if (!isOn) {
        fanServo.write(0);
        fanAngle = 0;
        Serial.println("[FAN] Dung quay, ve 0 do");
    } else {
        Serial.println("[FAN] Bat dau quay lien tuc 0<->180");
    }
}

// ============================================================
//  SERVO CỬA (RFID mở/đóng)
// ============================================================
Servo doorServo;

void servoSetAngle(int angle) {
    if (angle < 0)   angle = 0;
    if (angle > 180) angle = 180;
    doorServo.write(angle);
    Serial.print("[DOOR SERVO] Goc: "); Serial.print(angle); Serial.println(" do");
}

// ============================================================
//  RFID RC522
// ============================================================
MFRC522 mfrc522(SS_PIN, RST_PIN);

const String authorizedUIDs[] = {
    "96 59 E3 00",   // Đổi thành UID thẻ thực của bạn
};
const int authorizedCount = 1;
bool rfidTestMode = false;

String getCardUID() {
    String uid = "";
    for (byte i = 0; i < mfrc522.uid.size; i++) {
        uid.concat(mfrc522.uid.uidByte[i] < 0x10 ? " 0" : " ");
        uid.concat(String(mfrc522.uid.uidByte[i], HEX));
    }
    uid.toUpperCase();
    return uid.substring(1);
}

bool isAuthorized(String uid) {
    for (int i = 0; i < authorizedCount; i++)
        if (uid == authorizedUIDs[i]) return true;
    return false;
}

void handleRFID() {
    if (!mfrc522.PICC_IsNewCardPresent()) return;
    if (!mfrc522.PICC_ReadCardSerial())   return;

    String uid = getCardUID();
    Serial.println("\n---------- RFID ----------");
    Serial.print("[RFID] UID: "); Serial.println(uid);

    if (rfidTestMode) {
        Serial.println("[RFID TEST] Che do test - khong kiem tra quyen");
    } else {
        if (isAuthorized(uid)) {
            Serial.println("[RFID] DUOC PHEP -> Mo cua");
            servoSetAngle(90);
            delay(3000);
            servoSetAngle(0);
            Serial.println("[RFID] Cua da dong lai");
        } else {
            Serial.println("[RFID] TU CHOI TRUY CAP");
        }
    }
    Serial.println("--------------------------");
    mfrc522.PICC_HaltA();
    mfrc522.PCD_StopCrypto1();
}

// ============================================================
//  CẢM BIẾN
// ============================================================
DHT dht(DHT_PIN, DHT11);
unsigned long lastSensorRead = 0;
const unsigned long SENSOR_INTERVAL = 2000;

float readDistanceCM() {
    digitalWrite(TRIG_PIN, LOW);
    delayMicroseconds(2);
    digitalWrite(TRIG_PIN, HIGH);
    delayMicroseconds(10);
    digitalWrite(TRIG_PIN, LOW);
    long duration = pulseIn(ECHO_PIN, HIGH, 30000);
    if (duration == 0) return -1;
    return duration * 0.034f / 2.0f;
}

// Đọc cảm biến và gửi lên server qua WebSocket
void readAndSendSensors();   // forward declaration

void readAllSensors() {
    int   pirValue   = digitalRead(PIR_PIN);
    int   lightValue = analogRead(LIGHT_PIN);
    int   gasValue   = analogRead(GAS_PIN);
    float temp       = dht.readTemperature();
    float hum        = dht.readHumidity();
    float dist       = readDistanceCM();

    Serial.println("\n========== SENSOR DATA ==========");
    Serial.print("PIR: ");       Serial.println(pirValue);
    Serial.print("Light: ");     Serial.println(lightValue);
    Serial.print("Gas: ");       Serial.println(gasValue);
    Serial.print("Temp: ");
    isnan(temp) ? Serial.println("ERR") : (Serial.print(temp), Serial.println(" *C"));
    Serial.print("Humidity: ");
    isnan(hum)  ? Serial.println("ERR") : (Serial.print(hum),  Serial.println(" %"));
    Serial.print("Distance: ");
    dist < 0    ? Serial.println("ERR") : (Serial.print(dist), Serial.println(" cm"));
    Serial.println("=================================");

    readAndSendSensors();   // gửi WebSocket
}

// ============================================================
//  WEBSOCKET
// ============================================================
WebSocketsClient webSocket;

void sendAck(const String& deviceId, bool isOn) {
    StaticJsonDocument<128> ack;
    ack["type"]     = "ack";
    ack["deviceId"] = deviceId;
    ack["isOn"]     = isOn;
    String out;
    serializeJson(ack, out);
    webSocket.sendTXT(out);
    Serial.printf("[WS TX] ACK -> %s\n", out.c_str());
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
    String out;
    serializeJson(doc, out);
    webSocket.sendTXT(out);
    Serial.printf("[WS TX] init_state -> %s\n", out.c_str());
}

// Gửi dữ liệu cảm biến lên server
void readAndSendSensors() {
    StaticJsonDocument<256> doc;
    doc["type"]        = "sensor_data";
    doc["pir"]         = digitalRead(PIR_PIN);
    doc["light"]       = analogRead(LIGHT_PIN);
    doc["gas"]         = analogRead(GAS_PIN);
    float t = dht.readTemperature();
    float h = dht.readHumidity();
    float d = readDistanceCM();
    if (!isnan(t)) doc["temperature"] = t;
    if (!isnan(h)) doc["humidity"]    = h;
    if (d >= 0)    doc["distance"]    = d;
    String out;
    serializeJson(doc, out);
    webSocket.sendTXT(out);
    Serial.printf("[WS TX] sensor_data -> %s\n", out.c_str());
}

Device* findDeviceById(const String& id) {
    for (size_t i = 0; i < DEVICE_COUNT; i++)
        if (id == devices[i].id) return &devices[i];
    return nullptr;
}

void setDeviceState(const String& id, bool isOn) {
    Device* dev = findDeviceById(id);
    if (!dev) { Serial.printf("[ERROR] Device not found: %s\n", id.c_str()); return; }
    dev->isOn = isOn;
    if (dev->isServo) {
        setFan(isOn);
    } else {
        digitalWrite(dev->gpio, isOn ? HIGH : LOW);
        Serial.printf("[GPIO] %s -> %s (GPIO %d)\n", dev->name, isOn ? "ON" : "OFF", dev->gpio);
    }
}

void handleWebSocketMessage(uint8_t* payload, size_t length) {
    StaticJsonDocument<256> doc;
    if (deserializeJson(doc, payload, length)) { Serial.println("[JSON] Parse error"); return; }

    const char* action = doc["action"];
    if (!action) { Serial.println("[JSON] Missing action"); return; }

    if (strcmp(action, "set_state") == 0) {
        const char* deviceId = doc["deviceId"];
        bool isOn = doc["isOn"] | false;
        if (!deviceId) { Serial.println("[JSON] Missing deviceId"); return; }
        Serial.printf("[CMD] set_state: %s -> %s\n", deviceId, isOn ? "ON" : "OFF");
        setDeviceState(String(deviceId), isOn);
        sendAck(String(deviceId), isOn);

    } else if (strcmp(action, "get_state") == 0) {
        Serial.println("[CMD] get_state");
        sendAllStates();

    } else if (strcmp(action, "get_sensors") == 0) {
        Serial.println("[CMD] get_sensors");
        readAndSendSensors();

    } else {
        Serial.printf("[CMD] Unknown action: %s\n", action);
    }
}

void webSocketEvent(WStype_t type, uint8_t* payload, size_t length) {
    switch (type) {
        case WStype_DISCONNECTED:
            Serial.println("[WS] Disconnected");
            break;
        case WStype_CONNECTED:
            Serial.printf("[WS] Connected to ws://%s:%u%s\n", SERVER_HOST, SERVER_PORT, SERVER_PATH);
            sendAllStates();
            break;
        case WStype_TEXT:
            Serial.printf("[WS RX] %s\n", payload);
            handleWebSocketMessage(payload, length);
            break;
        case WStype_ERROR:
            Serial.printf("[WS] Error: %s\n", payload);
            break;
        default: break;
    }
}

// ============================================================
//  LỆNH SERIAL (debug / test thủ công)
// ============================================================
void handleSerialCommand() {
    if (!Serial.available()) return;
    String cmd = Serial.readStringUntil('\n');
    cmd.trim();

    if      (cmd == "DOOR_OPEN")      { servoSetAngle(90); }
    else if (cmd == "DOOR_CLOSE")     { servoSetAngle(0); }
    else if (cmd == "FAN_ON")         { setFan(true); }
    else if (cmd == "FAN_OFF")        { setFan(false); }
    else if (cmd == "READ")           { readAllSensors(); }
    else if (cmd == "SEND_STATE")     { sendAllStates(); }
    else if (cmd == "SEND_SENSORS")   { readAndSendSensors(); }
    else if (cmd == "RFID_TEST_ON")   { rfidTestMode = true;  Serial.println("[RFID] Test mode ON"); }
    else if (cmd == "RFID_TEST_OFF")  { rfidTestMode = false; Serial.println("[RFID] Test mode OFF"); }
    else if (cmd == "RFID_STATUS") {
        byte ver = mfrc522.PCD_ReadRegister(MFRC522::VersionReg);
        Serial.printf("[RFID] Firmware: 0x%02X %s\n", ver,
            (ver == 0x91 || ver == 0x92) ? "OK" : "ERROR");
    }
    else if (cmd == "HELP") {
        Serial.println("====== LENH SERIAL ======");
        Serial.println("  DOOR_OPEN/CLOSE    : Mo/dong cua (servo)");
        Serial.println("  FAN_ON/OFF         : Bat/tat quat (servo sweep)");
        Serial.println("  READ               : Doc cam bien & in Serial");
        Serial.println("  SEND_STATE         : Gui trang thai thiet bi len server");
        Serial.println("  SEND_SENSORS       : Gui du lieu cam bien len server");
        Serial.println("  RFID_TEST_ON/OFF   : Bat/tat che do test RFID");
        Serial.println("  RFID_STATUS        : Kiem tra ket noi RC522");
        Serial.println("=========================");
    }
    else {
        Serial.println("Lenh khong hop le. Go HELP.");
    }
}

// ============================================================
//  WIFI
// ============================================================
void setupWiFi() {
    Serial.print("[WiFi] Connecting to "); Serial.println(WIFI_SSID);
    WiFi.mode(WIFI_STA);
    WiFi.begin(WIFI_SSID, WIFI_PASS);
    int attempts = 0;
    while (WiFi.status() != WL_CONNECTED && attempts < 20) {
        delay(500); Serial.print("."); attempts++;
    }
    Serial.println();
    if (WiFi.status() != WL_CONNECTED) {
        Serial.println("[WiFi] Failed! Restarting..."); delay(3000); ESP.restart();
    }
    Serial.print("[WiFi] Connected! IP: "); Serial.println(WiFi.localIP());
}

// ============================================================
//  SETUP & LOOP
// ============================================================
void setup() {
    Serial.begin(115200);
    delay(1000);
    Serial.println("\n=== Smart Home ESP32 - Unified ===");

    // --- GPIO đèn ---
    int lampPins[] = {GPIO_LAMP, GPIO_LAMP_BED1, GPIO_LAMP_BED2};
    for (int pin : lampPins) { pinMode(pin, OUTPUT); digitalWrite(pin, LOW); }

    // --- Cảm biến ---
    pinMode(PIR_PIN,   INPUT);
    pinMode(LIGHT_PIN, INPUT);
    pinMode(GAS_PIN,   INPUT);
    pinMode(TRIG_PIN,  OUTPUT);
    pinMode(ECHO_PIN,  INPUT);
    digitalWrite(TRIG_PIN, LOW);
    dht.begin();

    // --- Servo quạt (GPIO 13) ---
    fanServo.attach(GPIO_FAN);
    fanServo.write(0);

    // --- Servo cửa (GPIO 26) ---
    doorServo.attach(SERVO_DOOR_PIN);
    doorServo.write(0);

    // --- SPI + RC522 ---
    SPI.begin(SCK_PIN, MISO_PIN, MOSI_PIN, SS_PIN);
    mfrc522.PCD_Init();
    delay(100);
    byte ver = mfrc522.PCD_ReadRegister(MFRC522::VersionReg);
    Serial.printf("[RFID] Firmware: 0x%02X %s\n", ver,
        (ver == 0x91 || ver == 0x92) ? "-> OK" : "-> ERROR (kiem tra ket noi)");

    // --- WiFi + WebSocket ---
    setupWiFi();
    webSocket.begin(SERVER_HOST, SERVER_PORT, SERVER_PATH);
    webSocket.onEvent(webSocketEvent);
    webSocket.setReconnectInterval(5000);
    webSocket.enableHeartbeat(15000, 3000, 2);

    Serial.println("[INIT] Done! Go HELP de xem lenh.");
}

void loop() {
    webSocket.loop();
    updateFan();
    handleRFID();
    handleSerialCommand();

    if (millis() - lastSensorRead >= SENSOR_INTERVAL) {
        lastSensorRead = millis();
        readAllSensors();   // đọc + gửi WebSocket
    }
}