FROM python:3.11-slim
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    OPENBLAS_NUM_THREADS=1
WORKDIR /app
COPY docker/ml-requirements.txt /tmp/ml-requirements.txt
RUN pip install --no-cache-dir -r /tmp/ml-requirements.txt
COPY ml/ ./ml/
COPY sql/11_ml_predictions.sql sql/12_ml_features.sql ./sql/
COPY tests/test_ml_features.py ./tests/test_ml_features.py
CMD ["python", "-m", "ml.train_and_score"]
