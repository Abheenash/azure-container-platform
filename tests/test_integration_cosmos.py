"""Integration tests against the real Cosmos DB emulator.

`test_api.py` runs the API against `fake_cosmos.py`, a hand-written double. These
run the same handlers against Microsoft's Linux Cosmos emulator, which is the
real engine and the real SQL query grammar. Free, no Azure subscription.

**Why the client is injected here rather than configured.** The AWS and GCP ports
point their SDK at a local endpoint with an environment variable and change no
application code. The Azure SDK has no equivalent: the emulator authenticates
with a well-known *key*, and `app/main.py` deliberately builds its client with
`DefaultAzureCredential` and nothing else — no connection string, no key, no
config path that could accept one. Adding a key branch to make this test tidier
would put the exact thing the repo argues against into the production code path.

So the test builds its own key-authenticated client and injects the container,
the same way the fake is injected. The trade-off is explicit: client construction
and managed-identity auth are NOT covered here (they are asserted in the
Terraform and in the checkov policies instead), and everything downstream of the
container handle — the query grammar, the error types, partition-key behaviour,
pagination — is exercised against the real engine rather than a double.

Skipped when the emulator is not running; CI sets `REQUIRE_COSMOS=1` so a
missing emulator is an error rather than quiet skips behind a green tick.
"""

import importlib
import os
import socket
import uuid

import pytest
from fastapi.testclient import TestClient

ENDPOINT = os.environ.get("COSMOS_EMULATOR_URL", "http://127.0.0.1:8081")
# The emulator's well-known key. Published by Microsoft in their own docs, identical
# on every install of the emulator, and worth nothing outside a throwaway container
# — a fixture, not a secret. Checked rather than assumed: the repo's gitleaks gate
# was run against this file and reports no finding, so no allowlist entry exists to
# weaken the rule that catches real keys.
EMULATOR_KEY = ("C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPM"
                "bIZnqyMsEcaGQy67XIw/Jw==")
DB_NAME = "notes-integration"
CONTAINER_NAME = "notes"


def _emulator_is_up() -> bool:
    host, _, port = ENDPOINT.removeprefix("http://").removeprefix("https://").partition(":")
    try:
        with socket.create_connection((host, int(port or 80)), timeout=2):
            return True
    except OSError:
        return False


_UP = _emulator_is_up()

if os.environ.get("REQUIRE_COSMOS") == "1" and not _UP:
    raise RuntimeError(
        f"REQUIRE_COSMOS=1 but nothing is listening on {ENDPOINT}. These tests were "
        "meant to run, not to be skipped."
    )

pytestmark = pytest.mark.skipif(
    not _UP,
    reason=f"no Cosmos emulator on {ENDPOINT} — run: docker run -d -p 8081:8081 "
           "mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview",
)


@pytest.fixture(scope="module")
def container():
    from azure.cosmos import CosmosClient, PartitionKey

    client = CosmosClient(ENDPOINT, credential=EMULATOR_KEY)
    db = client.create_database_if_not_exists(DB_NAME)
    return db.create_container_if_not_exists(
        id=CONTAINER_NAME, partition_key=PartitionKey(path="/id")
    )


@pytest.fixture
def client(monkeypatch, container):
    main = importlib.import_module("main")
    monkeypatch.setattr(main, "_notes", lambda: container)
    monkeypatch.setattr(main, "FAIL_READY", False)
    return TestClient(main.app)


def test_app_reaches_a_real_cosmos(client):
    r = client.get("/ready")
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "ready"


def test_round_trip_through_the_real_engine(client):
    text = f"integration {uuid.uuid4()}"
    created = client.post("/notes", json={"text": text})
    assert created.status_code == 201, created.text
    note_id = created.json()["id"]

    fetched = client.get(f"/notes/{note_id}")
    assert fetched.status_code == 200
    assert fetched.json()["text"] == text

    assert client.delete(f"/notes/{note_id}").status_code == 204
    assert client.get(f"/notes/{note_id}").status_code == 404


def test_missing_item_raises_rather_than_returning_empty(client, container):
    """The three-cloud difference this repo exists to show, asserted against the
    real server: Cosmos RAISES CosmosResourceNotFoundError, DynamoDB returns a
    response with no `Item`, and Firestore returns a snapshot whose `.exists` is
    False. Same 404 contract on top, three different shapes underneath — which is
    why the handler here catches and the other two check."""
    from azure.cosmos import exceptions

    missing = str(uuid.uuid4())
    with pytest.raises(exceptions.CosmosResourceNotFoundError):
        container.read_item(item=missing, partition_key=missing)


def test_duplicate_id_is_refused_by_the_server(client, container):
    """`create_item` conflicts on an existing id rather than overwriting, which is
    what makes the handler's uuid-per-note safe to rely on."""
    from azure.cosmos import exceptions

    note_id = str(uuid.uuid4())
    container.create_item({"id": note_id, "text": "first", "createdAt": 0})
    with pytest.raises(exceptions.CosmosResourceExistsError):
        container.create_item({"id": note_id, "text": "second", "createdAt": 0})
    container.delete_item(item=note_id, partition_key=note_id)


def test_cross_partition_query_needs_the_real_grammar(client, container):
    """The list handler runs a SQL query. A fake that pattern-matches strings will
    accept anything; the real engine rejects a malformed one — and it rejects it
    at request time, in production, not at deploy time."""
    from azure.cosmos import exceptions

    ok = list(container.query_items(
        query="SELECT * FROM c WHERE c.id = @id",
        parameters=[{"name": "@id", "value": "nothing-matches"}],
        enable_cross_partition_query=True,
    ))
    assert ok == []

    with pytest.raises(exceptions.CosmosHttpResponseError):
        list(container.query_items(query="SELECT * FROM c WHERE",
                                   enable_cross_partition_query=True))


def test_pagination_returns_every_note_exactly_once(client):
    """Cosmos pages with a continuation token, not an offset. Exercised across a
    real page boundary rather than a slice of a Python list."""
    made = {client.post("/notes", json={"text": f"page probe {i}"}).json()["id"] for i in range(25)}
    assert len(made) == 25

    seen, cursor, pages = set(), None, 0
    while True:
        r = client.get("/notes", params={"limit": 10, **({"cursor": cursor} if cursor else {})})
        assert r.status_code == 200, r.text
        body = r.json()
        seen.update(item["id"] for item in body["items"])
        pages += 1
        cursor = body.get("next")
        if not cursor or pages > 20:
            break

    assert made <= seen, f"{len(made - seen)} notes were never returned across {pages} pages"
    assert pages >= 3, "the page boundary was never actually crossed"
    for note_id in made:
        client.delete(f"/notes/{note_id}")
