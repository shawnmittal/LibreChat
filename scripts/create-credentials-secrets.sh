#!/bin/bash

# --- 1. Define Cleanup Function ---
# This function will run automatically when the script exits for ANY reason
cleanup() {
  # Unset the sensitive credential variable immediately
  unset OPENAI_API_KEY
  unset KEYCLOAK_CLIENT_SECRET

  # Unset configuration variables
  unset TARGET_NAMESPACE
  unset TARGET_SECRET_NAME

  echo "Environment variables cleared."
}

# Register the cleanup function to run on EXIT (success or failure)
trap cleanup EXIT

# --- 2. Configuration ---
TARGET_NAMESPACE="librechat"
TARGET_SECRET_NAME="librechat-credentials-env"

# Keycloak settings (from environment or defaults)
KEYCLOAK_ENABLED="${KEYCLOAK_ENABLED:-false}"
KEYCLOAK_CLIENT_SECRET="${KEYCLOAK_CLIENT_SECRET:-}"

# OpenAI API Key (from environment)
OPENAI_API_KEY="${OPENAI_API_KEY:-}"

# --- 3. Validate API Key ---
if [ -z "$OPENAI_API_KEY" ]; then
  echo "Error: OPENAI_API_KEY not provided."
  exit 1
fi

# --- 4. Create Namespace ---
kubectl create namespace ${TARGET_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# --- 5. Create Combined Secret ---
echo "Creating ${TARGET_SECRET_NAME} in namespace ${TARGET_NAMESPACE}..."

# Build the secret command with base credentials
SECRET_ARGS=(
  "--from-literal=OPENAI_API_KEY=${OPENAI_API_KEY}"
  "--from-literal=CREDS_KEY=$(openssl rand -hex 32)"
  "--from-literal=CREDS_IV=$(openssl rand -hex 16)"
  "--from-literal=JWT_SECRET=$(openssl rand -hex 32)"
  "--from-literal=JWT_REFRESH_SECRET=$(openssl rand -hex 32)"
  "--from-literal=MEILI_MASTER_KEY=$(openssl rand -hex 32)"
)

# Add Keycloak secrets if enabled
if [ "$KEYCLOAK_ENABLED" = "true" ]; then
  echo "Keycloak SSO is enabled, adding OIDC secrets..."
  if [ -z "$KEYCLOAK_CLIENT_SECRET" ]; then
    echo "Warning: KEYCLOAK_CLIENT_SECRET not provided, generating random value"
    KEYCLOAK_CLIENT_SECRET="$(openssl rand -hex 32)"
  fi
  SECRET_ARGS+=("--from-literal=OPENID_CLIENT_SECRET=${KEYCLOAK_CLIENT_SECRET}")
  SECRET_ARGS+=("--from-literal=OPENID_SESSION_SECRET=$(openssl rand -hex 32)")
fi

kubectl create secret generic ${TARGET_SECRET_NAME} \
  -n ${TARGET_NAMESPACE} \
  "${SECRET_ARGS[@]}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Done! Secret '${TARGET_SECRET_NAME}' created successfully."

# --- 6. Create PG Vector Secret ---
echo "Creating librechat-vectordb in namespace ${TARGET_NAMESPACE}..."

kubectl create secret generic "librechat-vectordb" \
  -n ${TARGET_NAMESPACE} \
  --from-literal=postgres-password="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -

# --- 7. Create Keycloak CA Bundle ConfigMap (if Keycloak enabled) ---
if [ "$KEYCLOAK_ENABLED" = "true" ]; then
  echo "Creating keycloak-ca-bundle ConfigMap..."
  
  # Extract CA cert from Keycloak TLS secret
  CA_CERT=$(kubectl get secret keycloak-tls-secret -n keycloak -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d)
  
  if [ -n "$CA_CERT" ]; then
    kubectl create configmap keycloak-ca-bundle \
      -n ${TARGET_NAMESPACE} \
      --from-literal=ca-certificates.crt="$CA_CERT" \
      --dry-run=client -o yaml | kubectl apply -f -
    echo "Keycloak CA bundle created successfully."
  else
    echo "Warning: Could not extract CA cert from keycloak-tls-secret. You may need to create keycloak-ca-bundle manually."
  fi
  
  unset CA_CERT
fi

# The 'trap cleanup EXIT' will now trigger automatically