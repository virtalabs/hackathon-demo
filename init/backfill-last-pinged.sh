#!/usr/bin/env bash
# Runs on: host (repo root)
# Invoked by: init/integrate.sh
#
# Workaround B3: TapirXL ingest leaves Asset.last_pinged=NULL, but BlueFlow's
# Viper webhook filters with last_pinged__gte=since. See PLAYBOOK / BLUEFLOW_BUGS.md.
set -euo pipefail

echo "==> Backfilling Asset.last_pinged for Viper sync..."
docker compose exec -T blueflow uv run python project/manage.py shell -c "
from django.utils import timezone
from blueflow.models import Asset
n = Asset.objects.filter(last_pinged__isnull=True).update(last_pinged=timezone.now())
print(f'Backfilled last_pinged on {n} assets')
"
