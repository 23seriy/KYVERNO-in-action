# Deliberately built as root by default so the "runs-as-root" bad-pod scenario
# is realistic. Individual k8s manifests under k8s/bad-pods/ override the
# securityContext to demonstrate specific policy violations.
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
EXPOSE 8080
CMD ["python", "app.py"]
