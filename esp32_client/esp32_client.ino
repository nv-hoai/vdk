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
//  CHÂN GPIO
// ============================================================
const int GPIO_LAMP      = 21;
const int GPIO_LAMP_BED1 = 25;
const int GPIO_LAMP_BED2 = 27;
const int GPIO_FAN       = 13;   // Servo quạt

#define PIR_PIN        4
#define LIGHT_PIN      34
#define DHT_PIN        14
#define SERVO_DOOR_PIN 26
#define TRIG_PIN       16
#define ECHO_PIN       17
#define GAS_PIN        35

#define SS_PIN   5
#define RST_PIN  22
#define SCK_PIN  18
#define MISO_PIN 19
#define MOSI_PIN 23

// ============================================================
//  NGƯỠNG CẢM BIẾN
// ============================================================
const int   LIGHT_THRESHOLD    = 1000;   // < ngưỡng = tối
const float TEMP_FAN_LOW       = 28.0f;  // < 28°C → tắt quạt
const float TEMP_FAN_HIGH      = 32.0f;  // > 32°C → quạt nhanh
const float HUMID_FAN_BOOST    = 80.0f;  // độ ẩm > 80% → tăng tốc quạt
const int   GAS_WARNING        = 2000;   // ngưỡng khí gas nguy hiểm (analog)
const int   GAS_DANGER         = 3000;   // ngưỡng khí gas cực nguy hiểm
const unsigned long NO_MOTION_LAMP_OFF  = 5UL  * 60 * 1000; // 5 phút
const unsigned long NO_MOTION_BED_OFF   = 10UL * 60 * 1000; // 10 phút
const unsigned long DOOR_OPEN_DURATION  = 30UL * 1000;       // 30 giây
const unsigned long INTRUDER_GRACE      = 10UL * 1000;       // 10 giây
const unsigned long AUTO_RESUME_DELAY   = 30UL * 60 * 1000;  // 30 phút → trở về AUTO

// ============================================================
//  CHẾ ĐỘ HỆ THỐNG
// ============================================================
enum SystemMode { AUTO, MANUAL };
SystemMode systemMode = AUTO;
unsigned long lastManualCommandTime = 0;

// ============================================================
//  ĐỊNH NGHĨA THIẾT BỊ
// ============================================================
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

// ============================================================
//  BIẾN TRẠNG THÁI CẢM BIẾN
// ============================================================
int   lastPIR       = 0;
int   lastLight     = 0;
float lastTemp      = NAN;
float lastHumid     = NAN;
float lastDist      = -1;
int   lastGas       = 0;
bool  gasAlertSent  = false;
bool  gasDangerSent = false;

unsigned long lastMotionTime       = 0;
unsigned long lastSensorRead       = 0;
unsigned long doorOpenedAt         = 0;
unsigned long rfidAuthorizedAt     = 0;
bool          doorIsOpen           = false;
bool          rfidRecentlyAuth     = false;
bool          intruderAlertSent    = false;

const unsigned long SENSOR_INTERVAL = 2000;

// ============================================================
//  WEBSOCKET
// ============================================================
WebSocketsClient webSocket;

// ============================================================
//  FORWARD DECLARATIONS
// ============================================================
void setDeviceStateAuto(const String& id, bool isOn, const char* reason);
void sendLog(const char* event, JsonObject& meta);
void sendAck(const String& deviceId, bool isOn);

// ============================================================
//  LOGGING LÊN SERVER
// ============================================================

// Gửi log sự kiện kèm metadata tùy ý
// Cách dùng: tạo JsonDocument, lấy root object, truyền vào
void sendEventLog(const char* event, StaticJsonDocument<384>& metaDoc) {
    StaticJsonDocument<512> doc;
    doc["type"]      = "log";
    doc["event"]     = event;
    doc["timestamp"] = millis();
    doc["mode"]      = (systemMode == AUTO) ? "AUTO" : "MANUAL";

    // Sao chép metadata vào trường "meta"
    JsonObject meta = doc.createNestedObject("meta");
    for (JsonPair kv : metaDoc.as<JsonObject>()) {
        meta[kv.key()] = kv.value();
    }

    String out;
    serializeJson(doc, out);
    webSocket.sendTXT(out);
    Serial.printf("[WS TX] LOG[%s] -> %s\n", event, out.c_str());
}

