import os
import sys
import pathlib

# The app is imported as a top-level module inside the image (WORKDIR /app), so
# tests put app/ on the path the same way rather than inventing a package.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "app"))

os.environ.setdefault("COSMOS_URL", "https://example.documents.azure.com:443/")
os.environ.setdefault("COSMOS_DB", "notes")
os.environ.setdefault("COSMOS_CONTAINER", "notes")
