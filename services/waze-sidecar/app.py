"""
Waze sidecar — FastAPI service.

Endpoints:
  GET /waze?left=&right=&bottom=&top=   Returns { alerts: [...] }
  GET /health                            Returns session status
"""

import logging
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import JSONResponse

from browser import manager

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s — %(message)s",
)
log = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    await manager.start()
    yield
    # Browser cleanup on shutdown
    if manager._browser:
        await manager._browser.close()
    if manager._pw:
        await manager._pw.stop()


app = FastAPI(title="waze-sidecar", lifespan=lifespan)


@app.get("/waze")
async def get_alerts(
    left: float = Query(...),
    right: float = Query(...),
    bottom: float = Query(...),
    top: float = Query(...),
):
    try:
        data = await manager.fetch_alerts(left=left, right=right, bottom=bottom, top=top)
        alerts = data.get("alerts", [])
        # Normalize raw Waze field names to match the WazeAlert contract
        for a in alerts:
            if "uuid" not in a and "id" in a:
                a["uuid"] = a["id"]
        log.info("Returning %d alerts for bbox %.2f,%.2f,%.2f,%.2f", len(alerts), left, right, bottom, top)
        return JSONResponse({"alerts": alerts})
    except RuntimeError as exc:
        # Session expired + no IMAP configured → needs manual intervention
        raise HTTPException(status_code=503, detail=str(exc))
    except Exception as exc:
        log.exception("fetch_alerts failed")
        raise HTTPException(status_code=500, detail=str(exc))


@app.get("/health")
async def health():
    from pathlib import Path
    cookie_file = Path(os.getenv("COOKIE_FILE", "/data/waze_session.json"))
    return {
        "ready": manager._ready,
        "cookie_file_exists": cookie_file.exists(),
        "cookie_file_size": cookie_file.stat().st_size if cookie_file.exists() else 0,
    }
