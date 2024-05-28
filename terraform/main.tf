# -------------------------------------------------------------------------------------
# Provider 
# -------------------------------------------------------------------------------------

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.29"
    }
  }
}

provider "google" {
  project               = local.project_id
  region                = local.region
  user_project_override = true
  billing_project       = local.billing_project
}


# -------------------------------------------------------------------------------------
# Variables
# -------------------------------------------------------------------------------------

locals {
  org_id          = var.org_id
  project_id      = var.project_id
  billing_project = var.billing_project
  prefix          = var.prefix
  region          = var.region
  zone            = var.zone
  mgmt_allow_ips  = ["0.0.0.0/0"]
  subnet_cidr     = "10.0.0.0/24"
  attacker_ip     = "10.0.0.10"
  attacker_image  = "ubuntu-os-cloud/ubuntu-2004-lts"
  tls_inspect     = false
  client_ip       = "10.0.0.10"
  web_ip          = "10.0.0.20"
}


# -------------------------------------------------------------------------------------
# Create VPC network and Cloud NAT.
# -------------------------------------------------------------------------------------

resource "google_compute_network" "main" {
  name                    = "${local.prefix}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "main" {
  name          = "${local.prefix}-${local.region}-subnet"
  ip_cidr_range = local.subnet_cidr
  region        = local.region
  network       = google_compute_network.main.id
}


resource "google_compute_router" "main" {
  name    = "${local.prefix}-router"
  region  = local.region
  network = google_compute_network.main.id
}

resource "google_compute_router_nat" "main" {
  name                               = "${local.prefix}-nat"
  router                             = google_compute_router.main.name
  region                             = local.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# -------------------------------------------------------------------------------------
# Create web & client VMs
# -------------------------------------------------------------------------------------

resource "google_compute_instance" "client" {
  name                      = "${local.prefix}-client-vm"
  machine_type              = "f1-micro"
  zone                      = local.zone
  can_ip_forward            = false
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2004-lts"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main.id
    network_ip = local.client_ip
  }

  metadata = {
    serial-port-enable = true
  }


  metadata_startup_script = <<SCRIPT
    #! /bin/bash 
    apt-get update 
    apt-get install apache2-utils mtr iperf3 tcpdump -y
    SCRIPT

  service_account {
    scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }

  depends_on = [
    google_compute_router_nat.main
  ]
}

resource "google_compute_instance" "web" {
  name                      = "${local.prefix}-web-vm"
  machine_type              = "f1-micro"
  zone                      = local.zone
  can_ip_forward            = false
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2004-lts"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main.id
    network_ip = local.web_ip
  }

  metadata = {
    serial-port-enable = true
  }


  metadata_startup_script = <<SCRIPT
    #! /bin/bash 
    sudo apt-get update
    sudo apt-get install coreutils -y
    sudo apt-get install php -y
    sudo apt-get install apache2 tcpdump iperf3 -y 
    sudo a2ensite default-ssl 
    sudo a2enmod ssl 
    # Apache configuration:
    sudo rm -f /var/www/html/index.html
    sudo wget -O /var/www/html/index.php https://raw.githubusercontent.com/wwce/terraform/master/azure/transit_2fw_2spoke_common/scripts/showheaders.php 
    systemctl restart apache2
    SCRIPT

  service_account {
    scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }

  depends_on = [
    google_compute_router_nat.main
  ]
}


# -------------------------------------------------------------------------------------
# Create Cloud NGFW endpoint, assocation, and security profile.
# -------------------------------------------------------------------------------------

// Create NGFW endpoint
resource "google_network_security_firewall_endpoint" "main" {
  name               = "${local.prefix}-endpoint"
  parent             = "organizations/${local.org_id}"
  location           = local.zone
  billing_project_id = local.billing_project
}

// Associate NGFW endpoint with the VPC network.
resource "google_network_security_firewall_endpoint_association" "main" {
  name              = "${local.prefix}-assoc"
  parent            = "projects/${local.project_id}"
  location          = local.zone
  network           = google_compute_network.main.id
  firewall_endpoint = google_network_security_firewall_endpoint.main.id
}

// Create security profile with actions for each threat severity level.
resource "google_network_security_security_profile" "main" {
  name        = "${local.prefix}-profile"
  parent      = "organizations/${local.org_id}"
  description = "Custom threat prevention profile to block medium, high, & critical threats."
  type        = "THREAT_PREVENTION"

  threat_prevention_profile {
    severity_overrides {
      severity = "INFORMATIONAL"
      action   = "ALERT"
    }
    severity_overrides {
      severity = "LOW"
      action   = "ALERT"
    }
    severity_overrides {
      severity = "MEDIUM"
      action   = "ALERT"
    }

    severity_overrides {
      severity = "HIGH"
      action   = "ALERT"
    }

    severity_overrides {
      severity = "CRITICAL"
      action   = "ALERT"
    }
  }
}

// Add the security profile to a security profile group.
resource "google_network_security_security_profile_group" "main" {
  name                      = "${local.prefix}-profile-group"
  parent                    = "organizations/${local.org_id}"
  threat_prevention_profile = google_network_security_security_profile.main.id
}



# -------------------------------------------------------------------------------------
# Create global network firewall policy with NGFW inspection rules.
# -------------------------------------------------------------------------------------

// Create a global network firewall policy
resource "google_compute_network_firewall_policy" "main" {
  name        = "${local.prefix}-policy"
  description = "Global network firewall policy which uses Cloud NGFW inspection."
  project     = local.project_id
}

// Create an INGRESS firewall rule to inspect all traffic using the security profile group.
resource "google_compute_network_firewall_policy_rule" "ingress" {
  rule_name              = "${local.prefix}-ingress-rule"
  description            = "Inspect all ingress traffic with Cloud NGFW."
  direction              = "INGRESS"
  enable_logging         = true
  tls_inspect            = local.tls_inspect
  firewall_policy        = google_compute_network_firewall_policy.main.name
  priority               = 10
  action                 = "apply_security_profile_group"
  security_profile_group = google_network_security_security_profile_group.main.id
  match {
    src_ip_ranges  = ["0.0.0.0/0"]
    dest_ip_ranges = [local.subnet_cidr]

    layer4_configs {
      ip_protocol = "tcp"
      ports       = ["22", "80", "443"]
    }
  }
}

// Create an EGRESS firewall rule to inspect all traffic using the security profile group.
resource "google_compute_network_firewall_policy_rule" "egress" {
  rule_name              = "${local.prefix}-egress-rule"
  description            = "Inspect all egress traffic with Cloud NGFW."
  direction              = "EGRESS"
  enable_logging         = true
  tls_inspect            = local.tls_inspect
  firewall_policy        = google_compute_network_firewall_policy.main.name
  priority               = 11
  action                 = "apply_security_profile_group"
  security_profile_group = google_network_security_security_profile_group.main.id
  match {
    src_ip_ranges  = [local.subnet_cidr]
    dest_ip_ranges = ["0.0.0.0/0"]

    layer4_configs {
      ip_protocol = "all"
    }
  }
}

// Associate the global policy with the VPC network.
resource "google_compute_network_firewall_policy_association" "main" {
  name              = "${local.prefix}-policy-association"
  attachment_target = google_compute_network.main.id
  firewall_policy   = google_compute_network_firewall_policy.main.name
  project           = local.project_id
}
