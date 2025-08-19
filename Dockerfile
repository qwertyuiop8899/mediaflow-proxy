FROM python:3.13.5-slim

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE="1"
ENV PYTHONUNBUFFERED="1"
ENV PORT="8888"
ENV API_PASSWORD="mfp"

# Set work directory
WORKDIR /mediaflow_proxy

# Create a non-root user
RUN useradd -m mediaflow_proxy
RUN chown -R mediaflow_proxy:mediaflow_proxy /mediaflow_proxy

# Set up the PATH to include the user's local bin
ENV PATH="/home/mediaflow_proxy/.local/bin:$PATH"

# Switch to non-root user
USER mediaflow_proxy

# Install Poetry
RUN pip install --user --no-cache-dir poetry

# Copy only requirements to cache them in docker layer
COPY --chown=mediaflow_proxy:mediaflow_proxy pyproject.toml poetry.lock* /mediaflow_proxy/

# Project initialization:
RUN poetry config virtualenvs.in-project true \
    && poetry install --no-interaction --no-ansi --no-root --only main

# Copy project files
COPY --chown=mediaflow_proxy:mediaflow_proxy . /mediaflow_proxy

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
