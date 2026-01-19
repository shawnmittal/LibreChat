#!/bin/bash

# --- 1. Define Cleanup Function ---
# This function will run automatically when the script exits for ANY reason
cleanup() {
  # Unset the sensitive credential variable immediately
  unset OPENAI_KEY_VALUE

  # Unset configuration variables
  unset TARGET_NAMESPACE
  unset TARGET_SECRET_NAME
  unset SOURCE_SECRET_NAME
  unset SOURCE_SECRET_NAMESPACE
  unset SOURCE_SECRET_KEY

  echo "Environment variables cleared."
}

# Register the cleanup function to run on EXIT (success or failure)
trap cleanup EXIT

# --- 2. Configuration ---
TARGET_NAMESPACE="librechat"
TARGET_SECRET_NAME="librechat-credentials-env"

# EXISTING secret details
SOURCE_SECRET_NAME="envoy-ai-gateway-goog-gemini-apikey"
SOURCE_SECRET_NAMESPACE="production"
SOURCE_SECRET_KEY="apiKey"

# --- 3. Retrieve and Decode ---
echo "Retrieving OpenAI API Key from ${SOURCE_SECRET_NAME}..."

OPENAI_KEY_VALUE=$(kubectl get secret ${SOURCE_SECRET_NAME} \
  -n ${SOURCE_SECRET_NAMESPACE} \
  -o jsonpath="{.data.${SOURCE_SECRET_KEY}}" | base64 -d)

# Validation: Ensure we actually got a key before proceeding
if [ -z "$OPENAI_KEY_VALUE" ]; then
  echo "Error: Could not retrieve API key. Check secret name and permissions."
  exit 1
fi

# --- 4. Create Namespace ---
kubectl create namespace ${TARGET_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# --- 5. Create Combined Secret ---
echo "Creating ${TARGET_SECRET_NAME} in namespace ${TARGET_NAMESPACE}..."

kubectl create secret generic ${TARGET_SECRET_NAME} \
  -n ${TARGET_NAMESPACE} \
  --from-literal=OPENAI_API_KEY="${OPENAI_KEY_VALUE}" \
  --from-literal=CREDS_KEY="$(openssl rand -hex 32)" \
  --from-literal=CREDS_IV="$(openssl rand -hex 16)" \
  --from-literal=JWT_SECRET="$(openssl rand -hex 32)" \
  --from-literal=JWT_REFRESH_SECRET="$(openssl rand -hex 32)" \
  --from-literal=MEILI_MASTER_KEY="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Done! Secret '${TARGET_SECRET_NAME}' created successfully."

# --- 6. Create PG Vector Secret ---
echo "Creating librechat-vectordb in namespace ${TARGET_NAMESPACE}..."

kubectl create secret generic "librechat-vectordb" \
  -n ${TARGET_NAMESPACE} \
  --from-literal=POSTGRES_PASSWORD="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -

# The 'trap cleanup EXIT' will now trigger automatically