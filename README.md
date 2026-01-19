# LibreChat Test Environment

> ⚠️ **FOR TESTING PURPOSES ONLY - NOT FOR PRODUCTION USE**

A lightweight AI chat frontend with basic RAG (Retrieval-Augmented Generation) capabilities, based on the [LibreChat](https://github.com/danny-avila/LibreChat) project. This fork has been modified for internal testing and evaluation of LLM deployments in air-gapped Kubernetes environments.

## Overview

This project provides:

- **Chat Interface** - Clean web UI for interacting with OpenAI-compatible LLM APIs
- **RAG Support** - Upload documents and query them using vector embeddings (pgvector + Ollama)
- **Keycloak SSO** - Optional single sign-on integration via OpenID Connect
- **Air-Gapped Deployment** - Packaged with Zarf for environments without internet access

## Quick Start

See [DEPLOYMENT.md](./DEPLOYMENT.md) for detailed deployment instructions.

### Prerequisites

- Kubernetes cluster (k3s, RKE2, etc.)
- vLLM or OpenAI-compatible API endpoint
- Ollama embedding service (for RAG)
- Keycloak with HTTPS (optional, for SSO)

### Deploy with Zarf

```bash
zarf package deploy zarf-package-librechat-amd64-0.1.0.tar.zst --confirm \
  --set BASE_URL="http://your-llm-api:8000/v1" \
  --set OPENAI_API_KEY="your-api-key" \
  --set MODEL_NAME="your-model-name"
```

## Features

| Feature | Status | Notes |
|---------|--------|-------|
| Chat Interface | ✅ | Multi-turn conversations with LLMs |
| File Upload (RAG) | ✅ | PDF, TXT, MD, and code files |
| Vector Search | ✅ | pgvector with Ollama embeddings |
| Keycloak SSO | ✅ | Optional OIDC authentication |
| Email/Password Auth | ✅ | Built-in user management |
| Conversation History | ✅ | MongoDB storage |
| Search | ✅ | Meilisearch integration |

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   LibreChat     │────▶│    vLLM/LLM     │     │    Keycloak     │
│   Frontend      │     │      API        │     │   (Optional)    │
└────────┬────────┘     └─────────────────┘     └─────────────────┘
         │
         │
┌────────▼────────┐     ┌─────────────────┐     ┌─────────────────┐
│    RAG API      │────▶│    Ollama       │     │    MongoDB      │
│                 │     │   Embeddings    │     │                 │
└────────┬────────┘     └─────────────────┘     └─────────────────┘
         │
         │
┌────────▼────────┐     ┌─────────────────┐
│   PostgreSQL    │     │   Meilisearch   │
│   (pgvector)    │     │                 │
└─────────────────┘     └─────────────────┘
```

## Configuration

### Zarf Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `BASE_URL` | LLM API endpoint | Required |
| `OPENAI_API_KEY` | API key for LLM | Required |
| `MODEL_NAME` | Model identifier | Required |
| `OLLAMA_BASE_URL` | Ollama embedding URL | `http://ollama-embedding.default.svc:11434` |
| `EMBEDDINGS_MODEL` | Embedding model | `nomic-embed-text` |
| `RAG_CHUNK_SIZE` | Document chunk size | `1500` |
| `RAG_CHUNK_OVERLAP` | Chunk overlap | `100` |
| `KEYCLOAK_ENABLED` | Enable SSO | `false` |
| `NODE_HOSTNAME` | K8s node for scheduling | Any |

See [DEPLOYMENT.md](./DEPLOYMENT.md) for complete variable reference.

## Limitations

This is a **test environment** with the following limitations:

- ❌ Not hardened for production security
- ❌ No high availability configuration
- ❌ Limited monitoring/observability
- ❌ No backup/restore procedures documented
- ❌ Performance not optimized for scale

## Directory Structure

```
├── helm/librechat/          # Helm chart
│   ├── templates/           # Kubernetes manifests
│   └── values.yaml          # Default configuration
├── scripts/                 # Deployment scripts
├── zarf-manifests/          # Additional K8s manifests
├── zarf.yaml                # Zarf package definition
└── DEPLOYMENT.md            # Deployment guide
```

## Development

### Building the Zarf Package

```bash
# Add Helm repos
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add meilisearch https://meilisearch.github.io/meilisearch-kubernetes
helm repo update

# Build package
zarf package create --confirm
```

### Local Helm Deployment

```bash
helm install librechat ./helm/librechat -n librechat --create-namespace
```

## Credits

This project is based on [LibreChat](https://github.com/danny-avila/LibreChat) by Danny Avila and contributors. Modified for internal testing purposes.

## License

MIT License - See [LICENSE](./LICENSE) for details.