// Macro tiện lợi: gửi log không có metadata
void sendSimpleLog(const char* event, const char* detail = "") {
    StaticJsonDocument<512> doc;
    doc["type"]      = "log";
    doc["event"]     = event;
    doc["timestamp"] = millis();
    doc["mode"]      = (systemMode == AUTO) ? "AUTO" : "MANUAL";
    if (strlen(detail) > 0) doc["detail"] = detail;
    String out;
    serializeJson(doc, out);
    webSocket.sendTXT(out);
    Serial.printf("[WS TX] LOG[%s] %s\n", event, detail);
}

// ============================================================
//  ACK
// ============================================================
void sendAck(const String& deviceId, bool isOn) {
    StaticJsonDocument<128> ack;
    ack["type"]     = "ack";
    ack["deviceId"] = deviceId;
    ack["isOn"]     = isOn;
    String out;
    serializeJson(ack, out);
    webSocket.sendTXT(out);
    Serial.printf("[WS TX] ACK -> %s = %s\n", deviceId.c_str(), isOn ? "ON" : "OFF");
}

// ============================================================
//  SERVO QUẠT (sweep liên tục)
// ============================================================
Servo fanServo;
bool  fanRunning   = false;
int   fanAngle     = 0;
bool  fanGoingUp   = true;
int   FAN_STEP     = 3;
int   FAN_INTERVAL = 15;
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

void setFanSpeed(int step, int interval) {
    FAN_STEP     = step;
    FAN_INTERVAL = interval;
}

void setFan(bool isOn) {
    fanRunning = isOn;
    fanGoingUp = true;
    if (!isOn) {
        fanServo.write(0);
        fanAngle = 0;
        Serial.println("[FAN] OFF -> ve 0 do");
    } else {
        Serial.printf("[FAN] ON -> step=%d interval=%d\n", FAN_STEP, FAN_INTERVAL);
    }
}

// ============================================================
//  SERVO CỬA
// ============================================================
Servo doorServo;

void servoSetAngle(int angle) {
    if (angle < 0) angle = 0;
    if (angle > 180) angle = 180;
    doorServo.write(angle);
    Serial.printf("[DOOR] Goc: %d do\n", angle);
}

void openDoor(const char* reason) {
    if (doorIsOpen) return;
    doorIsOpen    = true;
    doorOpenedAt  = millis();
    servoSetAngle(90);

    StaticJsonDocument<128> meta;
    meta["reason"] = reason;
    meta["angle"]  = 90;
    sendEventLog("door_opened", meta);
}

void closeDoor(const char* reason) {
    if (!doorIsOpen) return;
    doorIsOpen = false;
    servoSetAngle(0);

    StaticJsonDocument<128> meta;
    meta["reason"] = reason;
    meta["angle"]  = 0;
    sendEventLog("door_closed", meta);
}

// Tự động đóng cửa sau DOOR_OPEN_DURATION
void updateDoor() {
    if (doorIsOpen && (millis() - doorOpenedAt >= DOOR_OPEN_DURATION)) {
        closeDoor("auto_timeout");
    }
}

// ============================================================
//  RFID RC522
// ============================================================
MFRC522 mfrc522(SS_PIN, RST_PIN);

const String authorizedUIDs[] = {
    "96 59 E3 00",
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
    Serial.printf("\n[RFID] UID: %s\n", uid.c_str());

    if (rfidTestMode) {
        StaticJsonDocument<128> meta;
        meta["uid"]  = uid;
        meta["mode"] = "test";
        sendEventLog("rfid_scan_test", meta);
    } else {
        bool auth = isAuthorized(uid);

        StaticJsonDocument<128> meta;
        meta["uid"]        = uid;
        meta["authorized"] = auth;
        sendEventLog("rfid_scan", meta);

        if (auth) {
            Serial.println("[RFID] DUOC PHEP -> Mo cua");
            rfidRecentlyAuth  = true;
            rfidAuthorizedAt  = millis();
            intruderAlertSent = false;

            // Mở cửa
            openDoor("rfid_authorized");

            // Bật đèn phòng khách
            setDeviceStateAuto("lamp-1", true, "rfid_welcome");

            // Nếu nóng → bật quạt luôn
            if (!isnan(lastTemp) && lastTemp > TEMP_FAN_LOW) {
                setFanSpeed(3, 15);
                setDeviceStateAuto("fan-1", true, "rfid_welcome_hot");
            }
        } else {
            Serial.println("[RFID] TU CHOI");
        }
    }

    mfrc522.PICC_HaltA();
    mfrc522.PCD_StopCrypto1();
}

