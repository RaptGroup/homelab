terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # State lives in the rockingham-homelab-tfstate bucket created by this
  # same root. Bucket name must be hardcoded — the backend block does not
  # accept variables. GCS provides native state locking via object
  # generations; no separate lock table needed.
  backend "gcs" {
    bucket = "rockingham-homelab-tfstate"
    prefix = "terraform/gcp"
  }
}
