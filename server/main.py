import asyncio
import json
import os
import tempfile
import time
import traceback
from datetime import datetime, timezone
from typing import Optional, List, Dict, Any

import torch
import uvicorn
import whisper
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, UploadFile, File, HTTPException
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

FASTAPI_PORT = int(os.getenv("FASTAPI_PORT", "5000"))
WHISPER_MODEL_NAME = os.getenv("WHISPER_MODEL", "small")

DEVICE_CACHE_TTL_SEC = 3

device_cache = {
    "devices": None,
    "cached_at": 0,
    "device_by_id": {},
}

esp32_ws_client: Optional[WebSocket] = None

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

def append_sensor_record(record: Dict[str, Any]):
    try:
        received_sensors.append(record)
        # Keep only last 500 records in memory to avoid bloat
        if len(received_sensors) > 500:
            received_sensors.pop(0)
        # Persist as newline-delimited JSON
        with open(SENSOR_FILE_PATH, "a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception as e:
        print(f"[SENSOR] Failed to persist sensor data: {type(e).__name__}: {e}")

def process_incoming_ws_text(text: str):
    try:
        payload = json.loads(text)
    except Exception:
        print(f"[WebSocket] ESP32 RX (raw): {text}")
        return

    t = payload.get("type")
    if t == "log":
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

        if event == "device_state_changed":
            deviceId = meta.get("deviceId")
            deviceName = meta.get("deviceName")
            isOn = meta.get("isOn")
            trigger = meta.get("trigger")
            reason = meta.get("reason")
            changed = meta.get("changed")
            print(f"[LOG] device_state_changed - deviceId={deviceId}, deviceName={deviceName}, isOn={isOn}, trigger={trigger}, reason={reason}, changed={changed}, mode={mode}, clientTs={timestamp}")
        else:
            print(f"[LOG] Received log event '{event}': {payload}")
    
    elif t == "sensor_data":
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
        print(f"[SENSOR] PIR={pir} Light={light} Gas={gas} Temp={temperature} Humidity={humidity} Buzzer={buzzer_active}")
    
    else:
        print(f"[WebSocket] ESP32 RX: {text}")


class DeviceStateRequest(BaseModel):
    isOn: bool


class TranscribeResponse(BaseModel):
    text: str


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


async def send_command_to_esp32(device_id: str, is_on: bool):
    global esp32_ws_client
    if not esp32_ws_client:
        print(f"[WARNING] ESP32 not connected - command NOT sent for {device_id}")
        return

    try:
        print(f"[DEBUG] esp32_ws_client type: {type(esp32_ws_client)}")
        print(f"[DEBUG] Sending command: device={device_id}, isOn={is_on}")
        command = {"action": "set_state", "deviceId": device_id, "isOn": is_on}
        command_json = json.dumps(command)
        print(f"[DEBUG] Command JSON: {command_json}")
        await esp32_ws_client.send_text(command_json)
        print(f"[DEBUG] Command sent successfully to ESP32")
    except Exception as error:
        print(f"[ERROR] Failed to send command: {type(error).__name__}: {error}")
        print(f"[TRACEBACK] {traceback.format_exc()}")
        # Mark as disconnected if send failed
        esp32_ws_client = None
        raise HTTPException(status_code=500, detail=str(error))


@app.get("/health")
async def health():
    return {"status": "ok", "uptimeSec": int(time.time())}


@app.get("/devices")
async def list_devices():
    # Always refresh to avoid stale cache
    devices = [
        create_device_json("lamp-1", "Phong khach", "light", False),
        create_device_json("fan-1", "Quat", "fan", False),
        create_device_json("lamp-bed1", "Phong ngu 1", "light", False),
        create_device_json("lamp-bed2", "Phong ngu 2", "light", False),
    ]

    for device in devices:
        device_cache["device_by_id"][device["id"]] = device

    return devices


@app.get("/devices/{device_id}")
async def get_device(device_id: str):
    now = time.time()
    cached = device_cache["device_by_id"].get(device_id)
    if cached and (now - device_cache.get("cached_at", 0)) < DEVICE_CACHE_TTL_SEC:
        return cached

    all_devices = await list_devices()
    for device in all_devices:
        if device["id"] == device_id:
            return device

    raise HTTPException(status_code=404, detail="Device not found")


@app.post("/devices/{device_id}/state")
async def set_device_state(device_id: str, request: DeviceStateRequest):
    await send_command_to_esp32(device_id, request.isOn)

    device = create_device_json(device_id, f"Device {device_id}", "unknown", request.isOn)
    device_cache["device_by_id"][device_id] = device
    device_cache["cached_at"] = time.time()

    return device


@app.get("/logs")
async def get_logs(limit: int = 100):
    if limit <= 0:
        raise HTTPException(status_code=400, detail="limit must be positive")
    # Return both logs and sensor data
    logs_data = received_logs[-limit:] if received_logs else []
    sensors_data = received_sensors[-limit:] if received_sensors else []
    return {
        "logs": logs_data,
        "sensors": sensors_data,
    }


@app.get("/sensors")
async def get_sensors(limit: int = 100):
    if limit <= 0:
        raise HTTPException(status_code=400, detail="limit must be positive")
    return received_sensors[-limit:] if received_sensors else []


@app.post("/transcribe")
async def transcribe(file: UploadFile = File(...)):
    if not file.filename or not file.filename.endswith((".wav", ".mp3", ".m4a", ".flac")):
        raise HTTPException(status_code=400, detail="Unsupported audio format")

    try:
        contents = await file.read()

        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            tmp.write(contents)
            tmp_path = tmp.name

        model = whisper.load_model(WHISPER_MODEL_NAME)
        result = model.transcribe(tmp_path, language='vi')
        os.unlink(tmp_path)

        return TranscribeResponse(text=result.get("text", ""))
    except Exception as error:
        raise HTTPException(status_code=500, detail=str(error))


@app.websocket("/ws/esp32")
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
        esp32_ws_client = None
    except Exception as error:
        print(f"[WebSocket] ERROR: {type(error).__name__}: {error}")
        print(f"[TRACEBACK] {traceback.format_exc()}")
        esp32_ws_client = None


@app.on_event("startup")
async def on_startup():
    print(f"FastAPI running on http://localhost:{FASTAPI_PORT}")
    print(f"ESP32 WebSocket endpoint: ws://localhost:{FASTAPI_PORT}/ws/esp32")
    print(f"Whisper model: {WHISPER_MODEL_NAME}")
    device = "CUDA" if torch.cuda.is_available() else "CPU"
    print(f"Using {device} for inference")


if __name__ == "__main__":
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=FASTAPI_PORT,
        reload=False,
    )
