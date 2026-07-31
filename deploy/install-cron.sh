#!/bin/bash
#
# Installs the nightly backup in root's crontab. Run once, as root:
#
#   bash /opt/metrics-repo/deploy/install-cron.sh
#
# Not part of deploy.sh: that runs as the `deploy` user, and the cron lives under root
# because the backup reads /var/lib/docker/volumes directly.
set -euo pipefail

ENTRY="0 3 * * * /opt/metrics-repo/deploy/backup.sh >> /var/log/metrics-backup.log 2>&1"

chmod +x /opt/metrics-repo/deploy/backup.sh

# Replace any previous entry rather than stacking duplicates.
(crontab -l 2>/dev/null | grep -v 'deploy/backup.sh'; echo "$ENTRY") | crontab -

echo "Installed. Current root crontab:"
crontab -l
