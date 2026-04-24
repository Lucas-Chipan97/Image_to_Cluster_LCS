packer {
  required_plugins {
    docker = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/docker"
    }
  }
}

variable "repository" {
  type    = string
  default = "k3d-registry.localhost:5000/nginx-packer"
}

variable "tag" {
  type    = string
  default = "1.0.0"
}

source "docker" "nginx" {
  image  = "nginx:alpine"
  commit = true
}

build {
  sources = ["source.docker.nginx"]

  provisioner "shell" {
    inline = [
      "mkdir -p /usr/share/nginx/html",
      "date -Iseconds > /tmp/build_time.txt"
    ]
  }

  provisioner "file" {
    source      = "www/index.html"
    destination = "/usr/share/nginx/html/index.html"
  }

  provisioner "shell" {
    inline = [
      "BT=$(cat /tmp/build_time.txt)",
      "awk -v bt=\"$BT\" '{gsub(/__BUILD_TIME__/, bt)}1' /usr/share/nginx/html/index.html > /tmp/index.html && mv /tmp/index.html /usr/share/nginx/html/index.html"
    ]
  }

  post-processor "docker-tag" {
    repository = var.repository
    tags       = [var.tag]
  }
}
