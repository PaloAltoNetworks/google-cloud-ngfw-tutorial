#!/bin/bash

# ----------------------------------------------------------------------------------------------
# Set default values for the deployment region, zone, and naming prefix
# ----------------------------------------------------------------------------------------------

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

# ----------------------------------------------------------------------------------------------
# Delete network firewall policy, rules, and network association.
# ----------------------------------------------------------------------------------------------

gcloud compute network-firewall-policies associations delete \
   --firewall-policy=$PREFIX-global-policy \
   --name=$PREFIX-global-policy-association \
   --global-firewall-policy

gcloud compute network-firewall-policies rules delete 10 \
   --firewall-policy=$PREFIX-global-policy \
   --global-firewall-policy \
   --project=$PROJECT_ID

gcloud compute network-firewall-policies rules delete 11 \
   --firewall-policy=$PREFIX-global-policy \
   --global-firewall-policy \
   --project=$PROJECT_ID

gcloud compute network-firewall-policies delete $PREFIX-global-policy \
   --global \
   --project=$PROJECT_ID


# ----------------------------------------------------------------------------------------------
# Delete Firewall Plus Endpoint, VPC assocation, & security profiles.
# ----------------------------------------------------------------------------------------------

gcloud beta network-security firewall-endpoint-associations delete $PREFIX-assoc \
  --project=$PROJECT_ID \
  --zone=$ZONE \
  --quiet

while true; do
    STATUS=$(gcloud beta network-security firewall-endpoint-associations describe $PREFIX-assoc \
        --zone=$ZONE \
        --project=$PROJECT_ID \
        --format="value(state)" 2>/dev/null)

    # Check if the association is not found (indicating it's fully deleted)
    if [ -z "$STATUS" ]; then
        echo "Successfully deleted endpoint association."
        sleep 60

        # Delete the firewall endpoint. 
        gcloud beta network-security firewall-endpoints delete $PREFIX-endpoint \
        --zone=$ZONE \
        --organization=$ORG_ID \
        --quiet

        # Delete the security profile group. 
        gcloud beta network-security security-profile-groups delete $PREFIX-profile-group \
        --location=global \
        --organization=$ORG_ID \
        --quiet

        # Delete the security profile.
        gcloud beta network-security security-profiles threat-prevention delete $PREFIX-profile \
        --location=global \
        --organization=$ORG_ID \
        --quiet
        break
    fi

    echo "Waiting for firewall endpoint association to delete.  This can take up to 15 minutes."
    sleep 10
done


# ----------------------------------------------------------------------------------------------
# Delete workload VMs
# ----------------------------------------------------------------------------------------------

gcloud compute instances delete $PREFIX-attacker \
   --zone=$ZONE \
   --project=$PROJECT_ID \
   --quiet

gcloud compute instances delete $PREFIX-victim \
   --zone=$ZONE \
   --project=$PROJECT_ID \
   --quiet


# ----------------------------------------------------------------------------------------------
# Delete VPC network
# ----------------------------------------------------------------------------------------------

gcloud compute firewall-rules delete $PREFIX-all-ingress \
   --project=$PROJECT_ID \
   --quiet

gcloud compute networks subnets delete $PREFIX-subnet \
   --region=$REGION \
   --project=$PROJECT_ID \
   --quiet

gcloud compute networks delete $PREFIX-vpc \
   --project=$PROJECT_ID \
   --quiet

# ----------------------------------------------------------------------------------------------
# End of script
# ----------------------------------------------------------------------------------------------

echo "Delete complete!"