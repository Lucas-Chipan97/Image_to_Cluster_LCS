# Image to Cluster — Déploiement Nginx custom avec Packer, Ansible et K3d

## 1. Objectif du projet

Ce projet montre comment construire une image Docker personnalisée avec **Packer**, puis la déployer automatiquement dans un cluster Kubernetes local **K3d** à l'aide de **Ansible**.

L'application déployée est un simple serveur **Nginx** contenant une page `index.html` personnalisée avec un horodatage de build injecté dynamiquement.

---

## 2. Architecture de la solution

Le fonctionnement général est le suivant :

1. On travaille dans **GitHub Codespaces**.
2. **Packer** construit une image Docker personnalisée à partir de `nginx:alpine`.
3. L'image générée contient notre fichier `index.html` avec le `__BUILD_TIME__` injecté.
4. L'image est importée dans le cluster **K3d**.
5. **Ansible** déploie l'application dans Kubernetes via des templates Jinja2.
6. Le service est exposé et testé via `kubectl port-forward`.

---

## 3. Technologies utilisées

| Outil | Rôle |
|---|---|
| **GitHub Codespaces** | Environnement de développement cloud |
| **Docker** | Création et gestion des images |
| **Packer** | Automatisation de la construction de l'image Docker |
| **K3d** | Cluster Kubernetes local basé sur K3s dans Docker |
| **Kubernetes** | Orchestration des conteneurs |
| **Ansible** | Automatisation du déploiement Kubernetes |
| **Nginx** | Serveur web pour afficher la page HTML |

---

## 4. Structure du projet

```
.
├── packer/
│   ├── www/
│   │   └── index.html
│   └── nginx.pkr.hcl
├── ansible/
│   ├── k8s/
│   │   ├── deployment.yml.j2
│   │   └── service.yml.j2
│   ├── inventory.ini
│   └── deploy.yml
└── README.md
```

---

## 5. Guide d'exécution

### 5.1 Installation des prérequis

**Installer K3d**
```bash
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
```

**Installer Packer**
```bash
PACKER_VERSION=1.11.2
curl -fsSL -o /tmp/packer.zip \
  "https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_linux_amd64.zip"
sudo unzip -o /tmp/packer.zip -d /usr/local/bin
rm -f /tmp/packer.zip
```

**Installer Ansible + collection Kubernetes**
```bash
python3 -m pip install --user ansible kubernetes PyYAML jinja2
export PATH="$HOME/.local/bin:$PATH"
ansible-galaxy collection install kubernetes.core
```

---

### 5.2 Préparer l'arborescence

```bash
mkdir -p packer/www ansible/k8s
```

---

### 5.3 Packer — Build de l'image Nginx custom

**Créer le fichier `packer/www/index.html`**
```bash
cat > packer/www/index.html <<'EOF'
<!doctype html>
<html>
  <head><meta charset="utf-8"><title>Packer + K3d</title></head>
  <body>
    <h1>✅ Nginx déployé via Packer + Ansible sur K3d</h1>
    <p>Build time: __BUILD_TIME__</p>
  </body>
</html>
EOF
```

**Créer le template Packer `packer/nginx.pkr.hcl`**
```hcl
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
```

**Builder l'image**
```bash
cd packer
packer init .
packer fmt .
packer validate .
packer build .
```

---

### 5.4 Configuration du cluster K3d

**Créer le cluster**
```bash
k3d cluster create lab \
  --servers 1 \
  --agents 2
```

**Importer l'image dans le cluster**
```bash
k3d image import k3d-registry.localhost:5000/nginx-packer:1.0.0 -c lab
```

**Vérifier la connexion au cluster**
```bash
kubectl cluster-info
kubectl get nodes
```

---

### 5.5 Déploiement avec Ansible

