FROM python:3.13.15-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir --requirement requirements.txt

COPY main.py ./
COPY data ./data

RUN chown -R 10001:10001 /app

USER 10001:10001

ENTRYPOINT ["python", "/app/main.py"]
CMD ["transform"]