// ============================================================
//  THIẾT BỊ — set state
// ============================================================
Device* findDeviceById(const String& id) {
    for (size_t i = 0; i < DEVICE_COUNT; i++)
        if (id == devices[i].id) return &devices[i];
    return nullptr;
}

// Áp dụng trạng thái vật lý + gửi ACK + log
void applyDeviceState(const String& id, bool isOn, const char* trigger, const char* reason) {
    Device* dev = findDeviceById(id);
    if (!dev) { Serial.printf("[ERROR] Device not found: %s\n", id.c_str()); return; }

    bool changed = (dev->isOn != isOn);
    dev->isOn = isOn;

    if (dev->isServo) {
        setFan(isOn);
    } else {
        digitalWrite(dev->gpio, isOn ? HIGH : LOW);
    }

    // Gửi ACK
    sendAck(id, isOn);

    // Gửi log với metadata
    StaticJsonDocument<256> meta;
    meta["deviceId"]   = id;
    meta["deviceName"] = dev->name;
    meta["isOn"]       = isOn;
    meta["trigger"]    = trigger;   // "manual" | "auto"
    meta["reason"]     = reason;    // mô tả lý do cụ thể
    meta["changed"]    = changed;
    sendEventLog("device_state_changed", meta);

    Serial.printf("[DEVICE] %s -> %s (%s: %s)\n",
        dev->name, isOn ? "ON" : "OFF", trigger, reason);
}

// Điều khiển thủ công (từ WebSocket server)
void setDeviceStateManual(const String& id, bool isOn) {
    systemMode            = MANUAL;
    lastManualCommandTime = millis();
    applyDeviceState(id, isOn, "manual", "server_command");
}

