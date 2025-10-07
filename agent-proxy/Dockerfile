FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

RUN pip install --no-cache-dir flask requests

COPY agent_proxy.py /app/agent_proxy.py

EXPOSE 6969

ENTRYPOINT ["python", "agent_proxy.py"]
