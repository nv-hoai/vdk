import asyncio
import json
import os
import socket
import threading
import time
import traceback
from datetime import datetime, timezone
from typing import Optional, List, Dict, Any

import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

app = FastAPI(title="Smart Home Server")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Configuration
FASTAPI_PORT = int(os.getenv("FASTAPI_PORT", "5000"))
DISCOVERY_PORT = int(os.getenv("DISCOVERY_PORT", "5001"))
DEVICE_CACHE_TTL_SEC = 3

# WebSocket message types
MSG_TYPE_LOG = "log"
MSG_TYPE_SENSOR = "sensor_data"
MSG_TYPE_SNAPSHOT = "snapshot"
MSG_TYPE_ACK = "ack"
MSG_TYPE_LOGS_RESPONSE = "logs_response"

# Action types
ACTION_SET_STATE = "set_state"
ACTION_GET_LOGS = "get_logs"

# Event types
EVENT_DEVICE_STATE_CHANGED = "device_state_changed"
EVENT_DISCOVER_SMARTHOME = "DISCOVER_SMARTHOME"

# WebSocket paths
WS_ESP32_PATH = "/ws/esp32"
WS_APP_PATH = "/ws/app"

# Device types
DEVICE_TYPE_LIGHT = "light"
DEVICE_TYPE_FAN = "fan"
DEVICE_TYPE_UNKNOWN = "unknown"

device_cache = {
    "devices": None,
    "cached_at": 0,
    "device_by_id": {},
}

esp32_ws_client: Optional[WebSocket] = None
app_ws_clients: List[WebSocket] = []

# Simple in-memory + on-disk log storage for incoming client logs
LOG_FILE_NAME = "server_logs.jsonl"
LOG_FILE_PATH = os.path.join(os.path.dirname(__file__), LOG_FILE_NAME)
received_logs: List[Dict[str, Any]] = []

