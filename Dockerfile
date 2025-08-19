FROM python:3.13.5-slim

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE="1"
ENV PYTHONUNBUFFERED="1" \
    PORT="8888" \
    API_PASSWORD="mfp" \
    PYTHONDONTWRITEBYTECODE="1"

## Install system dependencies required for building wheels (lxml, cryptography, etc.)
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        gcc \
        git \
        libxml2-dev \
        libxslt1-dev \
        zlib1g-dev \
        libffi-dev \
        libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Set work directory
WORKDIR /mediaflow_proxy

# Create a non-root user
RUN useradd -m mediaflow_proxy
RUN chown -R mediaflow_proxy:mediaflow_proxy /mediaflow_proxy

# Set up the PATH to include the user's local bin
ENV PATH="/home/mediaflow_proxy/.local/bin:$PATH"

ARG USE_POETRY=true
## Install Poetry only if requested (can skip to faster pip mode)
RUN if [ "$USE_POETRY" = "true" ]; then pip install --no-cache-dir poetry; fi
USER mediaflow_proxy

# Copy only requirements to cache them in docker layer
COPY --chown=mediaflow_proxy:mediaflow_proxy pyproject.toml poetry.lock* /mediaflow_proxy/

## Dependency installation
COPY --chown=mediaflow_proxy:mediaflow_proxy requirements.txt /mediaflow_proxy/requirements.txt
RUN bash -c '
if [ "$USE_POETRY" = "true" ]; then
    poetry config virtualenvs.in-project true && \
    poetry install --no-interaction --no-ansi --no-root --only main && \
    echo "[build] Poetry install completed"
else
    pip install --no-cache-dir -r requirements.txt && \
    python - <<PY
import importlib, sys
mods=["fastapi","httpx","tenacity","xmltodict","pydantic_settings","gunicorn","uvicorn","tqdm","aiofiles","bs4","lxml","psutil"]
missing=[m for m in mods if not importlib.util.find_spec(m)]
if missing:
    print("[build] Missing after pip install:", missing)
    sys.exit(1)
print("[build] All runtime Python modules present (pip)")
PY
fi
'

## Copy project files
COPY --chown=mediaflow_proxy:mediaflow_proxy . /mediaflow_proxy

## Build-time dependency verification (poetry variant)
RUN if [ "$USE_POETRY" = "true" ]; then \
    ./.venv/bin/python - <<'PY'
import importlib, sys
mods=['fastapi','httpx','tenacity','xmltodict','pydantic_settings','gunicorn','uvicorn','tqdm','aiofiles','bs4','lxml','psutil']
missing=[]
for m in mods:
    try:
        importlib.import_module(m)
    except Exception as e:
        missing.append(f"{m}:{e}")
if missing:
    print('[build][ERROR] Missing modules after poetry install:', ', '.join(missing))
    sys.exit(1)
print('[build] All runtime Python modules present (poetry)')
PY
    ; fi

# Expose the port the app runs on
EXPOSE 8888

# Copy start script (added later) and set executable
COPY --chown=mediaflow_proxy:mediaflow_proxy start /mediaflow_proxy/start
RUN chmod +x /mediaflow_proxy/start

# Healthcheck (optional – attempts root path)
# NOTE: Must be a single line; previous multi-line broke parsing.
HEALTHCHECK --interval=30s --timeout=5s --start-period=25s --retries=3 CMD python -c "import os,urllib.request;port=os.getenv('PORT','8888');urllib.request.urlopen(f'http://127.0.0.1:{port}/proxy').read();print('OK')" 2>/dev/null || exit 1

# Use dedicated start script; also copy a convenience symlink to /start for some PaaS
USER root
RUN ln -sf /mediaflow_proxy/start /start && chown mediaflow_proxy:mediaflow_proxy /start
USER mediaflow_proxy
ENTRYPOINT ["/mediaflow_proxy/start"]
