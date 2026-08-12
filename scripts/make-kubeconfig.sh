#!/usr/bin/env bash
# Print a standalone read-only kubeconfig for the leandro ServiceAccount.
# Run with a kubeconfig that can read secrets in `default`:
#   ./scripts/make-kubeconfig.sh https://<api-server>:6443 > /tmp/leandro-kubeconfig
#   scp /tmp/leandro-kubeconfig leandro@<vm-ip>:/var/lib/leandro/kubeconfig
#   ssh leandro@<vm-ip> chmod 600 /var/lib/leandro/kubeconfig && rm /tmp/leandro-kubeconfig
set -euo pipefail

SERVER="${1:?usage: make-kubeconfig.sh https://<api-server>:6443}"

TOKEN=$(kubectl get secret leandro-token -n default -o jsonpath='{.data.token}' | base64 -d)
CA=$(kubectl get secret leandro-token -n default -o jsonpath='{.data.ca\.crt}')

cat <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: work
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA}
users:
  - name: leandro
    user:
      token: ${TOKEN}
contexts:
  - name: leandro@work
    context:
      cluster: work
      user: leandro
current-context: leandro@work
EOF
