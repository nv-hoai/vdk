# 5. Phần IV: Định dạng dữ liệu và Bảo mật — Báo cáo

Tiêu đề: Đánh giá định dạng payload và các biện pháp bảo mật cho kênh WebSocket/REST trong hệ thống Smart Home

Tóm tắt
Báo cáo phân tích lựa chọn định dạng dữ liệu (JSON vs binary formats) và thực trạng bảo mật (WS vs WSS, authentication) trong repository. Kết luận và khuyến nghị được đưa ra để hướng tới môi trường production an toàn.

1. Phương pháp
So sánh cấu trúc payload và đọc các cấu hình WebSocket trong `server/main.py` và `esp32_client/esp32_client.ino` để xác định trạng thái mã hóa và cơ chế heartbeat.

2. Hiện trạng (Evidence)
- Payload hiện dùng JSON trong cả server và firmware; ví dụ command: `{"action":"set_state","deviceId":"lamp-1","isOn":true}`.
- Kết nối ESP32 → Server sử dụng plain WS (log server in ra `ws://localhost:{port}/ws/esp32`) — không có TLS.
- ESP32 kích hoạt heartbeat bằng `webSocket.enableHeartbeat(15000, 3000, 2)`.

3. Phân tích
- JSON là thuận tiện cho phát triển nhưng kém hiệu quả ở quy mô lớn (băng thông và CPU). Với payload nhỏ (<256 bytes) JSON chấp nhận được; nếu cần tiết kiệm băng thông, Protobuf/CBOR là lựa chọn tốt.
- Thiếu TLS/WSS và authentication khiến hệ thống dễ bị tấn công MITM hoặc spoofing thiết bị.

4. Hạn chế
- Hiện chưa có cơ chế xác thực WebSocket trên server; server chấp nhận kết nối ESP32 mà không validate token.

5. Khuyến nghị bảo mật (Recommendation)
- Bắt buộc cho production: chuyển sang `wss://` (TLS). Có thể cấu hình TLS trên reverse proxy (nginx) hoặc trực tiếp trên ASGI server.
- Authentication: dùng JWT hoặc token-based auth; xác thực token ngay sau khi mở socket (hoặc sử dụng `Sec-WebSocket-Protocol`).
- Heartbeat & health checks: tiếp tục dùng ping/pong, điều chỉnh interval phù hợp; server nên có timeout logic để dọn connections stale.
- Định dạng dữ liệu: nếu hệ thống mở rộng đến hàng nghìn thiết bị, cân nhắc Protobuf/CBOR để tiết kiệm băng thông và RAM trên ESP32.

6. Kế hoạch hành động
- Ngắn hạn: triển khai TLS trên proxy và yêu cầu token trong message auth đầu tiên.  
- Trung hạn: cung cấp tooling để sinh parser Protobuf cho ESP32 và client nếu cần.

Tài liệu tham khảo
- `server/main.py`
- `esp32_client/esp32_client.ino`

