#=================================VPC subnet nat ===============================

resource "google_compute_network" "vpc" {
  project                 = var.project
  name                    = var.vpc_name
  auto_create_subnetworks = false
  mtu                     = 1460
}
resource "google_compute_subnetwork" "subnet" {
  name                     = var.subnet_name
  ip_cidr_range            = var.subnet-cidr
  region                   = var.region
  network                  = var.vpc_name
  private_ip_google_access = true
  depends_on               = ["google_compute_network.vpc"]
}

resource "google_compute_router" "nat-router" {
  name    = "nat-router"
  region  = var.region
  network = google_compute_network.vpc.id
}
resource "google_compute_router_nat" "nat" {
  name                               = "my-router-nat"
  router                             = google_compute_router.nat-router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

#===============================FW rule=================================

resource "google_compute_firewall" "fw-rule1" {
  name       = "fw-rule1"
  network    = var.vpc_name
  depends_on = ["google_compute_network.vpc"]
  allow {
    protocol = "icmp"
  }
  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "fw-iap" {
  name       = "fw-iap"
  network    = var.vpc_name
  depends_on = ["google_compute_network.vpc"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["35.235.240.0/20"]
}
#================================service account=======================
resource "google_service_account" "vm-sa" {
  account_id   = "vm-sa-id"
  display_name = "vm-sa"
}
#=================================instace ==============================

resource "google_compute_instance" "vm1-private" {
  name         = var.instance_name
  machine_type = var.machine_type
  zone         = var.zone
  depends_on   = ["google_compute_subnetwork.subnet"]
  tags         = ["test"]
  service_account {
    email  = google_service_account.vm-sa.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  boot_disk {
    initialize_params {
      image = var.image
    }
  }

  network_interface {
    network    = var.vpc_name
    subnetwork = var.subnet_name
    #access_config {
    #}
  }
  metadata_startup_script = file("startupscript.sh")
  metadata = {
    enable-oslogin = "TRUE"
  }
}

#======================== unmanged instance group ===================
resource "google_compute_instance_group" "u_instance_group" {
  name              = var.instance_name
  instances = [google_compute_instance.vm1-private.self_link]
  zone              = var.zone

  named_port {
    name = "http"
    port = 90
  }

}
#========================IAM role and permission=====================
resource "google_project_iam_binding" "role_viewer_binding" {
  project = var.project
  role    = "roles/viewer"
  members = ["user:katkarvishalen99@gmail.com"]
}
resource "google_project_iam_binding" "service_account_user" {
  project = var.project
  role    = "roles/iam.serviceAccountUser"
  members = ["user:katkarvishalen99@gmail.com"]
}
resource "google_project_iam_binding" "os_login" {
  project = var.project
  role    = "roles/compute.osLogin"
  members = ["user:katkarvishalen99@gmail.com"]
}
resource "google_project_iam_binding" "role_monitoring_binding" {
  project = var.project
  role    = "roles/monitoring.metricWriter"
  members = ["serviceAccount:${google_service_account.vm-sa.email}"]
}

#=========================IAP user===================================
resource "google_iap_tunnel_instance_iam_binding" "iap_tunnel_user" {
  project  = var.project
  zone     = var.zone
  instance = var.instance_name
  role     = "roles/iap.tunnelResourceAccessor"
  members  = ["user:katkarvishalen99@gmail.com"]

  depends_on = [google_compute_instance_group.u_instance_group]
}

#====================== Health check================================

resource "google_compute_http_health_check" "health_check" {
  name               = "health-check"
  request_path       = "/"
  port               = 80
  check_interval_sec = 5
  timeout_sec        = 5
  healthy_threshold  = 2
  unhealthy_threshold = 2
}

#=====================Backend Pool================================

resource "google_compute_target_pool" "backend_pool" {
  name   = "backend-target-pool"
  region = var.region

  instances = [
    google_compute_instance.vm1-private.self_link
  ]

  health_checks = [
    google_compute_http_health_check.health_check.self_link
  ]
}

#=================Forwarding rule==============================

resource "google_compute_forwarding_rule" "forwarding_rule" {
  name        = "forwarding-rule"
  region      = var.region
  target      = google_compute_target_pool.backend_pool.self_link
  port_range  = "80"
  ip_protocol = "TCP"
  load_balancing_scheme = "EXTERNAL"
}

#==================Cloud Armor policy==========================

resource "google_compute_security_policy" "vpn_allow_policy" {
  name        = "vpn-allow-policy"
  description = "Allow traffic only from specific VPN IP"

  rule {
    priority    = 1000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["185.4.97.2/32"]
      }
    }
    action = "allow"
  }
  rule {
    priority    = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    action = "deny(403)"
    description = "Deny all other traffic"
  }
}


resource "google_compute_backend_service" "default" {
  name                  = "my-backend-service"
  protocol              = "HTTP"
  port_name             = "http"
  timeout_sec           = 10
  load_balancing_scheme = "EXTERNAL"

  backend {
    group = google_compute_instance_group.u_instance_group.self_link
  }
  security_policy = google_compute_security_policy.vpn_allow_policy.id
}




