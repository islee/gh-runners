# Portable image for the gh-runner-broker (Render can use this, or any container host).
# Render's native Python runtime (render.yaml) doesn't need this; it's here for non-Render hosting.
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

# Render/most PaaS inject $PORT; default 8000 locally. Shell form so $PORT expands.
ENV PORT=8000
CMD uvicorn app:app --host 0.0.0.0 --port ${PORT}