def append_log_record(record: Dict[str, Any]):
    try:
        received_logs.append(record)
        # Persist as newline-delimited JSON for easy inspection
        with open(LOG_FILE_PATH, "a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception as e:
        print(f"[LOG] Failed to persist log: {type(e).__name__}: {e}")

# Sensor data storage
SENSOR_FILE_NAME = "server_sensor_data.jsonl"
SENSOR_FILE_PATH = os.path.join(os.path.dirname(__file__), SENSOR_FILE_NAME)
received_sensors: List[Dict[str, Any]] = []
MAX_SENSOR_RECORDS = 500

def append_sensor_record(record: Dict[str, Any]):
    try:
        received_sensors.append(record)
        # Keep only last 500 records in memory to avoid bloat
        if len(received_sensors) > MAX_SENSOR_RECORDS:
            received_sensors.pop(0)
        # Persist as newline-delimited JSON
        with open(SENSOR_FILE_PATH, "a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception as e:
        print(f"[SENSOR] Failed to persist sensor data: {type(e).__name__}: {e}")

async def broadcast_to_app_clients(payload_dict: Dict[str, Any]):
    """Broadcast a message to all connected app clients."""
    if not app_ws_clients:
        return
    
    payload_json = json.dumps(payload_dict, ensure_ascii=False)
    for ws in list(app_ws_clients):
        async def _safe_send(w: WebSocket, payload: str):
            try:
                await w.send_text(payload)
            except Exception:
                try:
                    app_ws_clients.remove(w)
                except ValueError:
                    pass
        
        asyncio.create_task(_safe_send(ws, payload_json))

def process_incoming_ws_text(text: str):
    try:
        payload = json.loads(text)
    except Exception:
        print(f"[WebSocket] ESP32 RX (raw): {text}")
        return

    t = payload.get("type")
    if t == MSG_TYPE_LOG:
        event = payload.get("event")
        timestamp = payload.get("timestamp")
        mode = payload.get("mode")
        meta = payload.get("meta", {})

        record = {
            "receivedAt": get_utc_iso_now(),
            "type": "log",
            "event": event,
            "clientTimestamp": timestamp,
            "mode": mode,
            "meta": meta,
        }
        append_log_record(record)

        # Broadcast the log record to connected app clients (realtime)
        if app_ws_clients:
            print(f"[BROADCAST] log -> {len(app_ws_clients)} app clients")
        asyncio.create_task(broadcast_to_app_clients(record))

        if event == EVENT_DEVICE_STATE_CHANGED:
            deviceId = meta.get("deviceId")
            deviceName = meta.get("deviceName")
            isOn = meta.get("isOn")
            trigger = meta.get("trigger")
            reason = meta.get("reason")
            changed = meta.get("changed")
            print(f"[LOG] device_state_changed - deviceId={deviceId}, deviceName={deviceName}, isOn={isOn}, trigger={trigger}, reason={reason}, changed={changed}, mode={mode}, clientTs={timestamp}")
        else:
            print(f"[LOG] Received log event '{event}': {payload}")
    
    elif t == MSG_TYPE_SENSOR:
        # Handle sensor data from ESP32
        pir = payload.get("pir")
        light = payload.get("light")
        gas = payload.get("gas")
        temperature = payload.get("temperature")
        humidity = payload.get("humidity")
        buzzer_active = payload.get("buzzerActive")

        record = {
            "receivedAt": get_utc_iso_now(),
            "type": "sensor_data",
            "pir": pir,
            "light": light,
            "gas": gas,
            "temperature": temperature,
            "humidity": humidity,
            "buzzerActive": buzzer_active,
        }
        append_sensor_record(record)
        # Broadcast sensor data to connected app clients in realtime
        if app_ws_clients:
            print(f"[BROADCAST] sensor_data -> {len(app_ws_clients)} app clients")
        asyncio.create_task(broadcast_to_app_clients(record))
        print(f"[SENSOR] PIR={pir} Light={light} Gas={gas} Temp={temperature} Humidity={humidity} Buzzer={buzzer_active}")
    
    else:
        print(f"[WebSocket] ESP32 RX: {text}")


def _udp_discovery_responder(bind_port: int = DISCOVERY_PORT):
    """Simple UDP responder for local discovery. Listens for the string
    'DISCOVER_SMARTHOME' and replies with a small JSON containing the
    WS URL to connect to. Runs in a background thread.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("", bind_port))
        print(f"[Discovery] UDP responder listening on port {bind_port}")

        while True:
            try:
                data, addr = sock.recvfrom(2048)
                if not data:
                    continue
                try:
                    msg = data.decode("utf-8").strip()
                except Exception:
                    continue

                if msg == EVENT_DISCOVER_SMARTHOME:
                    host_ip = addr[0]
                    payload = json.dumps({
                        "baseUrl": f"ws://{host_ip}:{FASTAPI_PORT}",
                        "wsPath": WS_ESP32_PATH,
                        "info": "smarthome-discovery",
                    })
                    try:
                        sock.sendto(payload.encode("utf-8"), addr)
                    except Exception:
                        pass
            except Exception:
                # keep responder alive
                continue
    finally:
        try:
            sock.close()
        except Exception:
            pass


class DeviceStateRequest(BaseModel):
    isOn: bool


def get_utc_iso_now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def create_device_json(device_id: str, name: str, device_type: str, is_on: bool):
    return {
        "id": device_id,
        "name": name,
        "type": device_type,
        "isOn": is_on,
        "updatedAt": get_utc_iso_now(),
    }


def get_devices():
    """Return the current devices list (internal helper). REST endpoints for devices
    are deprecated in this WS-only workflow for the app.
    """
    devices = [
        create_device_json("lamp-1", "Phong khach", DEVICE_TYPE_LIGHT, False),
        create_device_json("fan-1", "Quat", DEVICE_TYPE_FAN, False),
        create_device_json("lamp-bed1", "Phong ngu 1", DEVICE_TYPE_LIGHT, False),
        create_device_json("lamp-bed2", "Phong ngu 2", DEVICE_TYPE_LIGHT, False),
    ]

    for device in devices:
        device_cache["device_by_id"][device["id"]] = device

    return devices


async def send_command_to_esp32(device_id: str, is_on: bool):
    global esp32_ws_client
    if not esp32_ws_client:
        print(f"[WARNING] ESP32 not connected - command NOT sent for {device_id}")
        return

    try:
        command = {"action": ACTION_SET_STATE, "deviceId": device_id, "isOn": is_on}
        command_json = json.dumps(command)
        await esp32_ws_client.send_text(command_json)
    except Exception as error:
        print(f"[ERROR] Failed to send command: {type(error).__name__}: {error}")
        print(f"[TRACEBACK] {traceback.format_exc()}")
        # Mark as disconnected if send failed
        esp32_ws_client = None
        raise HTTPException(status_code=500, detail=str(error))


@app.get("/health")
async def health():
    return {"status": "ok", "uptimeSec": int(time.time())}





@app.websocket(WS_ESP32_PATH)
async def websocket_esp32(websocket: WebSocket):
    global esp32_ws_client
    await websocket.accept()
    esp32_ws_client = websocket
    print(f"[WebSocket] ESP32 connected from {websocket.client}")

    try:
        while True:
            # ESP32 is receive-only, just wait for connection to close
            # Client-side heartbeat handles keep-alive
            data = await websocket.receive_text()
            process_incoming_ws_text(data)
    except WebSocketDisconnect:
        print("[WebSocket] ESP32 disconnected gracefully")
        # Only clear if it's still OUR connection, not a newer reconnect
        if esp32_ws_client is websocket:
            esp32_ws_client = None
    except Exception as error:
        print(f"[WebSocket] ERROR: {type(error).__name__}: {error}")
        print(f"[TRACEBACK] {traceback.format_exc()}")
        if esp32_ws_client is websocket:
            esp32_ws_client = None


@app.websocket(WS_APP_PATH)
async def websocket_app(websocket: WebSocket):
    """WebSocket endpoint for client apps (Flutter). Multiple clients supported.
    The server will push realtime log and sensor records to connected apps.
    """
    await websocket.accept()
    app_ws_clients.append(websocket)
    print(f"[WebSocket] App client connected: {websocket.client}")

    try:
        # Send initial snapshot (devices + recent logs/sensors)
        try:
            devices = get_devices()
        except Exception:
            devices = []

        snapshot = {
            "type": MSG_TYPE_SNAPSHOT,
            "devices": devices,
            "logs": received_logs[-100:],
            "sensors": received_sensors[-100:],
        }
        try:
            await websocket.send_text(json.dumps(snapshot, ensure_ascii=False))
        except Exception:
            pass

        while True:
            msg = await websocket.receive_text()
            # Expect JSON messages with actions from app
            try:
                payload = json.loads(msg)
            except Exception:
                print(f"[WebSocket] App RX (non-json): {msg}")
                continue

            action = payload.get("action")
            request_id = payload.get("requestId")

            if action == ACTION_SET_STATE:
                device_id = payload.get("deviceId")
                is_on = payload.get("isOn")
                # Forward to ESP32 and ack back to app
                try:
                    await send_command_to_esp32(device_id, is_on)
                    # Build device object to return
                    device_obj = create_device_json(device_id, f"Device {device_id}", DEVICE_TYPE_UNKNOWN, bool(is_on))
                    ack = {"type": MSG_TYPE_ACK, "requestId": request_id, "status": "ok", "device": device_obj}
                    await websocket.send_text(json.dumps(ack, ensure_ascii=False))
                except Exception as e:
                    err = {"type": MSG_TYPE_ACK, "requestId": request_id, "status": "error", "error": str(e)}
                    try:
                        await websocket.send_text(json.dumps(err, ensure_ascii=False))
                    except Exception:
                        pass
            elif action == ACTION_GET_LOGS:
                limit = int(payload.get("limit", 100))
                resp = {"type": MSG_TYPE_LOGS_RESPONSE, "logs": received_logs[-limit:], "sensors": received_sensors[-limit:], "requestId": request_id}
                try:
                    await websocket.send_text(json.dumps(resp, ensure_ascii=False))
                except Exception:
                    pass
            else:
                print(f"[WebSocket] App RX unknown action: {payload}")
    except WebSocketDisconnect:
        print("[WebSocket] App client disconnected gracefully")
        try:
            app_ws_clients.remove(websocket)
        except ValueError:
            pass
    except Exception as error:
        print(f"[WebSocket] App ERROR: {type(error).__name__}: {error}")
        try:
            app_ws_clients.remove(websocket)
        except ValueError:
            pass


@app.on_event("startup")
async def on_startup():
    print(f"FastAPI running on http://localhost:{FASTAPI_PORT}")
    print(f"ESP32 WebSocket endpoint: ws://localhost:{FASTAPI_PORT}{WS_ESP32_PATH}")
    # Start UDP discovery responder in background thread for LAN discovery
    try:
        t = threading.Thread(target=_udp_discovery_responder, args=(DISCOVERY_PORT,), daemon=True)
        t.start()
    except Exception as e:
        print(f"[Discovery] Failed to start UDP responder: {e}")


if __name__ == "__main__":
    try:
        uvicorn.run(
            "main:app",
            host="0.0.0.0",
            port=FASTAPI_PORT,
            reload=False,
        )
    except (KeyboardInterrupt, SystemExit):
        # Graceful exit on Ctrl+C without printing full traceback
        print("[SERVER] Shutdown requested (KeyboardInterrupt). Exiting.")
    except Exception as e:
        # Unexpected exceptions should still surface for diagnostics
        print(f"[SERVER] Unhandled exception when running server: {type(e).__name__}: {e}")
        raise
