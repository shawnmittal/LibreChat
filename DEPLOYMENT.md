# LibreChat Air-Gapped Deployment Guide

This guide covers deploying LibreChat with optional Keycloak SSO authentication to a Kubernetes cluster using Zarf. This package is designed for air-gapped environments where internet access is unavailable.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Package Contents](#package-contents)
- [Keycloak Requirements](#keycloak-requirements)
  - [Creating the LibreChat Client](#creating-the-librechat-client)
  - [Distributing the CA Certificate](#distributing-the-ca-certificate)
- [LibreChat Deployment](#librechat-deployment)
  - [Deploy with Zarf (Recommended)](#deploy-with-zarf-recommended)
  - [Deploy with Helm (Alternative)](#deploy-with-helm-alternative)
  - [Deployment Variables Reference](#deployment-variables-reference)
- [Client Machine Configuration](#client-machine-configuration)
- [Post-Deployment Verification](#post-deployment-verification)
- [Troubleshooting](#troubleshooting)
- [Next Steps: Ingress Configuration](#next-steps-ingress-configuration)

---

## Prerequisites

- Kubernetes cluster (k3s, RKE2, etc.) with:
  - At least one worker node with sufficient resources
  - Storage class configured for PersistentVolumeClaims
  - Network policies allowing pod-to-pod communication
- `kubectl` configured with cluster admin access
- `zarf` CLI v0.60.0+ installed (for Zarf deployment)
- `helm` CLI v3.x installed (for Helm deployment or troubleshooting)
- **Keycloak deployed with HTTPS** (if using SSO - see [Keycloak Requirements](#keycloak-requirements))
- vLLM or OpenAI-compatible API endpoint accessible from the cluster
- Ollama embedding service deployed (for RAG functionality)

---

## Package Contents

This deployment package includes:

```
├── zarf-package-librechat-amd64-0.1.0.tar.zst  # Zarf package (recommended)
├── helm/librechat/                              # Helm chart (alternative)
│   ├── Chart.yaml
│   ├── values.yaml                              # Default configuration
│   └── templates/
├── zarf-manifests/
│   └── postgres.yaml                            # PostgreSQL for RAG vector store
├── scripts/
│   └── create-credentials-secrets.sh            # Secret generation script
└── DEPLOYMENT.md                                # This file
```

**Container Images Included:**
- `ghcr.io/shawnmittal/librechat:auth-testing` - LibreChat application
- `ghcr.io/danny-avila/librechat-rag-api-dev-lite:latest` - RAG API
- `docker.io/bitnamilegacy/mongodb:latest` - MongoDB for chat history
- `docker.io/pgvector/pgvector:pg16` - PostgreSQL with pgvector for embeddings
- `getmeili/meilisearch:v1.7.3` - Search engine

---

## Keycloak Requirements

> **IMPORTANT:** Keycloak MUST be deployed with HTTPS (TLS). LibreChat's OpenID Connect implementation requires a secure issuer URL. HTTP-only Keycloak deployments will fail with OIDC errors.

This guide assumes Keycloak is already deployed to your cluster with:
- TLS certificates configured (via cert-manager or manually)
- Admin console accessible
- A known admin username and password

### Creating the LibreChat Client

1. **Access the Keycloak pod:**

   ```bash
   kubectl exec -it -n keycloak deploy/keycloak -- bash
   ```

2. **Authenticate with kcadm.sh:**

   ```bash
   # Inside the Keycloak pod
   /opt/keycloak/bin/kcadm.sh config credentials \
     --server http://localhost:8080 \
     --realm master \
     --user admin \
     --password <YOUR_ADMIN_PASSWORD>
   ```

3. **Create the `librechat` realm:**

   ```bash
   /opt/keycloak/bin/kcadm.sh create realms \
     -s realm=librechat \
     -s enabled=true \
     -s registrationAllowed=true
   ```

4. **Create the `librechat` client:**

   > **Note:** Replace `chat.local:30080` with your actual LibreChat URL. If using Ingress, this might be `chat.yourdomain.com` without a port.

   ```bash
   /opt/keycloak/bin/kcadm.sh create clients -r librechat \
     -s clientId=librechat \
     -s enabled=true \
     -s publicClient=false \
     -s 'redirectUris=["http://chat.local:30080/*"]' \
     -s 'webOrigins=["http://chat.local:30080"]' \
     -s standardFlowEnabled=true \
     -s directAccessGrantsEnabled=true
   ```

5. **Generate and retrieve the client secret:**

   ```bash
   # Get the client UUID
   CLIENT_UUID=$(/opt/keycloak/bin/kcadm.sh get clients -r librechat \
     -q clientId=librechat --fields id --format csv --noquotes)

   # Generate a new client secret
   /opt/keycloak/bin/kcadm.sh create clients/$CLIENT_UUID/client-secret -r librechat

   # Retrieve and display the secret
   /opt/keycloak/bin/kcadm.sh get clients/$CLIENT_UUID/client-secret -r librechat
   ```

   **Save this client secret** - you'll need it for the `KEYCLOAK_CLIENT_SECRET` variable.

6. **(Optional) Create a test user:**

   ```bash
   /opt/keycloak/bin/kcadm.sh create users -r librechat \
     -s username=testuser \
     -s email=test@example.com \
     -s enabled=true \
     -s emailVerified=true

   /opt/keycloak/bin/kcadm.sh set-password -r librechat \
     --username testuser \
     --new-password testpassword \
     --temporary
   ```

7. **Exit the pod:**

   ```bash
   exit
   ```

### Distributing the CA Certificate

LibreChat needs to trust the Keycloak TLS certificate. If using self-signed certificates or an internal CA, you must distribute the CA bundle:

1. **Extract the CA certificate from Keycloak's TLS secret:**

   ```bash
   kubectl get secret keycloak-tls-secret -n keycloak \
     -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/keycloak-ca.crt
   ```

   > **Note:** The secret name may vary. Check with `kubectl get secrets -n keycloak | grep tls`

2. **Create the CA bundle ConfigMap in the librechat namespace:**

   ```bash
   kubectl create namespace librechat --dry-run=client -o yaml | kubectl apply -f -
   
   kubectl create configmap keycloak-ca-bundle \
     -n librechat \
     --from-file=ca-certificates.crt=/tmp/keycloak-ca.crt
   ```

   > **Note:** If deploying with Zarf and `KEYCLOAK_ENABLED=true`, the credentials script will attempt to create this ConfigMap automatically by extracting the CA from `keycloak-tls-secret`.

3. **Clean up:**

   ```bash
   rm /tmp/keycloak-ca.crt
   ```

---

## LibreChat Deployment

### Deploy with Zarf (Recommended)

Zarf handles image injection into the cluster's internal registry, making it ideal for air-gapped environments.

#### Minimal Deployment (No Keycloak SSO)

```bash
zarf package deploy zarf-package-librechat-amd64-0.1.0.tar.zst --confirm \
  --set BASE_URL="http://vllm-gemma-12b.default.svc:8000/v1" \
  --set OPENAI_API_KEY="your-api-key" \
  --set MODEL_NAME="leon-se/gemma-3-12b-it-FP8-Dynamic"
```

#### Full Deployment (With Keycloak SSO)

```bash
zarf package deploy zarf-package-librechat-amd64-0.1.0.tar.zst --confirm \
  --set BASE_URL="http://vllm-gemma-12b.default.svc:8000/v1" \
  --set OPENAI_API_KEY="your-api-key" \
  --set MODEL_NAME="leon-se/gemma-3-12b-it-FP8-Dynamic" \
  --set OLLAMA_BASE_URL="http://ollama-embedding.default.svc:11434" \
  --set EMBEDDINGS_MODEL="nomic-embed-text" \
  --set RAG_CHUNK_SIZE="1500" \
  --set RAG_CHUNK_OVERLAP="100" \
  --set KEYCLOAK_ENABLED="true" \
  --set KEYCLOAK_ISSUER="https://keycloak.local:30443/realms/librechat" \
  --set KEYCLOAK_CLIENT_ID="librechat" \
  --set KEYCLOAK_CLIENT_SECRET="<your-client-secret>" \
  --set KEYCLOAK_NODE_IP="192.168.8.163" \
  --set DOMAIN_CLIENT="http://chat.local:30080" \
  --set DOMAIN_SERVER="http://chat.local:30080" \
  --set NODE_HOSTNAME="worker-1"
```

### Deploy with Helm (Alternative)

If Zarf is not available or you need more control, deploy directly with Helm:

1. **Create the namespace and secrets:**

   ```bash
   kubectl create namespace librechat
   
   # Create the credentials secret
   kubectl create secret generic librechat-credentials-env \
     -n librechat \
     --from-literal=OPENAI_API_KEY="your-api-key" \
     --from-literal=CREDS_KEY="$(openssl rand -hex 32)" \
     --from-literal=CREDS_IV="$(openssl rand -hex 16)" \
     --from-literal=JWT_SECRET="$(openssl rand -hex 32)" \
     --from-literal=JWT_REFRESH_SECRET="$(openssl rand -hex 32)" \
     --from-literal=MEILI_MASTER_KEY="$(openssl rand -hex 32)" \
     --from-literal=OPENID_CLIENT_SECRET="<your-keycloak-client-secret>" \
     --from-literal=OPENID_SESSION_SECRET="$(openssl rand -hex 32)"
   
   # Create the PostgreSQL secret
   kubectl create secret generic librechat-vectordb \
     -n librechat \
     --from-literal=postgres-password="$(openssl rand -hex 32)"
   ```

2. **Deploy PostgreSQL for the vector store:**

   ```bash
   kubectl apply -f zarf-manifests/postgres.yaml
   ```

3. **Create the Keycloak CA bundle (if using Keycloak):**

   Follow steps in [Distributing the CA Certificate](#distributing-the-ca-certificate).

4. **Install with Helm:**

   ```bash
   helm install librechat ./helm/librechat \
     -n librechat \
     --set keycloak.enabled=true \
     --set keycloak.issuer="https://keycloak.local:30443/realms/librechat" \
     --set keycloak.clientId="librechat" \
     --set keycloak.nodeIp="192.168.8.163" \
     --set librechat.configEnv.DOMAIN_CLIENT="http://chat.local:30080" \
     --set librechat.configEnv.DOMAIN_SERVER="http://chat.local:30080" \
     --set scheduling.nodeHostname="worker-1"
   ```

### Deployment Variables Reference

#### Required Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `BASE_URL` | OpenAI-compatible API endpoint URL | `http://vllm-gemma-12b.default.svc:8000/v1` |
| `OPENAI_API_KEY` | API key for the LLM service | `sk-xxx` or `dummy` for local models |
| `MODEL_NAME` | Model identifier used by the API | `leon-se/gemma-3-12b-it-FP8-Dynamic` |

#### Embedding & RAG Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `OLLAMA_BASE_URL` | `http://ollama-embedding.default.svc:11434` | Ollama service URL for embeddings |
| `EMBEDDINGS_MODEL` | `nomic-embed-text` | Embedding model name |
| `RAG_CHUNK_SIZE` | `1500` | Characters per chunk when splitting documents. Larger values provide more context but may exceed model limits. |
| `RAG_CHUNK_OVERLAP` | `100` | Character overlap between chunks. Higher values preserve more context at boundaries. |

#### Keycloak SSO Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `KEYCLOAK_ENABLED` | `false` | Set to `true` to enable Keycloak SSO |
| `KEYCLOAK_ISSUER` | - | Full OIDC issuer URL. **Must be HTTPS.** Example: `https://keycloak.local:30443/realms/librechat` |
| `KEYCLOAK_CLIENT_ID` | `librechat` | Client ID configured in Keycloak |
| `KEYCLOAK_CLIENT_SECRET` | - | Client secret from Keycloak (see [Creating the LibreChat Client](#creating-the-librechat-client)) |
| `KEYCLOAK_NODE_IP` | - | IP address of a cluster node. Used for hostAlias so LibreChat pod can resolve `keycloak.local`. Find with `kubectl get nodes -o wide` |
| `DOMAIN_CLIENT` | `http://localhost:3080` | Browser-accessible URL for LibreChat. Must match Keycloak redirect URI. |
| `DOMAIN_SERVER` | `http://localhost:3080` | Server URL for callbacks. Usually same as `DOMAIN_CLIENT`. |

#### Scheduling Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `NODE_HOSTNAME` | - | Kubernetes node hostname for pod scheduling. Leave empty for any node. Example: `worker-1` |

---

## Client Machine Configuration

Since this deployment uses NodePort services, you must configure client machines to resolve the custom hostnames.

### 1. Update /etc/hosts

Add the following entries to `/etc/hosts` on each machine that will access LibreChat:

```bash
# LibreChat and Keycloak (replace with your actual node IP)
192.168.8.163    chat.local
192.168.8.163    keycloak.local
```

**To find your node IP:**

```bash
kubectl get nodes -o wide
# Use the INTERNAL-IP of the node specified in NODE_HOSTNAME
```

### 2. Access the Services

| Service | URL | Notes |
|---------|-----|-------|
| LibreChat | http://chat.local:30080 | Main application |
| Keycloak Admin | https://keycloak.local:30443/admin | Realm management |

### Tailscale Users

If accessing via Tailscale, use your Tailscale IP:

```bash
# Get Tailscale IP of the node
tailscale ip -4

# Add to /etc/hosts on your local machine
100.x.x.x    chat.local
100.x.x.x    keycloak.local
```

---

## Post-Deployment Verification

### 1. Check Pod Status

```bash
kubectl get pods -n librechat
```

All pods should be `Running`:
- `librechat-librechat-xxx` - Main application
- `librechat-librechat-rag-api-xxx` - RAG API
- `librechat-mongodb-xxx` - MongoDB
- `librechat-meilisearch-0` - Search engine
- `librechat-postgresql-xxx` - Vector database

### 2. Check Logs for Errors

```bash
# LibreChat main application
kubectl logs -n librechat deploy/librechat-librechat --tail=50

# RAG API
kubectl logs -n librechat deploy/librechat-librechat-rag-api --tail=50
```

### 3. Verify RAG API Health

```bash
kubectl exec -n librechat deploy/librechat-librechat -- \
  curl -s http://librechat-librechat-rag-api:8000/health
```

### 4. Test Keycloak Connectivity (if enabled)

```bash
kubectl exec -n librechat deploy/librechat-librechat -- \
  curl -sk https://keycloak.local:30443/realms/librechat/.well-known/openid-configuration | head -5
```

---

## Troubleshooting

### LibreChat pod fails to start

**Symptom:** Pod stuck in `ContainerCreating` or `CrashLoopBackOff`

```bash
kubectl describe pod -n librechat -l app.kubernetes.io/name=librechat
kubectl logs -n librechat deploy/librechat-librechat --previous
```

**Common causes:**
- Missing secrets (`librechat-credentials-env`, `librechat-vectordb`)
- Missing ConfigMap (`keycloak-ca-bundle` when Keycloak is enabled)
- Image pull errors (check Zarf registry is accessible)

### Keycloak login redirects back to login page

**Symptom:** After authenticating with Keycloak, you're redirected back to the LibreChat login page instead of the chat interface.

**Cause:** Cookie security mismatch. LibreChat sets `secure: true` on cookies in production mode, but the app is accessed via HTTP.

**Solution:** This deployment sets `NODE_ENV=development` to allow HTTP cookies. Verify:

```bash
kubectl exec -n librechat deploy/librechat-librechat -- printenv NODE_ENV
# Should output: development
```

### "Unable to connect" when redirecting to Keycloak

**Symptom:** Clicking "Login with Keycloak" shows connection error.

**Causes & Solutions:**

1. **Keycloak hostname not resolvable from LibreChat pod:**
   
   ```bash
   kubectl exec -n librechat deploy/librechat-librechat -- cat /etc/hosts | grep keycloak
   # Should show: 192.168.8.163 keycloak.local
   ```
   
   If missing, verify `KEYCLOAK_NODE_IP` is set correctly.

2. **Wrong port in KEYCLOAK_ISSUER:**
   
   The issuer URL must use the externally-accessible port (NodePort), not the internal port.
   - Correct: `https://keycloak.local:30443/realms/librechat`
   - Wrong: `https://keycloak.local:8443/realms/librechat`

3. **Keycloak not using HTTPS:**
   
   LibreChat's OIDC implementation requires HTTPS. Verify Keycloak has TLS configured.

### RAG file upload fails

**Symptom:** File uploads fail or embeddings don't work.

1. **Check RAG API logs:**
   
   ```bash
   kubectl logs -n librechat deploy/librechat-librechat-rag-api --tail=100
   ```

2. **Verify Ollama connectivity:**
   
   ```bash
   kubectl exec -n librechat deploy/librechat-librechat-rag-api -- \
     curl -s http://ollama-embedding.default.svc:11434/api/tags
   ```

3. **Check PostgreSQL connectivity:**
   
   ```bash
   kubectl exec -n librechat deploy/librechat-librechat-rag-api -- \
     pg_isready -h librechat-postgresql -U postgres
   ```

### JWT_SECRET warning in RAG API logs

**Symptom:** RAG API logs show `JWT_SECRET not found in environment variables`

**Solution:** Ensure the RAG API has access to the credentials secret:

```bash
kubectl get deployment librechat-librechat-rag-api -n librechat -o yaml | grep -A5 existingSecret
```

Should show `existingSecret: librechat-credentials-env`. If not, upgrade the Helm release or redeploy.

---

## Next Steps: Ingress Configuration

The current deployment uses NodePort services, which requires:
- Manual `/etc/hosts` configuration on client machines
- Non-standard ports (30080, 30443)
- Direct node IP access

For production environments, consider deploying an Ingress controller.

### Benefits of Ingress

- Standard ports (80/443)
- Automatic TLS termination
- Single entry point for all services
- Easier DNS management
- Path-based routing

### Example Traefik Ingress Configuration

1. **Ensure Traefik is installed** (included with k3s by default):

   ```bash
   kubectl get pods -n kube-system | grep traefik
   ```

2. **Create LibreChat Ingress:**

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: librechat
     namespace: librechat
     annotations:
       traefik.ingress.kubernetes.io/router.entrypoints: web
   spec:
     rules:
       - host: chat.yourdomain.com
         http:
           paths:
             - path: /
               pathType: Prefix
               backend:
                 service:
                   name: librechat-librechat
                   port:
                     number: 3080
   ```

3. **Update Configuration:**

   When switching to Ingress, update these values:
   - `DOMAIN_CLIENT`: `http://chat.yourdomain.com` (no port)
   - `DOMAIN_SERVER`: `http://chat.yourdomain.com`
   - `KEYCLOAK_ISSUER`: Update if Keycloak also uses Ingress
   - Keycloak client redirect URIs in the Keycloak admin console

### DNS Alternatives

Instead of `/etc/hosts`, consider:

- **CoreDNS customization:** Add entries to cluster DNS
- **External DNS:** Automatic DNS record management
- **Local DNS server:** dnsmasq or Pi-hole for your network

---

## Support

For issues specific to this deployment package, contact your deployment team.

For LibreChat application issues, refer to:
- [LibreChat Documentation](https://docs.librechat.ai/)
- [LibreChat GitHub](https://github.com/danny-avila/LibreChat)
