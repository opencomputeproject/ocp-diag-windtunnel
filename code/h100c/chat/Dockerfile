FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py index.html ./

# Port/host come from env so the launcher controls them (runs with --network host).
ENV CHAT_PORT=8080 CHAT_HOST=0.0.0.0
EXPOSE 8080

CMD ["sh", "-c", "uvicorn app:app --host ${CHAT_HOST} --port ${CHAT_PORT}"]
