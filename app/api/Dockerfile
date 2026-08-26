FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 8080

# Gunicorn in production mode; app.py's init_schema() also runs via
# a small wrapper so schema creation happens once on container start.
CMD ["sh", "-c", "python -c 'import app; app.init_schema()' && gunicorn -b 0.0.0.0:8080 -w 2 app:app"]
