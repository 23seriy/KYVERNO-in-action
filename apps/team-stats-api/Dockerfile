# Multi-stage build so the runtime image stays slim and root-free.
FROM python:3.12-slim AS builder
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim
RUN groupadd -r app && useradd -r -g app -u 10001 app
WORKDIR /app
COPY --from=builder /install /usr/local
COPY app.py .
USER 10001
EXPOSE 8080
CMD ["python", "app.py"]
