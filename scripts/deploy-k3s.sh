#!/bin/bash
#
# LibreChat Deployment Script for k3s
# This script creates necessary secrets, deploys PostgreSQL with pgvector, and deploys LibreChat via Helm
#

set -e

NAMESPACE="${NAMESPACE:-default}"
RELEASE_NAME="${RELEASE_NAME:-librechat}"
CHART_PATH="${CHART_PATH:-./helm/librechat}"

# Image configuration
IMAGE_REGISTRY="${IMAGE_REGISTRY:-ghcr.io}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-shawnmittal/librechat}"
IMAGE_TAG="${IMAGE_TAG:-security-banner}"
IMAGE_PULL_POLICY="${IMAGE_PULL_POLICY:-Always}"

# PostgreSQL configuration
POSTGRES_IMAGE="${POSTGRES_IMAGE:-pgvector/pgvector:pg16}"
POSTGRES_STORAGE_SIZE="${POSTGRES_STORAGE_SIZE:-10Gi}"

# Node affinity - schedule LibreChat pods on this node
NODE_SELECTOR_HOSTNAME="${NODE_SELECTOR_HOSTNAME:-worker-1}"

echo "=== LibreChat Deployment Script ==="
echo "Namespace: $NAMESPACE"
echo "Release: $RELEASE_NAME"
echo "Image: $IMAGE_REGISTRY/$IMAGE_REPOSITORY:$IMAGE_TAG"
echo "Node: $NODE_SELECTOR_HOSTNAME"
echo ""

# Function to generate random hex string
generate_hex() {
    openssl rand -hex "$1"
}

# Function to generate random base64 string
generate_base64() {
    openssl rand -base64 "$1" | tr -d '\n'
}

# Create librechat-credentials-env secret if it doesn't exist
create_credentials_secret() {
    local SECRET_NAME="librechat-credentials-env"
    
    if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
        echo "Secret '$SECRET_NAME' already exists, skipping creation."
    else
        echo "Creating secret '$SECRET_NAME'..."
        
        # Generate secure random values
        CREDS_KEY=$(generate_hex 32)
        CREDS_IV=$(generate_hex 16)
        JWT_SECRET=$(generate_hex 32)
        JWT_REFRESH_SECRET=$(generate_hex 32)
        MEILI_MASTER_KEY=$(generate_hex 32)
        
        kubectl create secret generic "$SECRET_NAME" \
            --from-literal=CREDS_KEY="$CREDS_KEY" \
            --from-literal=CREDS_IV="$CREDS_IV" \
            --from-literal=JWT_SECRET="$JWT_SECRET" \
            --from-literal=JWT_REFRESH_SECRET="$JWT_REFRESH_SECRET" \
            --from-literal=MEILI_MASTER_KEY="$MEILI_MASTER_KEY" \
            --from-literal=OPENAI_API_KEY="placeholder" \
            -n "$NAMESPACE"
        
        echo "Secret '$SECRET_NAME' created successfully."
    fi
}

# Create librechat-vectordb secret for PostgreSQL (RAG API)
create_vectordb_secret() {
    local SECRET_NAME="librechat-vectordb"
    
    if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
        echo "Secret '$SECRET_NAME' already exists, skipping creation."
        # Export the existing password for use in PostgreSQL deployment
        POSTGRES_PASSWORD=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.postgres-password}' | base64 -d)
    else
        echo "Creating secret '$SECRET_NAME'..."
        
        POSTGRES_PASSWORD=$(generate_base64 24)
        
        kubectl create secret generic "$SECRET_NAME" \
            --from-literal=postgres-password="$POSTGRES_PASSWORD" \
            -n "$NAMESPACE"
        
        echo "Secret '$SECRET_NAME' created successfully."
    fi
    
    export POSTGRES_PASSWORD
}

# Deploy PostgreSQL with pgvector
deploy_postgresql() {
    echo ""
    echo "Deploying PostgreSQL with pgvector..."
    
    # Check if PostgreSQL is already deployed
    if kubectl get deployment librechat-postgresql -n "$NAMESPACE" &>/dev/null; then
        echo "PostgreSQL deployment already exists, skipping creation."
        return
    fi
    
    # Create PVC for PostgreSQL
    cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: librechat-postgresql-pvc
  labels:
    app: librechat-postgresql
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${POSTGRES_STORAGE_SIZE}
EOF

    # Create PostgreSQL Deployment
    cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: librechat-postgresql
  labels:
    app: librechat-postgresql
spec:
  replicas: 1
  selector:
    matchLabels:
      app: librechat-postgresql
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: librechat-postgresql
    spec:
      nodeSelector:
        kubernetes.io/hostname: ${NODE_SELECTOR_HOSTNAME}
      containers:
        - name: postgresql
          image: ${POSTGRES_IMAGE}
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_DB
              value: "librechat-vectordb"
            - name: POSTGRES_USER
              value: "postgres"
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: librechat-vectordb
                  key: postgres-password
            - name: PGDATA
              value: "/var/lib/postgresql/data/pgdata"
          volumeMounts:
            - name: postgresql-data
              mountPath: /var/lib/postgresql/data
          resources:
            requests:
              memory: "256Mi"
              cpu: "250m"
            limits:
              memory: "1Gi"
              cpu: "1000m"
          livenessProbe:
            exec:
              command:
                - pg_isready
                - -U
                - postgres
                - -d
                - librechat-vectordb
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            exec:
              command:
                - pg_isready
                - -U
                - postgres
                - -d
                - librechat-vectordb
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: postgresql-data
          persistentVolumeClaim:
            claimName: librechat-postgresql-pvc
EOF

    # Create PostgreSQL Service
    cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: v1
kind: Service
metadata:
  name: librechat-postgresql
  labels:
    app: librechat-postgresql
spec:
  type: ClusterIP
  ports:
    - port: 5432
      targetPort: 5432
      protocol: TCP
      name: postgresql
  selector:
    app: librechat-postgresql
EOF

    echo "Waiting for PostgreSQL to be ready..."
    kubectl rollout status deployment/librechat-postgresql -n "$NAMESPACE" --timeout=300s
    
    # Wait a bit more for PostgreSQL to fully initialize
    echo "Waiting for PostgreSQL to initialize..."
    sleep 10
    
    echo "PostgreSQL deployed successfully."
}

# Deploy or upgrade LibreChat via Helm
deploy_librechat() {
    echo ""
    echo "Deploying LibreChat via Helm..."
    
    helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" \
        --set image.registry="$IMAGE_REGISTRY" \
        --set image.repository="$IMAGE_REPOSITORY" \
        --set image.tag="$IMAGE_TAG" \
        --set image.pullPolicy="$IMAGE_PULL_POLICY" \
        --set librechat-rag-api.rag.configEnv.POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
        -n "$NAMESPACE"
    
    echo ""
    echo "Waiting for deployment to complete..."
    kubectl rollout status deployment/"$RELEASE_NAME-librechat" -n "$NAMESPACE" --timeout=300s
}

# Main execution
main() {
    echo "Step 1: Creating secrets..."
    create_credentials_secret
    create_vectordb_secret
    
    echo ""
    echo "Step 2: Deploying PostgreSQL with pgvector..."
    deploy_postgresql
    
    echo ""
    echo "Step 3: Deploying LibreChat..."
    deploy_librechat
    
    echo ""
    echo "=== Deployment Complete ==="
    echo ""
    echo "To check the status:"
    echo "  kubectl get pods -n $NAMESPACE | grep librechat"
    echo ""
    echo "To view logs:"
    echo "  kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=librechat -f"
}

main "$@"
