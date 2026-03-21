#!/bin/bash

# Set your GCP Project ID
export PROJECT_ID='clingen-dev'

# The name of the container image you built previously
export IMAGE_NAME="gcr.io/${PROJECT_ID}/vrs-to-vi-location-transformer"

# # Build the container image and push it to Artifact Registry
gcloud builds submit --tag "${IMAGE_NAME}"

# Deploy the job. This creates the job definition in Cloud Run.
gcloud run jobs deploy vrs-to-vi-location-transformer \
  --image "${IMAGE_NAME}" \
  --region us-east1  # IMPORTANT: Make sure this is the correct region