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
# Create VPC network and subnets.
# ----------------------------------------------------------------------------------------------

gcloud compute networks create $PREFIX-vpc \
    --subnet-mode=custom \
    --quiet \
    --project=$PROJECT_ID

gcloud compute networks subnets create $PREFIX-subnet \
    --network=$PREFIX-vpc \
    --range=10.0.0.0/24 \
    --region=$REGION \
    --quiet \
    --project=$PROJECT_ID

gcloud compute firewall-rules create $PREFIX-all-ingress \
    --network=$PREFIX-vpc \
    --direction=ingress \
    --allow=all \
    --source-ranges=0.0.0.0/0 \
    --quiet \
    --project=$PROJECT_ID

# ----------------------------------------------------------------------------------------------
# Create workload VMs for simulating threats.
# ----------------------------------------------------------------------------------------------

gcloud compute instances create $PREFIX-attacker \
    --zone=$ZONE \
    --machine-type=f1-micro \
    --image-project=ubuntu-os-cloud \
    --image-family=ubuntu-2004-lts \
    --network-interface subnet=$PREFIX-subnet,private-network-ip=10.0.0.10 \
    --quiet \
    --project=$PROJECT_ID


gcloud compute instances create $PREFIX-victim \
    --zone=$ZONE\
    --machine-type=f1-micro \
    --image-project=panw-gcp-team-testing \
    --image=debian-cloud-ids-victim \
    --network-interface subnet=$PREFIX-subnet,private-network-ip=10.0.0.20 \
    --quiet \
    --project=$PROJECT_ID


# ----------------------------------------------------------------------------------------------
# Create Firewall Plus security profiles
# ----------------------------------------------------------------------------------------------

# Create security profile.
gcloud beta network-security security-profiles threat-prevention create $PREFIX-profile \
    --location=global \
    --project=$PROJECT_ID \
    --organization=$ORG_ID \
    --quiet

# Override default action for informational and low threats to ALERT.
gcloud beta network-security security-profiles threat-prevention add-override $PREFIX-profile \
    --severities=INFORMATIONAL,LOW \
    --action=ALERT \
    --location=global \
    --organization=$ORG_ID \
    --quiet \
    --project=$PROJECT_ID

# Override default action for medium, high, & critical threats to DENY.
gcloud beta network-security security-profiles threat-prevention add-override $PREFIX-profile \
    --severities=MEDIUM,HIGH,CRITICAL \
    --action=DENY \
    --location=global \
    --organization=$ORG_ID \
    --quiet \
    --project=$PROJECT_ID

# Create security profile group.
gcloud beta network-security security-profile-groups create $PREFIX-profile-group \
    --threat-prevention-profile "organizations/$ORG_ID/locations/global/securityProfiles/$PREFIX-profile" \
    --location=global \
    --project=$PROJECT_ID \
    --organization=$ORG_ID \
    --quiet

# ----------------------------------------------------------------------------------------------
# Create Firewall Plus endpoint
# ----------------------------------------------------------------------------------------------

# Create firewall endpoint. 
gcloud beta network-security firewall-endpoints create $PREFIX-endpoint \
    --zone=$ZONE \
    --billing-project=$PROJECT_ID \
    --organization=$ORG_ID \
    --quiet

# Wait for the firewall endpoint to be fully provisioned
while true; do
    STATUS_EP=$(gcloud beta network-security firewall-endpoints describe $PREFIX-endpoint \
        --zone=$ZONE \
        --project=$PROJECT_ID \
        --organization=$ORG_ID \
        --format="json" | jq -r '.state')
    if [[ "$STATUS_EP" == "ACTIVE" ]]; then
        echo "Firewall endpoint $PREFIX-endpoint is now active."
        sleep 30
        break
    fi
    echo "Waiting for the firewall endpoint to be created.  This can take up to 25 minutes..."
    sleep 1
done

# ----------------------------------------------------------------------------------------------
# Create Network Firewall policy, rules, and network association.
# ----------------------------------------------------------------------------------------------

# Create network firewall policy
gcloud compute network-firewall-policies create $PREFIX-global-policy \
    --global \
    --quiet \
    --project=$PROJECT_ID

# Create ingress network firewall rule
gcloud beta compute network-firewall-policies rules create 10 \
    --action=apply_security_profile_group \
    --security-profile-group=//networksecurity.googleapis.com/organizations/$ORG_ID/locations/global/securityProfileGroups/$PREFIX-profile-group \
    --firewall-policy=$PREFIX-global-policy \
    --global-firewall-policy \
    --direction=INGRESS \
    --enable-logging \
    --layer4-configs all \
    --src-ip-ranges=0.0.0.0/0 \
    --dest-ip-ranges=0.0.0.0/0 \
    --quiet \
    --project=$PROJECT_ID

# Create egress network firewall rule 
gcloud beta compute network-firewall-policies rules create 11 \
    --action=apply_security_profile_group \
    --security-profile-group=//networksecurity.googleapis.com/organizations/$ORG_ID/locations/global/securityProfileGroups/$PREFIX-profile-group \
    --firewall-policy=$PREFIX-global-policy \
    --global-firewall-policy \
    --layer4-configs=all \
    --direction=EGRESS \
    --enable-logging \
    --src-ip-ranges=0.0.0.0/0 \
    --dest-ip-ranges=0.0.0.0/0 \
    --quiet \
    --project=$PROJECT_ID


# Associate the firewall policy with the VPC network
gcloud compute network-firewall-policies associations create \
    --firewall-policy=$PREFIX-global-policy \
    --network=$PREFIX-vpc \
    --name=$PREFIX-global-policy-association \
    --quiet \
    --global-firewall-policy
    
# ----------------------------------------------------------------------------------------------
# Create Firewall Plus endpoint association with the VPC network
# ----------------------------------------------------------------------------------------------

# Create endpoint association
gcloud beta network-security firewall-endpoint-associations create $PREFIX-assoc \
    --endpoint "organizations/$ORG_ID/locations/$ZONE/firewallEndpoints/$PREFIX-endpoint" \
    --network=$PREFIX-vpc \
    --zone=$ZONE \
    --quiet \
    --project=$PROJECT_ID

# Wait for the endpoint association to complete before finishing.
while true; do
    STATUS_ASSOC=$(gcloud beta network-security firewall-endpoint-associations describe $PREFIX-assoc \
        --zone=$ZONE \
        --project=$PROJECT_ID \
        --format="json" | jq -r '.state')

    if [[ "$STATUS_ASSOC" == "ACTIVE" ]]; then
        echo "Endpoint association $PREFIX-assoc is now active."
        sleep 10
        break
    fi
    echo "Waiting for the endpoint association to be created.  This can take up to 45 minutes..."
    sleep 1
done

# ----------------------------------------------------------------------------------------------
# End of script
# ----------------------------------------------------------------------------------------------

echo "Script complete!"