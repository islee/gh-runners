# Container image for the gh-runner-broker. The repo-root render.yaml deploys this on Render
# (runtime: docker, rootDir: broker); docker-compose.yml runs it on any other container host.
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

# Render/most PaaS inject $PORT; default 8000 locally. Shell form so $PORT expands.
ENV PORT=8000
CMD uvicorn app:app --host 0.0.0.0 --port ${PORT}
