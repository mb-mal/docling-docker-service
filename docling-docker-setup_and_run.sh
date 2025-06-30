#!/bin/bash

# This script sets up and runs the Docling microservice in a Docker container.
# It creates the necessary Python and Docker files, builds the image,
# and starts the container.

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
readonly CONTAINER_NAME="docling-service"
readonly IMAGE_NAME="docling-fastapi"
readonly HOST_PORT=8080
readonly CONTAINER_PORT=8000

# Determine the directory of this script to locate project files correctly.
# The script expects to be in the project root, with 'main.py' and 'Dockerfile.fastapi'
# being created inside a 'docling' subdirectory.
PROJECT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
APP_DIR="$PROJECT_DIR/docling"

# --- Main Logic ---
echo "--- Starting Docling Microservice Setup ---"

# Ensure the app directory exists and navigate into it
mkdir -p "$APP_DIR"
cd "$APP_DIR"
echo "Working directory: $(pwd)"


echo ">>> Creating main.py..."
cat <<'EOF' > main.py
import uuid
from typing import Dict, Any, Optional

from fastapi import FastAPI, HTTPException, BackgroundTasks
from pydantic import BaseModel

from docling.document_converter import DocumentConverter

# --- Data Models ---

class Job(BaseModel):
    job_id: str
    status: str = "pending"
    result: Optional[Any] = None
    error: Optional[str] = None

class ConversionOptions(BaseModel):
    source: str
    page_range: Optional[tuple[int, int]] = None

# --- In-memory "database" ---

jobs: Dict[str, Job] = {}

# --- Background Task ---

def process_document(job_id: str, options: ConversionOptions):
    """The actual document processing function that runs in a background task."""
    try:
        jobs[job_id].status = "processing"
        converter = DocumentConverter()

        if options.page_range:
            result = converter.convert(source=options.source, page_range=options.page_range)
        else:
            result = converter.convert(source=options.source)

        jobs[job_id].result = result.document.export_to_markdown()
        jobs[job_id].status = "completed"

    except Exception as e:
        jobs[job_id].status = "failed"
        jobs[job_id].error = str(e)


# --- FastAPI App ---

app = FastAPI(
    title="Docling Microservice",
    description="A microservice to process documents using docling with a job queue.",
)

@app.post("/jobs", status_code=202, response_model=Job)
async def submit_job(options: ConversionOptions, background_tasks: BackgroundTasks):
    """Submit a document for processing."""
    job_id = str(uuid.uuid4())
    job = Job(job_id=job_id)
    jobs[job_id] = job
    background_tasks.add_task(process_document, job_id, options)
    return job

@app.get("/jobs/{job_id}", response_model=Job)
async def get_job_status(job_id: str):
    """Get the status of a processing job."""
    if job_id not in jobs:
        raise HTTPException(status_code=404, detail="Job not found")
    return jobs[job_id]

@app.get("/jobs/{job_id}/result")
async def get_job_result(job_id: str):
    """Get the result of a completed job."""
    if job_id not in jobs:
        raise HTTPException(status_code=404, detail="Job not found")

    job = jobs[job_id]

    if job.status == "pending" or job.status == "processing":
        raise HTTPException(status_code=202, detail="Job is still being processed.")

    if job.status == "failed":
        raise HTTPException(status_code=500, detail=f"Job failed: {job.error}")

    if job.status == "completed":
        return {"markdown_content": job.result}

    raise HTTPException(status_code=500, detail="Job in unknown state")

@app.get("/")
def read_root():
    return {"message": "Docling microservice with job queue is running."}
EOF
echo "main.py created successfully."


echo ">>> Creating Dockerfile.fastapi..."
cat <<'EOF' > Dockerfile.fastapi
# Use the official Python image.
FROM python:3.11-slim-bookworm

# Prevent python from writing pyc files
ENV PYTHONDONTWRITEBYTECODE=1
# Ensure python output is sent straight to the terminal
ENV PYTHONUNBUFFERED=1

# System dependencies
RUN apt-get update \
    && apt-get install -y libgl1 libglib2.0-0 curl wget git procps \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install docling with CPU support.
# For GPU support, replace 'cpu' with the appropriate CUDA version (e.g., 'cu118').
RUN pip install --no-cache-dir docling --extra-index-url https://download.pytorch.org/whl/cpu

# Install FastAPI, uvicorn and gunicorn
RUN pip install --no-cache-dir "fastapi[all]" "uvicorn[standard]" "gunicorn"

# Set home for HuggingFace models to a temporary directory
ENV HF_HOME=/tmp/
# Download models during the build process
RUN docling-tools models download

# Copy the application code
COPY main.py /app/main.py

# Set the working directory
WORKDIR /app

# Expose the port the app runs on
EXPOSE 8000

# Run the application with Gunicorn for robust process management
CMD ["gunicorn", "-w", "2", "-k", "uvicorn.workers.UvicornWorker", "main:app", "--bind", "0.0.0.0:8000"]
EOF
echo "Dockerfile.fastapi created successfully."


echo ">>> Stopping and removing existing container '$CONTAINER_NAME' if it exists..."
if [ "$(docker ps -q -f name=$CONTAINER_NAME)" ]; then
    docker stop "$CONTAINER_NAME"
fi
if [ "$(docker ps -aq -f status=exited -f name=$CONTAINER_NAME)" ]; then
    docker rm "$CONTAINER_NAME"
fi

echo ">>> Building Docker image '$IMAGE_NAME'..."
docker build -t "$IMAGE_NAME" -f Dockerfile.fastapi .

echo ">>> Starting new container '$CONTAINER_NAME'..."
docker run -d --rm --name "$CONTAINER_NAME" -p "$HOST_PORT:$CONTAINER_PORT" "$IMAGE_NAME"

echo ""
echo "--- ✅ Setup Complete ---"
echo "Service is running in the background as container '$CONTAINER_NAME'."
echo "Access the API at: http://localhost:$HOST_PORT"
echo ""
echo "To test the service, run:"
echo "  curl -s -X POST http://localhost:$HOST_PORT/jobs -H 'Content-Type: application/json' -d '{\"source\": \"https://arxiv.org/pdf/2206.01062\"}' | jq"
echo ""
echo "To view container logs, run:"
echo "  docker logs -f $CONTAINER_NAME"
echo ""
echo "To stop the service, run:"
echo "  docker stop $CONTAINER_NAME" 