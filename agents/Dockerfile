FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Default: run worker agent. Override with docker-compose command for verifier.
CMD ["python", "-m", "worker.main"]
