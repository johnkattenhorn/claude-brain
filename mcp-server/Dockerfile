FROM python:3.12-slim

WORKDIR /app

# Install git (needed for brain-repo operations) and jq (needed by brain scripts)
RUN apt-get update && apt-get install -y --no-install-recommends git jq && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py .

# Brain repo and claude config are mounted as volumes
ENV BRAIN_REPO=/data/brain-repo
ENV CLAUDE_DIR=/data/claude
ENV CLAUDE_PLUGIN_ROOT=/app/plugin

EXPOSE 8080

CMD ["python", "server.py", "--http", "--port", "8080"]
