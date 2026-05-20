# 2. Phần I: Client (Ứng dụng Flutter) — Báo cáo Kỹ thuật

Tiêu đề: Phân tích hiện trạng giao tiếp và đề xuất cải tiến cho phần Client (Flutter)

Tóm tắt
Ứng dụng Flutter hiện thực hiện giao tiếp với Server thông qua HTTP REST cho các tác vụ quản lý thiết bị. Một cơ chế polling đơn giản (10s) được triển khai để làm mới danh sách thiết bị. Báo cáo này mô tả hiện trạng, phân tích hạn chế, và đề xuất các lựa chọn kiến trúc khi cần realtime.

1. Phương pháp
Phân tích dựa trên đọc mã nguồn: `smarthomeapp/lib/services/esp32_client.dart`, `smarthomeapp/lib/screens/home_screen.dart`, đối chiếu với endpoints trong `server/main.py`.

2. Hiện trạng (Evidence)
- REST API client: `fetchDevices`, `setDeviceState`, `fetchLogs`, `fetchSensors` trong [smarthomeapp/lib/services/esp32_client.dart](smarthomeapp/lib/services/esp32_client.dart).
- Polling: `HomeScreen` dùng `Timer.periodic(Duration(seconds:10))` để gọi `_loadDevices()` tự động.
- Server chưa cung cấp endpoint WSS dành cho client app (hiện có `/ws/esp32` cho ESP32).

3. Phân tích & Kết quả
- REST + polling: đơn giản, ít thay đổi server, thích hợp khi cập nhật không cần tức thời. Với polling 10s, độ trễ nhận biết trạng thái tối thiểu là ~10s.
- Ảnh hưởng tới tài nguyên: polling làm tăng băng thông và có thể ảnh hưởng tới pin thiết bị di động.

4. Thảo luận (Discussion)
- Nếu ứng dụng cần push tức thời (alerts, live telemetry), việc chuyển sang WSS cho client là hợp lý nhưng cần giải quyết: TLS (WSS), auth (JWT), heartbeat và cơ chế reconnect.
- Nếu giữ REST: có thể tối ưu bằng caching, differential update, hoặc giảm interval khi cần.

5. Khuyến nghị
- Giữ setup hiện tại nếu realtime không quan trọng; giữ polling = 10s hoặc điều chỉnh trong khoảng 5–15s tùy ưu tiên trải nghiệm vs tiết kiệm pin.
- Nếu cần realtime: triển khai WSS cho client, bổ sung auth, và dùng Redis Pub/Sub khi scale.

6. Kế hoạch triển khai (ngắn hạn)
- A: Giữ REST — tối ưu UI và đảm bảo debounce trên các thao tác user.  
- B: Chuyển WSS — tôi sẽ chuẩn bị mẫu server WSS + snippet Flutter để test.

Tài liệu tham khảo
- `smarthomeapp/lib/services/esp32_client.dart`
- `smarthomeapp/lib/screens/home_screen.dart`

