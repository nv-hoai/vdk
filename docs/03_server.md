# 3. Phần II: Server (FastAPI) — Phân tích và Đề xuất

Tiêu đề: Phân tích hiện trạng triển khai Server, điều phối tin nhắn và phương án mở rộng

Tóm tắt
Báo cáo mô tả hiện trạng server (FastAPI), cơ chế quản lý kết nối với ESP32, các endpoints REST hiện có, hạn chế về kiến trúc single-instance và đề xuất mở rộng để hỗ trợ nhiều thiết bị và kết nối realtime cho client.

1. Phương pháp
Đọc và phân tích mã nguồn `server/main.py`, xác định endpoints, luồng điều phối lệnh, và phương thức lưu trữ log/sensor.

2. Hiện trạng (Evidence)
- Công nghệ chính: `Python + FastAPI + uvicorn` (xem [server/main.py](server/main.py)).
- Endpoints REST: `/health`, `/devices`, `/devices/{id}`, `/devices/{id}/state`, `/logs`, `/sensors`, `/transcribe`.
- WebSocket: có endpoint `/ws/esp32` dành cho ESP32; server lưu socket hiện tại trong `esp32_ws_client` (biến toàn cục), xem hàm websocket tại [server/main.py#L264-L277].
- Lưu trữ log/sensor: file newline-delimited JSON (`server_logs.jsonl`, `server_sensor_data.jsonl`).

3. Phân tích & Kết quả
- Mô hình hiện tại là single-instance, single-ESP32: server chỉ có thể quản lý một kết nối ESP32 đồng thời qua `esp32_ws_client`.
- Khi App gọi `POST /devices/{id}/state`, server gọi `send_command_to_esp32()` để forward JSON command tới ESP32 nếu kết nối tồn tại.

4. Hạn chế và rủi ro
- Không hỗ trợ nhiều thiết bị/multi-instance: biến toàn cục không phù hợp để scale.
- Thiếu cơ chế xác thực cho WebSocket; WS hiện là plain (không TLS).
- Lưu file logs dưới dạng JSONL phù hợp cho dev nhưng không tối ưu cho truy vấn/scale.

5. Khuyến nghị (Recommendation)
- Ngắn hạn: bổ sung kiểm tra trạng thái khi `esp32_ws_client` rỗng và trả lỗi có ý nghĩa cho client. Chuyển lưu trữ logs sang DB nhẹ (SQLite/Postgres) nếu cần phân tích.
- Trung hạn: triển khai mapping `deviceId -> connection` (in-memory hoặc Redis) để quản lý nhiều thiết bị; sử dụng Redis Pub/Sub cho điều phối giữa nhiều instance.
- Dài hạn / production: hỗ trợ WSS (TLS), authentication (JWT/pre-shared), và dùng message broker (NATS/RabbitMQ) khi cần throughput cao.

6. Kế hoạch triển khai (ngắn)
- Bước 1: thay `esp32_ws_client` bằng registry `Map<deviceId, WebSocket>` hoặc lưu vào Redis.  
- Bước 2: thêm middleware/auth cho WebSocket (validate token trước khi accept).  
- Bước 3: di chuyển logs sang DB và thiết lập job làm sạch/rotation.

Tài liệu tham khảo
- `server/main.py`
- `esp32_client/esp32_client.ino`

