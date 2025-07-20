FROM python:3.10-slim

# Install system dependencies for Node.js (required for Prisma CLI)
RUN apt-get update && apt-get install -y nodejs npm && apt-get clean

# Install Prisma CLI globally
RUN npm install -g prisma

# Install litellm[proxy] and prisma
RUN pip3 install --upgrade 'litellm[proxy]' prisma

# Copy Prisma schema
COPY prisma/schema.prisma /app/prisma/schema.prisma

# Run prisma generate to generate the client
RUN prisma generate --schema=/app/prisma/schema.prisma

# Set work directory
WORKDIR /app

# Expose 8000 port
EXPOSE 8000

# Entry point script to write secret to file
RUN echo '#!/bin/bash\n\
rm -rf /app/litellm-config.yaml\n\
echo "$LITELLM_CONFIG" > /app/litellm-config.yaml\n\
exec litellm --config /app/litellm-config.yaml --port 8000 --' > /app/entrypoint.sh && \
chmod +x /app/entrypoint.sh

# Run with entrypoint
ENTRYPOINT ["/app/entrypoint.sh"]