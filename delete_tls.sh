: "${REGION:=us-central1}"
: "${ZONE:=us-central1-a}"
: "${PREFIX:=panw}"

# Check if the PROJECT_ID & ORG_ID environment variables are set.
if [ -z "$PROJECT_ID" ]; then
  echo "The PROJECT_ID environment variable is not set. Set with: "
  echo "export PROJECT_ID=YOUR_PROJECT_ID"
  exit 1  # Exit the script with a non-zero status code to indicate failure
fi

if [ -z "$ORG_ID" ]; then
  echo "The ORG_ID environment variable is not set. Set with: "
  echo "export ORG_ID=YOUR_ORGANIZATION_ID"
  exit 1  # Exit the script with a non-zero status code to indicate failure
fi

export PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="get(projectNumber)")


# Delete TLS policy.
gcloud network-security tls-inspection-policies delete $PREFIX-tls-policy \
    --project=$PROJECT_ID \
    --location=$REGION \
    --quiet


# Delete trust config.
gcloud certificate-manager trust-configs delete $PREFIX-trust-config \
    --project=$PROJECT_ID \
    --location=$REGION \
    --quiet


# Remove IAM policy from CA pool service account.
gcloud privateca pools remove-iam-policy-binding $PREFIX-ca-pool \
    --project=$PROJECT_ID \
    --location=$REGION \
    --role=roles/privateca.certificateRequester \
    --member=serviceAccount:service-$PROJECT_NUMBER@gcp-sa-networksecurity.iam.gserviceaccount.com

# Disable root CA (must be disabled before deleting).
gcloud privateca roots disable $PREFIX-ca-root \
    --project=$PROJECT_ID \
    --location=$REGION \
    --pool=$PREFIX-ca-pool \
    --ignore-dependent-resources \
    --quiet

# Delete CA root certificate.
gcloud privateca roots delete $PREFIX-ca-root \
    --project=$PROJECT_ID \
    --location=$REGION \
    --pool=$PREFIX-ca-pool \
    --skip-grace-period \
    --ignore-dependent-resources \
    --ignore-active-certificates \
    --quiet

# Delete CA pool in CAS.
gcloud privateca pools delete $PREFIX-ca-pool \
    --project=$PROJECT_ID \
    --location=$REGION \
    --quiet

# Files to delete
rm tls_policy.yaml
rm trust_config.yaml
rm key.pem
rm server.pem
rm local_ca_root.crt 
