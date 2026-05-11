FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY static/ ./static/

ENV APP_VERSION=1.0.0
ENV APP_COLOR=blue
ENV REDIS_HOST=localhost
ENV REDIS_PORT=6379

EXPOSE 5000

CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "--timeout", "30", "app:app"]
