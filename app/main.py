"""Minimal notes API — the Azure half of a two-cloud comparison.

This is a deliberate line-for-line port of the same API in
`secure-container-pipeline` (AWS: Fargate + DynamoDB). The routes, the status
codes, the log shape and the security headers are identical on purpose — the
only thing that changes is the cloud underneath, which is the whole point of
the exercise. See docs/aws-vs-azure.md.

GET  /health          liveness: the process is up (no Azure calls — never fails because a
                      dependency is down, which is what a liveness probe must not do)
GET  /ready           readiness: the Cosmos container is reachable (this is what Container
                      Apps' ingress health probe gates traffic on)
POST /notes           create a note
GET  /notes/{id}      fetch one
GET  /notes           list (paginated with a continuation token, bounded page size)
DELETE /notes/{id}    delete one
"""

import json
import logging
import os
import sys
import time
import uuid

from fastapi import FastAPI, HTTPException, Query, Request, Response
from pydantic import BaseModel, Field

COSMOS_URL = os.environ.get("COSMOS_URL", "")
COSMOS_DB = os.environ.get("COSMOS_DB", "notes")
COSMOS_CONTAINER = os.environ.get("COSMOS_CONTAINER", "notes")
MAX_TEXT = int(os.environ.get("MAX_TEXT", "4000"))
# Drill switch: a revision with FAIL_READY=1 reports not-ready while staying alive —
# the shape of a dependency outage — so Container Apps' revision rollback can be seen
# to fire. Mirrors the AWS side's CodeDeploy circuit-breaker drill.
FAIL_READY = os.environ.get("FAIL_READY", "") == "1"

app = FastAPI(title="azure-container-platform notes API", docs_url=None, redoc_url=None, openapi_url=None)

_log = logging.getLogger("notes")
_log.setLevel(logging.INFO)
_h = logging.StreamHandler(sys.stdout)
_h.setFormatter(logging.Formatter("%(message)s"))
_log.handlers = [_h]
_log.propagate = False

_container = None


def _notes():
    """Resolved lazily so the module imports (and /health answers) without Azure.

    DefaultAzureCredential picks up the Container App's user-assigned managed
    identity at runtime and a developer's az-cli login locally — there is no
    connection string and no key anywhere in the config. This is the direct
    counterpart of the AWS side's task role.
    """
    global _container
    if _container is None:
        from azure.cosmos import CosmosClient
        from azure.identity import DefaultAzureCredential

        client = CosmosClient(COSMOS_URL, credential=DefaultAzureCredential())
        _container = client.get_database_client(COSMOS_DB).get_container_client(COSMOS_CONTAINER)
    return _container


class NoteIn(BaseModel):
    text: str = Field(min_length=1, max_length=MAX_TEXT)


@app.middleware("http")
async def request_context(request: Request, call_next):
    t0 = time.time()
    # Container Apps' ingress sets Request-Id; the AWS side reads X-Amzn-Trace-Id.
    rid = request.headers.get("request-id") or request.headers.get("x-request-id") or str(uuid.uuid4())
    try:
        response = await call_next(request)
    except Exception:
        _log.info(json.dumps({"rid": rid, "method": request.method, "path": request.url.path,
                              "status": 500, "ms": round((time.time() - t0) * 1000, 1)}))
        raise
    response.headers["X-Request-Id"] = rid
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Cache-Control"] = "no-store"
    response.headers["Content-Security-Policy"] = "default-src 'none'"
    _log.info(json.dumps({"rid": rid, "method": request.method, "path": request.url.path,
                          "status": response.status_code, "ms": round((time.time() - t0) * 1000, 1)}))
    return response


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/ready")
def ready(response: Response):
    if FAIL_READY:
        response.status_code = 503
        return {"status": "not ready", "reason": "FAIL_READY drill flag"}
    try:
        _notes().read()  # cheap metadata read that proves the identity + network path
        return {"status": "ready", "container": COSMOS_CONTAINER}
    except Exception as e:
        response.status_code = 503
        return {"status": "not ready", "reason": type(e).__name__}


@app.post("/notes", status_code=201)
def create_note(note: NoteIn):
    item = {"id": str(uuid.uuid4()), "text": note.text, "createdAt": int(time.time())}
    _notes().create_item(body=item)
    return item


@app.get("/notes/{note_id}")
def get_note(note_id: str):
    from azure.cosmos import exceptions

    try:
        return _notes().read_item(item=note_id, partition_key=note_id)
    except exceptions.CosmosResourceNotFoundError as e:
        raise HTTPException(status_code=404, detail="note not found") from e


@app.delete("/notes/{note_id}", status_code=204)
def delete_note(note_id: str):
    from azure.cosmos import exceptions

    try:
        _notes().delete_item(item=note_id, partition_key=note_id)
    except exceptions.CosmosResourceNotFoundError as e:
        raise HTTPException(status_code=404, detail="note not found") from e
    return Response(status_code=204)


@app.get("/notes")
def list_notes(limit: int = Query(20, ge=1, le=100), cursor: str | None = None):
    pager = _notes().query_items(
        query="SELECT * FROM c",
        enable_cross_partition_query=True,
        max_item_count=limit,
    ).by_page(cursor)
    page = next(pager)
    items = list(page)
    return {"items": items, "next": pager.continuation_token}
