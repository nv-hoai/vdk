# 3. Phần II: Server (FastAPI) — Phân tích và Đề xuất

Tiêu đề: Phân tích hiện trạng triển khai Server, điều phối tin nhắn và phương án mở rộng

Tóm tắt
Báo cáo mô tả hiện trạng server (FastAPI), cơ chế quản lý kết nối WebSocket với ESP32 và Flutter App, các message types hiện có, hạn chế về kiến trúc single-instance, và đề xuất mở rộng để hỗ trợ multi-device + auth.

1. Phương pháp
Đọc và phân tích mã nguồn `server/main.py`, xác định endpoints, luồng điều phối lệnh, và phương thức lưu trữ log/sensor.

2. Hiện trạng (Evidence)
- Công nghệ chính: `Python + FastAPI + uvicorn` (xem [server/main.py](server/main.py)).
- **WebSocket Endpoints**:
  - `/ws/esp32`: ESP32 device kết nối; server lưu socket trong `esp32_ws_client` (single device support)
  - `/ws/app`: Flutter App clients kết nối; server lưu list sockets trong `app_ws_clients` (multi-client support)
- **Health Check**: `/health` endpoint để monitoring
- **Giao tiếp**:
  - ESP32 → Server: gửi log events và sensor data (PIR, light, gas, temperature, humidity, buzzer)
  - Server → Flutter Apps: broadcast nhận sensor data realtime, send device state snapshots
  - Flutter App → Server: gửi device control commands (set_state, get_logs)
- **Lưu trữ**: Log/sensor data được persist dưới dạng newline-delimited JSON (`server_logs.jsonl`, `server_sensor_data.jsonl`)
- **Discovery**: UDP responder trên port 5001 cho LAN device discovery

3. Phân tích & Kết quả
- **Message Types**: Định nghĩa constants cho `MSG_TYPE_LOG`, `MSG_TYPE_SENSOR`, `MSG_TYPE_SNAPSHOT`, `MSG_TYPE_ACK`, `MSG_TYPE_LOGS_RESPONSE` để avoid hardcoded strings.
- **Broadcasting**: Server có helper function `broadcast_to_app_clients()` để gửi message tới tất cả kết nối Flutter clients một lần (efficient).
- **Command Forwarding**: Khi app gửi `set_state` action, server forward tới ESP32 rồi ack lại app.
- **Single ESP32 Pattern**: `esp32_ws_client` là biến toàn cục → chỉ hỗ trợ 1 device. Cần refactor để scale.

4. Hạn chế và rủi ro
- **Single Device Architecture**: `esp32_ws_client` chỉ lưu 1 kết nối → không support multi-device deployments
- **No Authentication**: WebSocket endpoints không validate client identity (anyone can connect từ network)
- **No TLS/Encryption**: Plain WebSocket (ws://) → dữ liệu transmitted in plaintext
- **In-Memory Broadcasting**: `app_ws_clients` list có thể bị OOM nếu app clients không clean disconnect (zombie connections)

5. Khuyến nghị (Recommendation)
- **Ngắn hạn (now)**:
  - Code cleanup ✅ (xóa unused endpoints, Whisper model, extract constants)
  - Add connection state monitoring (detect stale clients)
  - Add graceful shutdown handling
- **Trung hạn (1-2 months)**:
  - Implement device registry: `Dict[deviceId, WebSocket]` thay `esp32_ws_client`
  - Add JWT token validation trên WebSocket accept
  - Implement heartbeat + reconnection logic
- **Dài hạn (production)**:
  - WSS (TLS) + strong auth (mTLS hoặc pre-shared keys)
  - Move logs từ JSONL → time-series DB (InfluxDB) cho efficient querying
  - Use Redis/RabbitMQ cho message broker khi multi-instance

6. Kế hoạch triển khai (ngắn)
- Phase 1: Implement device registry + clean shutdown
- Phase 2: Add JWT auth + heartbeat
- Phase 3: Migrate logs → time-series DB

Tài liệu tham khảo
- [server/main.py](server/main.py) - Constants-driven configuration
- [esp32_client/esp32_client.ino](esp32_client/esp32_client.ino) - ESP32 WebSocket client
- [smarthomeapp/lib/screens/home_screen.dart](smarthomeapp/lib/screens/home_screen.dart) - Flutter WebSocket integration

