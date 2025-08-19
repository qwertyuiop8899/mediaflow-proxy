FROM python:3.13.5-slim

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE="1"
ENV PYTHONUNBUFFERED="1" \
    API_PASSWORD="mfp" \
    PYTHONDONTWRITEBYTECODE="1" \
    PYTHONFAULTHANDLER="1" \
    FORWARDED_ALLOW_IPS="*"

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

## Copy requirement spec first (only requirements.txt used in pip mode)
COPY requirements.txt /tmp/requirements.txt

## Install Python dependencies (pip only)
RUN pip install --no-cache-dir -r /tmp/requirements.txt \
 && rm /tmp/requirements.txt

## Copy project files (after deps)
COPY . /mediaflow_proxy

## Create non-root user after code present
RUN useradd -m mediaflow_proxy || true \
 && chown -R mediaflow_proxy:mediaflow_proxy /mediaflow_proxy
USER mediaflow_proxy

## Build-time dependency verification
RUN python - <<'PY'
import importlib, sys
mods=["fastapi","httpx","tenacity","xmltodict","pydantic_settings","gunicorn","uvicorn","tqdm","aiofiles","bs4","lxml","psutil","Crypto"]
missing=[]
for m in mods:
    try:
        importlib.import_module(m)
    except Exception as e:
        missing.append(f"{m}:{e}")
if missing:
    print('[build][ERROR] Missing modules:', ', '.join(missing))
    sys.exit(1)
print('[build] All runtime Python modules present')
PY

# Expose default port (platform may override PORT env at runtime)
EXPOSE 8888

## Copy start script and set executable (must be done as root to avoid permission issues on some builders)
USER root
COPY start /mediaflow_proxy/start
RUN chmod 755 /mediaflow_proxy/start && chown mediaflow_proxy:mediaflow_proxy /mediaflow_proxy/start
USER mediaflow_proxy

# Healthcheck (optional – attempts root path)
# NOTE: Must be a single line; previous multi-line broke parsing.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=5 CMD python -c "import os,sys,urllib.request;port=os.getenv('PORT','8888');url=f'http://127.0.0.1:{port}/health';\
    
try:\
    with urllib.request.urlopen(url,timeout=4) as r: sys.exit(0 if r.status<400 else 1)\
except Exception as e: sys.exit(1)" 2>/dev/null || exit 1

# Use dedicated start script; also copy a convenience symlink to /start for some PaaS
USER root
RUN ln -sf /mediaflow_proxy/start /start
USER mediaflow_proxy
ENTRYPOINT ["/mediaflow_proxy/start"]