// Điều khiển tự động (từ logic cảm biến)
void setDeviceStateAuto(const String& id, bool isOn, const char* reason) {
    if (systemMode == MANUAL) return;   // không override khi MANUAL
    Device* dev = findDeviceById(id);
    if (!dev) return;
    if (dev->isOn == isOn) return;      // không log nếu không có thay đổi
    if (dev->isServo && isOn) {         // cập nhật tốc độ trước khi bật
        // tốc độ đã được set ở nơi gọi nếu cần
    }
    applyDeviceState(id, isOn, "auto", reason);
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

// ============================================================
//  CẢM BIẾN — đọc và gửi server
// ============================================================
DHT dht(DHT_PIN, DHT11);

float readDistanceCM() {
    digitalWrite(TRIG_PIN, LOW);  delayMicroseconds(2);
    digitalWrite(TRIG_PIN, HIGH); delayMicroseconds(10);
    digitalWrite(TRIG_PIN, LOW);
    long dur = pulseIn(ECHO_PIN, HIGH, 30000);
    return dur == 0 ? -1 : dur * 0.034f / 2.0f;
}

void sendSensorData() {
    StaticJsonDocument<256> doc;
    doc["type"]     = "sensor_data";
    doc["pir"]      = lastPIR;
    doc["light"]    = lastLight;
    doc["gas"]      = lastGas;
    if (!isnan(lastTemp))  doc["temperature"] = lastTemp;
    if (!isnan(lastHumid)) doc["humidity"]    = lastHumid;
    if (lastDist >= 0)     doc["distance"]    = lastDist;
    String out;
    serializeJson(doc, out);
    webSocket.sendTXT(out);
}

void readAllSensors() {
    lastPIR   = digitalRead(PIR_PIN);
    lastLight = analogRead(LIGHT_PIN);
    lastGas   = analogRead(GAS_PIN);
    lastTemp  = dht.readTemperature();
    lastHumid = dht.readHumidity();
    lastDist  = readDistanceCM();

    Serial.printf("\n[SENSOR] PIR=%d Light=%d Gas=%d Temp=%.1f Hum=%.1f Dist=%.1f\n",
        lastPIR, lastLight, lastGas, lastTemp, lastHumid, lastDist);

    sendSensorData();
}

// ============================================================
//  LOGIC TỰ ĐỘNG — chạy sau mỗi lần đọc cảm biến
// ============================================================

// --- Logic 1: Gas ---
void logicGas() {
    if (lastGas >= GAS_DANGER && !gasDangerSent) {
        gasDangerSent = true;
        gasAlertSent  = true;

        StaticJsonDocument<128> meta;
        meta["gasValue"]   = lastGas;
        meta["threshold"]  = GAS_DANGER;
        meta["level"]      = "DANGER";
        sendEventLog("gas_alert", meta);

        // Mở cửa thoát khí
        openDoor("gas_danger");
        // Bật đèn toàn bộ để cảnh báo
        setDeviceStateAuto("lamp-1",    true, "gas_danger_alert");
        setDeviceStateAuto("lamp-bed1", true, "gas_danger_alert");
        setDeviceStateAuto("lamp-bed2", true, "gas_danger_alert");
        // Tắt quạt (tránh tia lửa điện)
        setDeviceStateAuto("fan-1", false, "gas_danger_no_spark");
        Serial.println("[GAS] !!! NGUY HIEM - Mo cua, bat den, tat quat !!!");

    } else if (lastGas >= GAS_WARNING && !gasAlertSent) {
        gasAlertSent = true;

        StaticJsonDocument<128> meta;
        meta["gasValue"]  = lastGas;
        meta["threshold"] = GAS_WARNING;
        meta["level"]     = "WARNING";
        sendEventLog("gas_alert", meta);

        openDoor("gas_warning");
        Serial.println("[GAS] Canh bao khi gas - Mo cua thoat khi");

    } else if (lastGas < GAS_WARNING) {
        // Reset cờ khi gas về mức an toàn
        if (gasAlertSent || gasDangerSent) {
            sendSimpleLog("gas_clear", "Gas returned to safe level");
        }
        gasAlertSent  = false;
        gasDangerSent = false;
    }
}

// --- Logic 2: Nhiệt độ + Độ ẩm → Quạt ---
void logicFan() {
    if (isnan(lastTemp)) return;
    // Không override nếu gas nguy hiểm (quạt đang tắt vì an toàn)
    if (gasDangerSent) return;

    bool shouldFanOn = false;
    int  step = 3, interval = 15;

    if (lastTemp >= TEMP_FAN_HIGH) {
        shouldFanOn = true;
        step = 5; interval = 8;   // nhanh
    } else if (lastTemp >= TEMP_FAN_LOW) {
        shouldFanOn = true;
        step = 3; interval = 15;  // vừa
    }

    // Boost nếu độ ẩm cao
    if (!isnan(lastHumid) && lastHumid > HUMID_FAN_BOOST && shouldFanOn) {
        step     = min(step + 1, 6);
        interval = max(interval - 3, 5);
    }

    Device* fan = findDeviceById("fan-1");
    if (!fan) return;

    if (shouldFanOn) {
        setFanSpeed(step, interval);
        setDeviceStateAuto("fan-1", true,
            lastTemp >= TEMP_FAN_HIGH ? "temp_high" : "temp_medium");
    } else {
        setDeviceStateAuto("fan-1", false, "temp_low");
    }
}

// --- Logic 3: PIR + Ánh sáng → Đèn ---
void logicLighting() {
    bool isDark      = (lastLight < LIGHT_THRESHOLD);
    bool motionNow   = (lastPIR == HIGH);

    if (motionNow) {
        lastMotionTime    = millis();
        rfidRecentlyAuth  = false;   // chuyển động thường, không phải từ RFID
        intruderAlertSent = false;
    }

    unsigned long noMotionDuration = millis() - lastMotionTime;

    // Bật đèn phòng khách: tối + có người
    if (isDark && motionNow) {
        setDeviceStateAuto("lamp-1", true, "motion_dark");
    }
    // Tắt đèn phòng khách sau NO_MOTION_LAMP_OFF
    if (!motionNow && noMotionDuration > NO_MOTION_LAMP_OFF) {
        setDeviceStateAuto("lamp-1", false, "no_motion_timeout");
    }
    // Tắt đèn nếu trời sáng
    if (!isDark) {
        setDeviceStateAuto("lamp-1",    false, "daylight");
        setDeviceStateAuto("lamp-bed1", false, "daylight");
        setDeviceStateAuto("lamp-bed2", false, "daylight");
    }
}

// --- Logic 4: Chế độ ngủ thông minh → Đèn phòng ngủ ---
void logicSleepMode() {
    bool noMotionLong = (millis() - lastMotionTime > NO_MOTION_BED_OFF);
    bool tempOk       = (!isnan(lastTemp) && lastTemp < TEMP_FAN_HIGH);

    Device* bed1 = findDeviceById("lamp-bed1");
    Device* bed2 = findDeviceById("lamp-bed2");
    if (!bed1 || !bed2) return;

    // Nếu 1 trong 2 đèn ngủ đang bật + không có ai + nhiệt độ ổn → tắt đèn, giảm quạt
    if ((bed1->isOn || bed2->isOn) && noMotionLong && tempOk) {
        setDeviceStateAuto("lamp-bed1", false, "sleep_mode_no_motion");
        setDeviceStateAuto("lamp-bed2", false, "sleep_mode_no_motion");
        // Quạt ru ngủ nhẹ
        Device* fan = findDeviceById("fan-1");
        if (fan && fan->isOn) {
            setFanSpeed(1, 40);
            StaticJsonDocument<64> meta;
            meta["fanStep"]     = 1;
            meta["fanInterval"] = 40;
            meta["reason"]      = "sleep_mode";
            sendEventLog("fan_speed_changed", meta);
            Serial.println("[SLEEP] Giam toc quat che do ngu");
        }
    }
}

// --- Logic 5: Bảo mật — PIR không có RFID ---
void logicSecurity() {
    bool motionNow = (lastPIR == HIGH);

    // Nếu RFID vừa xác thực trong vòng INTRUDER_GRACE thì bỏ qua
    if (rfidRecentlyAuth &&
        (millis() - rfidAuthorizedAt < INTRUDER_GRACE)) return;

    if (motionNow && !rfidRecentlyAuth && !intruderAlertSent) {
        intruderAlertSent = true;

        StaticJsonDocument<128> meta;
        meta["pirValue"]   = lastPIR;
        meta["lightValue"] = lastLight;
        meta["gasValue"]   = lastGas;
        sendEventLog("intruder_detected", meta);

        // Nháy đèn phòng khách cảnh báo (blocking ngắn)
        for (int i = 0; i < 5; i++) {
            digitalWrite(GPIO_LAMP, HIGH); delay(200);
            digitalWrite(GPIO_LAMP, LOW);  delay(200);
        }
        Serial.println("[SECURITY] Phat hien xam nhap!");
    }

    // Reset khi không còn chuyển động
    if (!motionNow) {
        intruderAlertSent = false;
        rfidRecentlyAuth  = false;
    }
}

// --- Logic 6: Tự động về AUTO sau thời gian không có lệnh manual ---
void logicModeManager() {
    if (systemMode == MANUAL &&
        (millis() - lastManualCommandTime > AUTO_RESUME_DELAY)) {
        systemMode = AUTO;
        sendSimpleLog("mode_changed", "AUTO resumed after manual timeout");
        Serial.println("[MODE] Tro ve AUTO sau 30 phut khong co lenh thu cong");
    }
}

// Gọi tất cả logic tự động
void runAutoLogic() {
    logicModeManager();
    logicGas();         // Ưu tiên cao nhất
    logicFan();
    logicLighting();
    logicSleepMode();
    logicSecurity();
}

// ============================================================
//  WEBSOCKET — xử lý lệnh từ server
// ============================================================
void handleWebSocketMessage(uint8_t* payload, size_t length) {
    StaticJsonDocument<256> doc;
    if (deserializeJson(doc, payload, length)) {
        Serial.println("[JSON] Parse error");
        return;
    }

    const char* action = doc["action"];
    if (!action) { Serial.println("[JSON] Missing action"); return; }

    if (strcmp(action, "set_state") == 0) {
        const char* deviceId = doc["deviceId"];
        bool isOn = doc["isOn"] | false;
        if (!deviceId) { Serial.println("[JSON] Missing deviceId"); return; }
        Serial.printf("[CMD] set_state: %s -> %s\n", deviceId, isOn ? "ON" : "OFF");
        setDeviceStateManual(String(deviceId), isOn);

    } else if (strcmp(action, "get_state") == 0) {
        sendAllStates();

    } else if (strcmp(action, "get_sensors") == 0) {
        sendSensorData();

    } else if (strcmp(action, "set_mode") == 0) {
        const char* mode = doc["mode"];
        if (mode && strcmp(mode, "AUTO") == 0) {
            systemMode = AUTO;
            sendSimpleLog("mode_changed", "Switched to AUTO by server");
        } else if (mode && strcmp(mode, "MANUAL") == 0) {
            systemMode = MANUAL;
            lastManualCommandTime = millis();
            sendSimpleLog("mode_changed", "Switched to MANUAL by server");
        }

    } else if (strcmp(action, "open_door") == 0) {
        systemMode = MANUAL;
        lastManualCommandTime = millis();
        openDoor("server_command");

    } else if (strcmp(action, "close_door") == 0) {
        systemMode = MANUAL;
        lastManualCommandTime = millis();
        closeDoor("server_command");

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
            Serial.printf("[WS] Connected to ws://%s:%u%s\n",
                SERVER_HOST, SERVER_PORT, SERVER_PATH);
            sendAllStates();
            sendSimpleLog("esp32_connected", "ESP32 online");
            break;
        case WStype_TEXT:
            Serial.printf("[WS RX] %s\n", payload);
            handleWebSocketMessage(payload, length);
            break;
        case WStype_ERROR:
            Serial.printf("[WS ERROR] %s\n", payload);
            break;
        default: break;
    }
}

// ============================================================
//  LỆNH SERIAL (debug)
// ============================================================
void handleSerialCommand() {
    if (!Serial.available()) return;
    String cmd = Serial.readStringUntil('\n');
    cmd.trim();

    if      (cmd == "DOOR_OPEN")     { openDoor("serial_cmd"); }
    else if (cmd == "DOOR_CLOSE")    { closeDoor("serial_cmd"); }
    else if (cmd == "FAN_ON")        { setFanSpeed(3, 15); setDeviceStateManual("fan-1", true); }
    else if (cmd == "FAN_OFF")       { setDeviceStateManual("fan-1", false); }
    else if (cmd == "LAMP1_ON")      { setDeviceStateManual("lamp-1", true); }
    else if (cmd == "LAMP1_OFF")     { setDeviceStateManual("lamp-1", false); }
    else if (cmd == "BED1_ON")       { setDeviceStateManual("lamp-bed1", true); }
    else if (cmd == "BED1_OFF")      { setDeviceStateManual("lamp-bed1", false); }
    else if (cmd == "BED2_ON")       { setDeviceStateManual("lamp-bed2", true); }
    else if (cmd == "BED2_OFF")      { setDeviceStateManual("lamp-bed2", false); }
    else if (cmd == "READ")          { readAllSensors(); }
    else if (cmd == "MODE_AUTO")     { systemMode = AUTO;   Serial.println("[MODE] AUTO"); }
    else if (cmd == "MODE_MANUAL")   { systemMode = MANUAL; lastManualCommandTime = millis(); Serial.println("[MODE] MANUAL"); }
    else if (cmd == "RFID_TEST_ON")  { rfidTestMode = true;  Serial.println("[RFID] Test ON"); }
    else if (cmd == "RFID_TEST_OFF") { rfidTestMode = false; Serial.println("[RFID] Test OFF"); }
    else if (cmd == "RFID_STATUS") {
        byte ver = mfrc522.PCD_ReadRegister(MFRC522::VersionReg);
        Serial.printf("[RFID] Firmware: 0x%02X %s\n", ver,
            (ver == 0x91 || ver == 0x92) ? "OK" : "ERROR");
    }
    else if (cmd == "STATUS") {
        Serial.printf("[STATUS] Mode: %s\n", systemMode == AUTO ? "AUTO" : "MANUAL");
        Serial.printf("[STATUS] PIR=%d Light=%d Gas=%d Temp=%.1f Hum=%.1f Dist=%.1f\n",
            lastPIR, lastLight, lastGas, lastTemp, lastHumid, lastDist);
        for (size_t i = 0; i < DEVICE_COUNT; i++) {
            Serial.printf("  [%s] %s -> %s\n",
                devices[i].id, devices[i].name, devices[i].isOn ? "ON" : "OFF");
        }
    }
    else if (cmd == "HELP") {
        Serial.println("====== LENH SERIAL ======");
        Serial.println("  DOOR_OPEN/CLOSE         : Mo/dong cua");
        Serial.println("  FAN_ON/OFF              : Quat");
        Serial.println("  LAMP1_ON/OFF            : Den phong khach");
        Serial.println("  BED1_ON/OFF             : Den phong ngu 1");
        Serial.println("  BED2_ON/OFF             : Den phong ngu 2");
        Serial.println("  READ                    : Doc cam bien");
        Serial.println("  STATUS                  : Xem toan bo trang thai");
        Serial.println("  MODE_AUTO / MODE_MANUAL : Doi che do");
        Serial.println("  RFID_TEST_ON/OFF        : Test RFID");
        Serial.println("  RFID_STATUS             : Kiem tra RC522");
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
    Serial.printf("[WiFi] Connecting to %s\n", WIFI_SSID);
    WiFi.mode(WIFI_STA);
    WiFi.begin(WIFI_SSID, WIFI_PASS);
    int attempts = 0;
    while (WiFi.status() != WL_CONNECTED && attempts < 20) {
        delay(500); Serial.print("."); attempts++;
    }
    Serial.println();
    if (WiFi.status() != WL_CONNECTED) {
        Serial.println("[WiFi] Failed! Restarting...");
        delay(3000); ESP.restart();
    }
    Serial.printf("[WiFi] Connected! IP: %s\n", WiFi.localIP().toString().c_str());
}

// ============================================================
//  SETUP & LOOP
// ============================================================
void setup() {
    Serial.begin(115200);
    delay(1000);
    Serial.println("\n=== Smart Home ESP32 Unified ===");

    // GPIO đèn
    int lampPins[] = {GPIO_LAMP, GPIO_LAMP_BED1, GPIO_LAMP_BED2};
    for (int pin : lampPins) { pinMode(pin, OUTPUT); digitalWrite(pin, LOW); }

    // Cảm biến
    pinMode(PIR_PIN,   INPUT);
    pinMode(LIGHT_PIN, INPUT);
    pinMode(GAS_PIN,   INPUT);
    pinMode(TRIG_PIN,  OUTPUT);
    pinMode(ECHO_PIN,  INPUT);
    digitalWrite(TRIG_PIN, LOW);
    dht.begin();

    // Servo quạt
    fanServo.attach(GPIO_FAN);
    fanServo.write(0);

    // Servo cửa
    doorServo.attach(SERVO_DOOR_PIN);
    doorServo.write(0);

    // SPI + RC522
    SPI.begin(SCK_PIN, MISO_PIN, MOSI_PIN, SS_PIN);
    mfrc522.PCD_Init();
    delay(100);
    byte ver = mfrc522.PCD_ReadRegister(MFRC522::VersionReg);
    Serial.printf("[RFID] Firmware: 0x%02X %s\n", ver,
        (ver == 0x91 || ver == 0x92) ? "-> OK" : "-> ERROR");

    // WiFi + WebSocket
    setupWiFi();
    webSocket.begin(SERVER_HOST, SERVER_PORT, SERVER_PATH);
    webSocket.onEvent(webSocketEvent);
    webSocket.setReconnectInterval(5000);
    webSocket.enableHeartbeat(15000, 3000, 2);

    Serial.println("[INIT] Done! Go HELP de xem lenh.\n");
}

void loop() {
    webSocket.loop();
    updateFan();
    updateDoor();
    handleRFID();
    handleSerialCommand();

    if (millis() - lastSensorRead >= SENSOR_INTERVAL) {
        lastSensorRead = millis();
        readAllSensors();
        runAutoLogic();
    }
}
