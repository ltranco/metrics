#!/bin/bash
set -e

echo "=========================================="
echo "Deploying Life Metrics"
echo "=========================================="

REPO_DIR="/opt/metrics-repo"
APP_DIR="/opt/metrics"
DOMAIN="metrics.ltran.co"
EMAIL="linode@ltran.co"

# $APP_DIR and /opt/metrics-repo are created once by root and chowned to the
# deploy user -- its sudoers allowlist has no mkdir, and /opt is root-owned.
# Secrets are placed by hand once; never committed, never touched by CI.
if [ ! -f $APP_DIR/.env ]; then
    echo "ERROR: $APP_DIR/.env is missing. As root, one time:"
    echo "  mkdir -p $APP_DIR /opt/metrics-repo"
    echo "  chown deploy:deploy $APP_DIR /opt/metrics-repo"
    echo "  printf 'INGEST_TOKEN=%s\\n' \"\$(openssl rand -hex 24)\" > $APP_DIR/.env"
    echo "  chown deploy:deploy $APP_DIR/.env && chmod 600 $APP_DIR/.env"
    exit 1
fi

if [ ! -f /etc/nginx/.htpasswd-metrics ]; then
    echo "ERROR: /etc/nginx/.htpasswd-metrics is missing (basic auth for the read API)."
    echo "  sudo htpasswd -bc /etc/nginx/.htpasswd-metrics grafana '<password>'"
    exit 1
fi

echo "Deploying nginx config..."
sudo cp $REPO_DIR/deploy/nginx.conf /etc/nginx/sites-available/metrics
sudo ln -sf /etc/nginx/sites-available/metrics /etc/nginx/sites-enabled/

# Only issue the cert if it doesn't exist. Certbot's systemd timer handles
# renewal -- re-running --force-renewal on every deploy burns rate limits.
if [ ! -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem ]; then
    echo "Installing SSL certificate..."
    sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos --email $EMAIL --redirect
else
    echo "SSL certificate already exists"
fi

echo "Reloading nginx..."
sudo nginx -t
sudo systemctl reload nginx

echo "Deploying application..."
cp $REPO_DIR/deploy/docker-compose.prod.yml $APP_DIR/docker-compose.yml

cd $APP_DIR
export DOCKER_IMAGE=${DOCKER_IMAGE:-ghcr.io/$GITHUB_REPO:latest}

# No `down` -- compose recreates only what changed, so VictoriaMetrics keeps
# running and there's no gap in the series.
docker compose pull
docker compose up -d

echo "Waiting for shim..."
for i in $(seq 1 15); do
    if curl -fsS localhost:8081/healthz >/dev/null 2>&1; then
        echo "Shim healthy"
        break
    fi
    [ "$i" = 15 ] && { echo "ERROR: shim did not come up"; docker compose logs --tail=50 shim; exit 1; }
    sleep 2
done

echo "=========================================="
echo "Deployment complete!"
echo "=========================================="
docker compose ps
