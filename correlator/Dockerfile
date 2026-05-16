FROM python:3.12-slim
RUN pip install --no-cache-dir requests==2.32.3 prometheus_client==0.21.0
COPY correlator.py /correlator.py
EXPOSE 9100
CMD ["python", "-u", "/correlator.py"]
