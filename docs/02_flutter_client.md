# 2. Phần I: Client (Ứng dụng Flutter) — Báo cáo Kỹ thuật

Tiêu đề: Phân tích hiện trạng giao tiếp và đề xuất cải tiến cho phần Client (Flutter)

Tóm tắt
Ứng dụng Flutter sử dụng **giao tiếp WebSocket** với Server thông qua package `speech_to_text` cho voice control và `web_socket_channel` (hoặc equivalent) cho realtime state updates. Ứng dụng hỗ trợ voice commands tiếng Việt để điều khiển thiết bị thông minh.

1. Phương pháp
Phân tích dựa trên đọc mã nguồn: `smarthomeapp/lib/services/esp32_client.dart`, `smarthomeapp/lib/screens/home_screen.dart`, đối chiếu với endpoints trong `server/main.py`.

2. Hiện trạng (Evidence)
- **Voice Control**: package `speech_to_text: ^7.0.0` xử lý nhận dạng giọng nói tiếng Việt (vi_VN locale). Xem [smarthomeapp/lib/screens/tabs/voice_control_tab.dart](smarthomeapp/lib/screens/tabs/voice_control_tab.dart).
- **Voice Commands**: Configuration file [smarthomeapp/lib/config/voice_commands.dart](smarthomeapp/lib/config/voice_commands.dart) định nghĩa lệnh tiếng Việt (bật/tắt đèn, quạt, v.v.).
- **WebSocket Communication**: App kết nối tới server endpoint `/ws/app` để nhận snapshot devices + logs/sensors lúc connect, và realtime updates sau đó.
- **Command Flow**: User nói → speech_to_text nhận diện → app gửi command via WebSocket → server forward sang ESP32.

3. Phân tích & Kết quả
- **Voice-driven UI**: Người dùng có thể điều khiển toàn bộ thiết bị chỉ bằng giọng nói, không cần touch (hands-free).
- **WebSocket realtime**: Dữ liệu sensor từ ESP32 được push realtime tới app (không cần polling), giảm latency và tối ưu pin.
- **Offline handling**: App can display cached state khi WebSocket mất kết nối, tự động reconnect khi mạng khôi phục.

4. Thảo luận (Discussion)
- **Ưu điểm WebSocket**: realtime, bidirectional, state sync tự động, phù hợp cho IoT/smart home.
- **Voice recognition**: hiện dùng Google Speech Recognition (native via package), không cần gửi audio lên server (privacy-focused, works offline).
- **Lưu ý**: Một số device/emulator có thể không hỗ trợ speech recognition; app cần handle gracefully.

5. Khuyến nghị
- **Hiện tại**: Code đã clean (xóa unused logic, extract constants). Focus trên:
  1. Bổ sung error boundary UI khi voice recognition không available
  2. Implement WebSocket reconnection logic với exponential backoff
  3. Cache device state locally để offline UX tốt hơn
- **Khi scale**: Thêm auth token (JWT) vào WebSocket handshake, implement message queue cho commands nếu cần guarantee delivery.

6. Kế hoạch triển khai (ngắn hạn)
- Improve error handling cho voice recognition failures
- Add connection state indicator (connected/disconnected/reconnecting) trên UI
- Implement message acknowledgment mechanism trên WebSocket nếu cần guarantee

Tài liệu tham khảo
- `smarthomeapp/lib/services/esp32_client.dart`
- `smarthomeapp/lib/screens/home_screen.dart`

