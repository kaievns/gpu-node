"""
Gaming-node host agent. HTTP control plane on :8080.
Authenticates via Bearer token (loaded from /etc/gaming-agent/token).
The k8s gpu-node-controller pod talks to this; idle-check timer also.

Endpoints:
  GET  /status        — current mode, services state, GPU util/power
  POST /mode/compute  — stop gaming stack, apply compute profile
                        (gpu-profile v3.0: PL370 + boost lift + EXCLUSIVE_PROCESS)
  POST /mode/gaming   — apply gaming profile (PL370 + DEFAULT), start gaming stack
  POST /sleep         — systemctl suspend (idle-check uses this)
"""
import os, subprocess, time
from fastapi import FastAPI, HTTPException, Depends, Header

TOKEN_PATH = "/etc/gaming-agent/token"
with open(TOKEN_PATH) as f:
    EXPECTED_TOKEN = f.read().strip()

app = FastAPI(title="gaming-agent")

def require_token(authorization: str = Header(default="")):
    if not authorization.startswith("Bearer "):
        raise HTTPException(401, "missing/malformed Authorization header")
    if authorization[7:].strip() != EXPECTED_TOKEN:
        raise HTTPException(403, "bad token")
    return True

def run(cmd, timeout=60):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr.strip()

def svc_active(name):
    _, out, _ = run(f"/usr/bin/systemctl is-active {name}")
    return out

def nvidia_smi_query(field):
    _, out, _ = run(f"/usr/bin/nvidia-smi --query-gpu={field} --format=csv,noheader,nounits")
    return out

def current_mode():
    # Modes are distinguished by gamescope-headless service state, not by
    # compute_mode: chosen in v2.5 when both modes ran DEFAULT, and kept in
    # v2.9+ (EXCLUSIVE_PROCESS back in compute) because the service state is
    # the operative fact either way.
    cm = nvidia_smi_query("compute_mode")
    if svc_active("gamescope-headless") == "active":
        return "gaming", cm
    return "compute", cm

def streaming_active():
    # Sunshine logs "CLIENT CONNECTED" / "CLIENT DISCONNECTED" on stream
    # start/end. The most recent of these determines current state. If
    # neither has appeared in the last 30 lines (or sunshine isn't running),
    # nobody's streaming.
    if svc_active("sunshine") != "active":
        return False
    _, out, _ = run(
        "/usr/bin/journalctl -u sunshine -n 50 --no-pager 2>&1 "
        "| /usr/bin/grep -oE 'CLIENT (CONNECTED|DISCONNECTED)' | /usr/bin/tail -1"
    )
    return out == "CLIENT CONNECTED"

@app.get("/status")
def status(_=Depends(require_token)):
    mode, cmode_raw = current_mode()
    return {
        "mode": mode,
        "compute_mode": cmode_raw,
        "sunshine": svc_active("sunshine"),
        "gamescope_headless": svc_active("gamescope-headless"),
        "streaming_active": streaming_active(),
        "gpu_util_pct": int(nvidia_smi_query("utilization.gpu") or 0),
        "gpu_power_w": float(nvidia_smi_query("power.draw") or 0),
    }

@app.post("/mode/compute")
def mode_compute(_=Depends(require_token)):
    # Gating: if a Moonlight client is mid-stream, refuse the flip.
    # Killing the GPU here yanks NVENC out from under Sunshine and
    # crashes the running game. The controller should defer too, but
    # the agent is the authoritative gate.
    if streaming_active():
        raise HTTPException(409, "streaming client connected; refusing compute flip")
    # Stop gamescope-headless first; sunshine cascade-stops via BindsTo.
    # 60s timeout matches gamescope-headless.service TimeoutStopSec=20 drop-in
    # with margin. Without the drop-in, gamescope's default 90s SIGTERM wait
    # would blow past this timeout — keep both in sync.
    rc, _, err = run("/usr/bin/sudo /usr/bin/systemctl stop gamescope-headless.service", timeout=60)
    if rc != 0:
        raise HTTPException(500, f"stop gamescope-headless: {err}")
    # Defensive: also stop sunshine in case BindsTo timing slipped.
    run("/usr/bin/sudo /usr/bin/systemctl stop sunshine.service", timeout=30)
    time.sleep(2)
    # Flip GPU profile to compute (v3.0: PL370 + -lgc 0,2160 + EXCLUSIVE_PROCESS)
    rc, _, err = run("/usr/bin/sudo /usr/local/sbin/gpu-profile compute", timeout=30)
    if rc != 0:
        raise HTTPException(500, f"gpu-profile compute: {err}")
    # Verify
    mode, cmode_raw = current_mode()
    if mode != "compute":
        raise HTTPException(500, f"compute mode not set: {cmode_raw!r}")
    return {"status": "ok", "mode": "compute", "compute_mode": cmode_raw}

@app.post("/mode/gaming")
def mode_gaming(_=Depends(require_token)):
    # Set DEFAULT + PL370 BEFORE starting Sunshine (or NVENC probes EXCLUSIVE and falls back to libx264)
    rc, _, err = run("/usr/bin/sudo /usr/local/sbin/gpu-profile gaming", timeout=30)
    if rc != 0:
        raise HTTPException(500, f"gpu-profile gaming: {err}")
    # Start gamescope-headless (cascades sunshine via BindsTo + ExecStartPre wait-loop)
    rc, _, err = run("/usr/bin/sudo /usr/bin/systemctl start gamescope-headless.service", timeout=60)
    if rc != 0:
        raise HTTPException(500, f"start gamescope-headless: {err}")
    # Wait up to 30s for sunshine to come up (typical ~15s for ExecStartPre wait-loop)
    for _ in range(30):
        if svc_active("sunshine") == "active":
            break
        time.sleep(1)
    return {"status": "ok", "mode": "gaming",
            "sunshine": svc_active("sunshine"),
            "gamescope_headless": svc_active("gamescope-headless")}

@app.post("/sleep")
def do_sleep(_=Depends(require_token)):
    # Triggered by idle-check.timer. Box suspends (S3); services pause + resume on wake.
    rc, _, err = run("/usr/bin/sudo /usr/bin/systemctl suspend")
    if rc != 0:
        raise HTTPException(500, f"suspend: {err}")
    return {"status": "suspending"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080, log_level="info")
