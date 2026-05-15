# ESP32 WebSocket Client Setup

File: `esp32_client.ino`

## Bước 1: Chuẩn bị Arduino IDE

1. Cài đặt Arduino IDE (nếu chưa có)
2. Thêm ESP32 board:
   - File → Preferences → Board Manager URLs → thêm: `https://dl.espressif.com/dl/package_esp32_index.json`
   - Tools → Board Manager → tìm "esp32" → cài "ESP32 by Espressif Systems"

3. Cài đặt WebSocketsClient library:
   - Sketch → Include Library → Manage Libraries
   - Tìm: "WebSocketsClient"
   - Cài: "WebSocketsClient by Links2004"

4. Cài đặt ArduinoJson library:
   - Sketch → Include Library → Manage Libraries
   - Tìm: "ArduinoJson"
   - Cài: "ArduinoJson by Benoit Blanchon"

## Bước 2: Cấu hình

Mở file `esp32_client.ino` và sửa các dòng này (section CONFIGURATION):

```cpp
const char* WIFI_SSID = "YOUR_WIFI_SSID";        // Tên Wi-Fi của bạn
const char* WIFI_PASS = "YOUR_WIFI_PASSWORD";    // Mật khẩu Wi-Fi

const char* SERVER_HOST = "192.168.1.100";       // IP PC chạy FastAPI server
const uint16_t SERVER_PORT = 5000;               // Port FastAPI (mặc định 5000)

// GPIO pin mapping (tuỳ theo board ESP32 của bạn)
const int GPIO_LAMP = 4;                         // GPIO 4 cho đèn
const int GPIO_FAN = 5;                          // GPIO 5 cho quạt
```

## Bước 3: Upload

1. Kết nối ESP32 qua USB
2. Tools → Board → chọn "ESP32 Dev Module" (hoặc board của bạn)
3. Tools → Port → chọn COM port của ESP32
4. Bấm Upload (mũi tên →)

## Bước 4: Kiểm tra

1. Mở Serial Monitor (Tools → Serial Monitor)
2. Baudrate: 115200
3. Bạn sẽ thấy:
   - WiFi connecting...
   - IP address: ...
   - WebSocket connecting...

Nếu thấy "Connected" → thành công!

## GPIO Mapping

Mặc định:
- GPIO 4 → Đèn (Lamp) - relay chân D4
- GPIO 5 → Quạt (Fan) - relay chân D5

Nếu dùng GPIO khác, sửa `GPIO_LAMP` và `GPIO_FAN` trong configuration.

## Chuẩn lệnh WebSocket

Server gửi lệnh theo format:
```json
{
  "action": "set_state",
  "deviceId": "lamp-1",
  "isOn": true
}
```

Device ID có sẵn: `lamp-1`, `fan-1`

## Troubleshooting

**"Failed to connect WiFi"**
- Kiểm tra SSID và password
- Đảm bảo WiFi 2.4GHz (ESP32 không hỗ trợ 5GHz)

**"WebSocket connection failed"**
- Kiểm tra SERVER_HOST (IP của PC)
- Đảm bảo FastAPI server đang chạy
- Kiểm tra firewall cho port 5000

**Serial port không hiện**
- Cài driver CP2102 (CH340): https://www.silabs.com/developers/usb-to-uart-bridge-vcp-drivers

## Mở rộng

Để thêm thiết bị mới:
1. Thêm entry vào mảng `devices[]`
2. Thêm GPIO pin vào `setupGPIO()`
3. Thêm device vào FastAPI server `/devices` endpoint
