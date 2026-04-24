packer {
  required_plugins {
    docker = {
      version = ">= 1.0.8"
      source  = "github.com/hashicorp/docker"
    }
  }
}

source "docker" "nginx" {
  image  = "nginx:alpine"
  commit = true
  # On garde le changes pour d'éventuelles métadonnées, mais plus de COPY ici
  changes = [
    "LABEL built_by=packer"
  ]
}

build {
  sources = ["source.docker.nginx"]

  # Provisioner qui copie le fichier local dans le conteneur avant commit
  provisioner "file" {
    source      = "index.html"
    destination = "/usr/share/nginx/html/index.html"
  }
}