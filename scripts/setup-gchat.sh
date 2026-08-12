#!/usr/bin/env bash
# Provision the GCP side of Leandro's Google Chat app (idempotent-ish:
# `already exists` errors are fine on re-run).
# Prereqs: gcloud auth login done; billing enabled on the project.
#   ./scripts/setup-gchat.sh <gcp-project-id>
# The Chat app itself (name, avatar, Pub/Sub topic wiring) has no gcloud API:
# finish in the console — the script prints the exact steps at the end.
set -euo pipefail

PROJECT="${1:?usage: setup-gchat.sh <gcp-project-id>}"
SA="hermes-chat-bot"
TOPIC="hermes-chat-events"
SUB="hermes-chat-events-sub"

gcloud config set project "$PROJECT"

gcloud services enable chat.googleapis.com pubsub.googleapis.com

gcloud iam service-accounts create "$SA" \
  --display-name "Hermes Google Chat bot (Leandro)" || true

gcloud pubsub topics create "$TOPIC" || true
gcloud pubsub subscriptions create "$SUB" \
  --topic "$TOPIC" \
  --message-retention-duration=7d || true

# Chat pushes events into the topic...
gcloud pubsub topics add-iam-policy-binding "$TOPIC" \
  --member="serviceAccount:chat-api-push@system.gserviceaccount.com" \
  --role="roles/pubsub.publisher"

# ...and Hermes pulls them from the subscription.
for role in roles/pubsub.subscriber roles/pubsub.viewer; do
  gcloud pubsub subscriptions add-iam-policy-binding "$SUB" \
    --member="serviceAccount:${SA}@${PROJECT}.iam.gserviceaccount.com" \
    --role="$role"
done

KEY_FILE="gchat-sa.json"
gcloud iam service-accounts keys create "$KEY_FILE" \
  --iam-account "${SA}@${PROJECT}.iam.gserviceaccount.com"

cat <<EOF

Done. Now:
1. scp $KEY_FILE leandro@<vm-ip>:/var/lib/leandro/gchat-sa.json
   ssh leandro@<vm-ip> chmod 600 /var/lib/leandro/gchat-sa.json
   rm $KEY_FILE   # do not leave the key on the host
2. Console (no API for this): console.cloud.google.com > APIs & Services >
   Google Chat API > Configuration:
   - App name "Leandro", description, avatar
   - Enable "Receive 1:1 messages"
   - Connection settings: Cloud Pub/Sub, topic projects/$PROJECT/topics/$TOPIC
   - Visibility: restrict to your workspace/account
3. Fill /var/lib/leandro/secrets.env in the VM:
   GOOGLE_CHAT_PROJECT_ID=$PROJECT
   GOOGLE_CHAT_SUBSCRIPTION_NAME=projects/$PROJECT/subscriptions/$SUB
   GOOGLE_CHAT_SERVICE_ACCOUNT_JSON=/var/lib/leandro/gchat-sa.json
   GOOGLE_CHAT_ALLOWED_USERS=<your email>
4. ssh leandro@<vm-ip> sudo systemctl restart hermes-gateway
EOF
