FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
RUN useradd --uid 10001 --no-create-home app
USER 10001

EXPOSE 8080
# 1 proces (wspólny rejestr metryk prometheus_client), współbieżność przez wątki
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "--threads", "8", \
     "--access-logfile", "-", "app:create_app()"]
