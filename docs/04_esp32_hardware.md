# 4. Phần III: ESP32 — Báo cáo Kỹ thuật Phần cứng & Firmware

Tiêu đề: Phân tích sketch ESP32, cấu hình WebSocket và quản lý tài nguyên

Tóm tắt
ESP32 trong dự án hoạt động như WebSocket client kết nối tới FastAPI server. Firmware sử dụng `WebSocketsClient` và `ArduinoJson`; báo cáo này mô tả cấu hình, hành vi runtime, các vấn đề bộ nhớ tiềm năng và khuyến nghị tối ưu.

1. Nguồn dữ liệu & Phương pháp
Phân tích trực tiếp mã firmware: `esp32_client/esp32_client.ino` (đoạn khởi tạo WebSocket, callback, gửi log, cấu hình heartbeat, reconnect và SENSOR_INTERVAL).

2. Hiện trạng (Evidence)
- Thư viện WebSocket: `WebSocketsClient` (Links2004) — khởi tạo bằng `webSocket.begin(SERVER_HOST, SERVER_PORT, SERVER_PATH)`.
- Cấu hình kết nối/độ tin cậy: `webSocket.setReconnectInterval(5000);` và `webSocket.enableHeartbeat(15000, 3000, 2);`.
- Firmware dùng `ArduinoJson` với `StaticJsonDocument<512>` cho logs và `StaticJsonDocument<128>` cho ACK nhỏ; gửi bằng `serializeJson()` rồi `webSocket.sendTXT(out)`.
- Sensor sampling: biến `SENSOR_INTERVAL` quy định khoảng đọc cảm biến (theo code là 2000 ms).

3. Phân tích
- Việc dùng `StaticJsonDocument` là phù hợp để hạn chế fragmentation heap; cần tính chính xác dung lượng tài liệu để tránh lỗi `allocate`.
- Heartbeat và reconnect đã được cấu hình ở phía client, cải thiện tính ổn định trong môi trường mạng không ổn định.

4. Hạn chế
- Firmware hiện hardcode `SERVER_HOST/PORT/PATH` và thông tin Wi‑Fi; cần cơ chế cấu hình (SmartConfig hoặc captive portal) cho triển khai thực tế.
- Nếu payload lớn hoặc nhiều sự kiện/s giây, việc dùng JSON có thể tiêu tốn RAM; cân nhắc binary encoding (CBOR/Protobuf).

5. Khuyến nghị
- Cấu hình: cung cấp cơ chế cấu hình mạng (WiFiManager/captive portal) thay vì hardcode.
- Bộ nhớ: xác định kích thước `StaticJsonDocument` tối thiểu cần thiết bằng profiling, tránh `String` thừa.
- Mở rộng: giữ heartbeat ngắn/hợp lý (15s) và điều chỉnh reconnect interval + jitter nếu cần để tránh thundering herd.

6. Tài liệu tham khảo
- `esp32_client/esp32_client.ino`