**Créer le manifest Deployment `ansible/k8s/deployment.yml.j2`**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-packer
  labels:
    app: nginx-packer
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-packer
  template:
    metadata:
      namespace: {{ namespace }}
      labels:
        app: nginx-packer
    spec:
      containers:
        - name: nginx
          image: {{ image }}
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
```

**Créer le manifest Service `ansible/k8s/service.yml.j2`**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-packer-svc
  namespace: {{ namespace }}
spec:
  selector:
    app: nginx-packer
  ports:
    - port: 80
      targetPort: 80
```

**Créer l'inventory `ansible/inventory.ini`**
```ini
[local]
localhost ansible_connection=local
```

**Créer le playbook `ansible/deploy.yml`**
```yaml
- name: Deploy Nginx (Packer-built) to K3d via Ansible
  hosts: local
  gather_facts: false
  vars:
    namespace: demo
    image: "k3d-registry.localhost:5000/nginx-packer:1.0.0"

  tasks:
    - name: Ensure namespace exists
      kubernetes.core.k8s:
        state: present
        definition:
          apiVersion: v1
          kind: Namespace
          metadata:
            name: "{{ namespace }}"

    - name: Apply Deployment
      kubernetes.core.k8s:
        state: present
        namespace: "{{ namespace }}"
        definition: "{{ lookup('template', 'k8s/deployment.yml.j2') }}"

    - name: Apply Service
      kubernetes.core.k8s:
        state: present
        namespace: "{{ namespace }}"
        definition: "{{ lookup('template', 'k8s/service.yml.j2') }}"
```

**Lancer le déploiement**
```bash
cd ansible
ansible-playbook -i inventory.ini deploy.yml
cd ..
```

---

### 5.6 Vérification et accès à l'application

**Vérifier le déploiement**
```bash
kubectl -n demo get pods
kubectl -n demo get svc
kubectl -n demo get deployment
```

**Exposer le service localement**
```bash
kubectl -n demo port-forward svc/nginx-packer-svc 8080:80 >/tmp/web.log 2>&1 &
```

Le port `8080` est maintenant actif dans l'onglet **PORTS** de GitHub Codespaces. Vous pouvez lui donner une visibilité **Public** pour partager le lien à l'extérieur.

**Tester l'application**
```bash
curl http://localhost:8080
```

---

## 6. Résumé des commandes (ordre d'exécution)

```bash
# 1. Installation
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
python3 -m pip install --user ansible kubernetes PyYAML jinja2
ansible-galaxy collection install kubernetes.core

# 2. Build de l'image
cd packer && packer init . && packer build . && cd ..

# 3. Cluster K3d
k3d cluster create lab --servers 1 --agents 2
k3d image import k3d-registry.localhost:5000/nginx-packer:1.0.0 -c lab

# 4. Déploiement
cd ansible && ansible-playbook -i inventory.ini deploy.yml && cd ..

# 5. Vérification
kubectl -n demo get pods
kubectl -n demo get svc

# 6. Accès
kubectl -n demo port-forward svc/nginx-packer-svc 8080:80 &
curl http://localhost:8080
```

---

## 7. Nettoyage (optionnel)

```bash
# Supprimer les ressources Kubernetes
kubectl -n demo delete deployment nginx-packer
kubectl -n demo delete svc nginx-packer-svc

# Arrêter le cluster
k3d cluster stop lab

# Supprimer le cluster
k3d cluster delete lab

# Supprimer l'image Docker
docker rmi k3d-registry.localhost:5000/nginx-packer:1.0.0
```

---

## 8. Exercices

### Exercice 1 — HTML custom
Utiliser le code HTML source disponible sur [github.com/bstocker/Maison_SVG](https://github.com/bstocker/Maison_SVG), construire une image Docker avec Packer et déployer le service sur le cluster K3d via Ansible.

### Exercice 2 — Application Flask
Utiliser le code Flask source disponible sur [github.com/bstocker/Exercice_Docker_CV](https://github.com/bstocker/Exercice_Docker_CV), construire une image Docker avec Packer et déployer le service sur le cluster K3d via Ansible.
