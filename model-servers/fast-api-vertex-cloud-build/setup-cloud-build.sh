#!/bin/bash

# ============================================================
# Cloud Build Setup Script
# Run this once to prepare your GCP project for CI/CD.
# ============================================================

# === CONFIGURABLE VARIABLES (edit these) ===
PROJECT_ID="project3grupo1"
REGION="us-central1"
REPO_NAME="vertex-repo"
GITHUB_OWNER="nbenlloch-maker"
GITHUB_REPO="mlops-course-code-students2"

# ============================================================
# Step 1: Enable required GCP APIs
# ============================================================
echo "==> Enabling GCP APIs..."
gcloud services enable \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com \
    run.googleapis.com \
    --project="$PROJECT_ID"

# ============================================================
# Step 2: Create Artifact Registry Docker repository
# ============================================================
echo "==> Creating Artifact Registry repository '${REPO_NAME}'..."
gcloud artifacts repositories create "$REPO_NAME" \
    --repository-format=docker \
    --location="$REGION" \
    --project="$PROJECT_ID" \
    --description="Docker images for Vertex AI / Cloud Run" \
    2>/dev/null || echo "    (repository already exists, skipping)"

# ============================================================
# Step 3: Create a dedicated service account for Cloud Build
# ============================================================
CB_SA_NAME="cloud-build-deployer"
CB_SA_EMAIL="${CB_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "==> Creating service account '${CB_SA_NAME}'..."
gcloud iam service-accounts create "$CB_SA_NAME" \
    --display-name="Cloud Build CI/CD Service Account" \
    --project="$PROJECT_ID" \
    2>/dev/null || echo "    (service account already exists, skipping)"

echo "==> Granting roles to ${CB_SA_EMAIL}..."

ROLES=(
    "roles/run.admin"
    "roles/iam.serviceAccountUser"
    "roles/artifactregistry.writer"
    "roles/logging.logWriter"
)

for ROLE in "${ROLES[@]}"; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:${CB_SA_EMAIL}" \
        --role="$ROLE" \
        --condition=None \
        --quiet
done

# ============================================================
# Step 4: Connect GitHub repository (manual step)
# ============================================================
echo ""
echo "============================================================"
echo " MANUAL STEP: Connect your GitHub repository to Cloud Build"
echo "============================================================"
echo ""
echo " 1. Go to: https://console.cloud.google.com/cloud-build/triggers;region=${REGION}?project=${PROJECT_ID}"
echo " 2. Click 'CONNECT REPOSITORY' (1st gen)"
echo " 3. Select GitHub and authenticate"
echo " 4. Choose repository: ${GITHUB_OWNER}/${GITHUB_REPO}"
echo " 5. Complete the connection"
echo ""
read -p "Press Enter once the repository is connected..."

# ============================================================
# Step 5: Create CI trigger (Pull Requests)
# ============================================================
echo "==> Creating CI trigger (Pull Requests → lint + build)..."
gcloud builds triggers create github \
    --name="ci-lint-and-build" \
    --repo-name="$GITHUB_REPO" \
    --repo-owner="$GITHUB_OWNER" \
    --pull-request-pattern="^main$" \
    --comment-control=COMMENTS_DISABLED \
    --build-config="model-servers/fast-api-vertex-cloud-build/cloudbuild-ci.yaml" \
    --included-files="model-servers/fast-api-vertex-cloud-build/**" \
    --service-account="projects/${PROJECT_ID}/serviceAccounts/${CB_SA_EMAIL}" \
    --region="$REGION" \
    --project="$PROJECT_ID"

# ============================================================
# Step 6: Create CD trigger (Push to main)
# ============================================================
echo "==> Creating CD trigger (Push to main → build + push + deploy)..."
gcloud builds triggers create github \
    --name="cd-build-and-deploy" \
    --repo-name="$GITHUB_REPO" \
    --repo-owner="$GITHUB_OWNER" \
    --branch-pattern="^main$" \
    --build-config="model-servers/fast-api-vertex-cloud-build/cloudbuild-cd.yaml" \
    --included-files="model-servers/fast-api-vertex-cloud-build/**" \
    --service-account="projects/${PROJECT_ID}/serviceAccounts/${CB_SA_EMAIL}" \
    --region="$REGION" \
    --project="$PROJECT_ID"

echo ""
echo "==> Setup complete!"
echo "    CI trigger: runs on Pull Requests to main (lint + build)"
echo "    CD trigger: runs on Push to main (build + push + deploy)"
echo ""
echo "    Artifact Registry: ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}"
echo "    Cloud Run service will be created on first deploy."

# ============================================================
# TEARDOWN — run manually to remove all created resources
# Usage: bash setup-cloud-build.sh teardown
# ============================================================
SERVICE_NAME="fastapi-app-vertex"

teardown() {
    echo "==> WARNING: This will delete all resources created by this script."
    read -p "    Are you sure? (yes/no): " CONFIRM
    [[ "$CONFIRM" != "yes" ]] && echo "Aborted." && exit 0

    echo "==> Deleting Cloud Build triggers..."
    gcloud builds triggers delete "ci-lint-and-build" \
        --region="$REGION" --project="$PROJECT_ID" --quiet 2>/dev/null \
        || echo "    (ci-lint-and-build not found, skipping)"

    gcloud builds triggers delete "cd-build-and-deploy" \
        --region="$REGION" --project="$PROJECT_ID" --quiet 2>/dev/null \
        || echo "    (cd-build-and-deploy not found, skipping)"

    echo "==> Deleting Cloud Run service '${SERVICE_NAME}'..."
    gcloud run services delete "$SERVICE_NAME" \
        --region="$REGION" --project="$PROJECT_ID" --quiet 2>/dev/null \
        || echo "    (service not found, skipping)"

    echo "==> Deleting Artifact Registry repository '${REPO_NAME}'..."
    gcloud artifacts repositories delete "$REPO_NAME" \
        --location="$REGION" --project="$PROJECT_ID" --quiet 2>/dev/null \
        || echo "    (repository not found, skipping)"

    echo "==> Revoking IAM roles from service account '${CB_SA_EMAIL}'..."
    for ROLE in "roles/run.admin" "roles/iam.serviceAccountUser" "roles/artifactregistry.writer" "roles/logging.logWriter"; do
        gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
            --member="serviceAccount:${CB_SA_EMAIL}" \
            --role="$ROLE" \
            --quiet 2>/dev/null || true
    done

    echo "==> Deleting service account '${CB_SA_NAME}'..."
    gcloud iam service-accounts delete "$CB_SA_EMAIL" \
        --project="$PROJECT_ID" --quiet 2>/dev/null \
        || echo "    (service account not found, skipping)"

    echo ""
    echo "==> Teardown complete."
    echo "    Note: GCP APIs were NOT disabled. Disable manually if needed:"
    echo "    gcloud services disable cloudbuild.googleapis.com artifactregistry.googleapis.com run.googleapis.com --project=${PROJECT_ID}"
}

if [[ "${1:-}" == "teardown" ]]; then
    teardown
fi

# ============================================================
# LINTING EXAMPLES — copy and paste these commands manually
# ============================================================

# Check for lint errors
# uv run ruff check model-servers/fast-api-vertex-cloud-build/

# Auto-fix what ruff can fix automatically
# uv run ruff check --fix model-servers/fast-api-vertex-cloud-build/

# Check formatting (ruff also replaces black)
# uv run ruff format --check model-servers/fast-api-vertex-cloud-build/

# Apply formatting
# uv run ruff format model-servers/fast-api-vertex-cloud-build/