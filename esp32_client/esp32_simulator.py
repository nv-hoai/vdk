"""
ESP32 simulator for local testing
- Sends UDP discovery broadcast `DISCOVER_SMARTHOME` to port 5001
- Parses JSON reply {"baseUrl":"ws://<ip>:<port>", "wsPath":"/ws/esp32"}
- Connects to server WebSocket and mimics ESP32 behavior:
  - send init_state, periodic sensor_data, logs, acks
  - handle server actions: set_state, get_state, get_sensors, set_mode, open_door, close_door, buzzer_stop

Run:
    pip install websockets
    python esp32_simulator.py --discover

Options:
    --discover    Send UDP broadcast and use server reply (default)
    --ws WS_URI    Directly connect to this WebSocket URI (e.g. ws://192.168.1.10:5000/ws/esp32)
    --id ID        Device id to include in logs (default esp32-sim)
"""
import asyncio
import json
import random
import socket
import argparse
import time
from typing import Dict

import websockets

DISCOVERY_PORT = 5001
DISCOVERY_MSG = b"DISCOVER_SMARTHOME"
DISCOVERY_TIMEOUT = 2.0

SENSOR_INTERVAL = 2.0
RECONNECT_DELAY = 2.0

# Devices mirrored from firmware
DEVICES = [
    {"id": "lamp-1", "name": "Phong khach", "isOn": False},
    {"id": "fan-1", "name": "Quat", "isOn": False},
    {"id": "lamp-bed1", "name": "Phong ngu 1", "isOn": False},
    {"id": "lamp-bed2", "name": "Phong ngu 2", "isOn": False},
]

class ESP32Sim:
    def __init__(self, ws_uri: str, ident: str = "esp32-sim"):
        self.ws_uri = ws_uri
        self.id = ident
        self.devices: Dict[str, bool] = {d["id"]: d["isOn"] for d in DEVICES}
        self.mode = "AUTO"
        self.ws = None
        self.running = True

    async def connect_loop(self):
        while self.running:
            try:
                print(f"[SIM] Connecting to {self.ws_uri}")
                async with websockets.connect(self.ws_uri) as ws:
                    self.ws = ws
                    await self.on_connect()
                    consumer_task = asyncio.create_task(self.consumer())
                    producer_task = asyncio.create_task(self.producer())
                    done, pending = await asyncio.wait(
                        [consumer_task, producer_task], return_when=asyncio.FIRST_EXCEPTION
                    )
                    for t in pending: t.cancel()
            except Exception as e:
                print(f"[SIM] Connection error: {e}")
            print(f"[SIM] Reconnecting in {RECONNECT_DELAY}s...")
            await asyncio.sleep(RECONNECT_DELAY)

    async def on_connect(self):
        print("[SIM] Connected — sending init_state and a connected log")
        await self.send_all_states()
        await self.send_simple_log("esp32_connected", "ESP32 simulator online")

    async def consumer(self):
        assert self.ws
        async for msg in self.ws:
            await self.handle_message(msg)

    async def producer(self):
        # periodic sensor sending
        while True:
            await asyncio.sleep(SENSOR_INTERVAL)
            await self.send_sensor_data()

    async def handle_message(self, msg: str):
        print(f"[WS RX] {msg}")
        try:
            doc = json.loads(msg)
        except Exception:
            print("[SIM] Invalid JSON from server")
            return
        # handle actions similar to firmware
        typ = doc.get("type")
        if typ == "action" or "action" in doc:
            action = doc.get("action")
            if action == "set_state":
                deviceId = doc.get("deviceId")
                isOn = bool(doc.get("isOn", False))
                if deviceId in self.devices:
                    self.devices[deviceId] = isOn
                    await self.send_ack(deviceId, isOn)
                    meta = {"deviceId": deviceId, "isOn": isOn, "reason": "server_command"}
                    await self.send_event_log("device_state_changed", meta)
                    print(f"[SIM] set_state -> {deviceId} = {isOn}")
            elif action == "get_state":
                await self.send_all_states()
            elif action == "get_sensors":
                await self.send_sensor_data()
            elif action == "set_mode":
                mode = doc.get("mode")
                if mode in ("AUTO","MANUAL"):
                    self.mode = mode
                    await self.send_simple_log("mode_changed", f"Set to {mode}")
            elif action in ("open_door","close_door","buzzer_stop"):
                await self.send_simple_log(action, "performed by simulator")
            else:
                print(f"[SIM] Unknown action {action}")
        else:
            print("[SIM] Message has no action/type")

    async def send(self, payload: dict):
        if not self.ws:
            return
        text = json.dumps(payload)
        await self.ws.send(text)
        print(f"[WS TX] {text}")

    async def send_all_states(self):
        payload = {"type": "init_state", "devices": [{"id": k, "isOn": v} for k,v in self.devices.items()]}
        await self.send(payload)

    async def send_sensor_data(self):
        data = {
            "type": "sensor_data",
            "pir": random.choice([0,1]),
            "light": random.randint(0, 2000),
            "gas": random.randint(0, 400),
            "buzzerActive": False,
            "temperature": round(random.uniform(24.0, 36.0), 1),
            "humidity": round(random.uniform(30.0, 90.0), 1),
        }
        await self.send(data)

    async def send_event_log(self, event: str, meta: dict):
        payload = {"type":"log","event":event,"timestamp":int(time.time()*1000),"mode":self.mode,"meta":meta}
        await self.send(payload)

    async def send_simple_log(self, event: str, detail: str=""):
        payload = {"type":"log","event":event,"timestamp":int(time.time()*1000),"mode":self.mode}
        if detail:
            payload["detail"] = detail
        await self.send(payload)

    async def send_ack(self, deviceId: str, isOn: bool):
        payload = {"type":"ack","deviceId":deviceId,"isOn":isOn}
        await self.send(payload)


