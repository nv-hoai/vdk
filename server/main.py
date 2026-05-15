import asyncio
import json
import os
import tempfile
import time
import traceback
from datetime import datetime, timezone
from typing import Optional

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
            print(f"[WebSocket] ESP32 RX: {data}")
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
