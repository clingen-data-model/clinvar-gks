# Use the official Google Cloud SDK image as a base. It includes gcloud.
FROM google/cloud-sdk:slim

# Switch to the root user to install packages
USER root

# Install jq using the package manager
RUN apt-get update && apt-get install -y jq

# Copy your script into the container
COPY process.sh /app/process.sh

# Make the script executable
RUN chmod +x /app/process.sh

# Set the entrypoint for the container. This command will run when the job starts.
ENTRYPOINT ["/app/process.sh"]