async def discover_server(timeout=DISCOVERY_TIMEOUT):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.settimeout(timeout)
    try:
        s.sendto(DISCOVERY_MSG, ("255.255.255.255", DISCOVERY_PORT))
        data, addr = s.recvfrom(1024)
        try:
            doc = json.loads(data.decode())
            base = doc.get("baseUrl")
            path = doc.get("wsPath") or "/ws/esp32"
            if path == "/ws/app":
                path = "/ws/esp32"
            if base:
                # base may be ws://host:port or ws://host
                # ensure scheme present
                if base.startswith("ws://") or base.startswith("wss://"):
                    # remove scheme
                    no_scheme = base.split("://",1)[1]
                else:
                    no_scheme = base
                if ":" in no_scheme:
                    host, port = no_scheme.rsplit(":",1)
                    uri = f"ws://{host}:{port}{path}"
                else:
                    uri = f"ws://{no_scheme}{path}"
                return uri
        except Exception:
            print("[DISC] Invalid discovery JSON")
    except socket.timeout:
        print("[DISC] No discovery reply")
    finally:
        s.close()
    return None


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--discover", action="store_true", default=False, help="Use UDP discovery")
    parser.add_argument("--ws", help="Direct WebSocket URI")
    parser.add_argument("--id", default="esp32-sim", help="Simulator id")
    args = parser.parse_args()

    ws_uri = args.ws
    if args.discover or (not ws_uri):
        print("[MAIN] Performing UDP discovery...")
        found = await discover_server()
        if found:
            ws_uri = found
            print(f"[MAIN] Discovered server: {ws_uri}")
        else:
            if not ws_uri:
                print("[MAIN] No server found via discovery and no --ws provided. Exiting.")
                return

    sim = ESP32Sim(ws_uri, ident=args.id)
    await sim.connect_loop()

if __name__ == '__main__':
    asyncio.run(main())
