"""Bind-mount overlay for `virtalabsinc/blueflow:demo-0.3.0` through `demo-0.3.1`.

This file REPLACES `/app/blueflow/celery/tasks.py` inside the BlueFlow
container (see `compose.yaml` blueflow.volumes). It works around two
upstream defects that block Phase 2 asset propagation to Viper:

    U4  ViperWebhookRequest is annotated `since: str` but DRF passes a
        `datetime`; `ViperWebhookResponse.to_dict()` returns it raw,
        causing `requests.post(json=...)` to raise
        `TypeError: Object of type datetime is not JSON serializable`.
        Verified still broken in `demo-0.3.1`. Tracked upstream as B4.

    U5  `ViperAsset` / `ViperWebhookResponse` use snake_case keys, a
        `vendor`/`model`/`udi`/`id` shape, and `status="active"`, none
        of which match Viper's `/api/v1/assets/integrationUpload/{token}`
        contract (camelCase, `ip` + `upstreamApi` + `vendorId` required,
        `status` enum is `Active|Decommissioned|Maintenance`).
        Verified still broken in `demo-0.3.1`. Tracked upstream as B5.

We bypass the broken model `to_dict()` methods and build the wire
payload directly from `Asset` rows in the shape Viper expects.

**This file is the canonical source of truth for the wire payload we
POST to Viper's `integrationUpload` endpoint.** Because the Viper-side
`integrationUpload` schema is still evolving, removal or update may be
required when Viper's contract settles — independent of when BlueFlow
ships a B4/B5 fix. Target for removal: `virtalabsinc/blueflow:demo-0.3.2+`
*and* a stable Viper `integrationUpload` schema. See PLAYBOOK §Failure modes.
"""

from __future__ import annotations

import logging
import math
from datetime import datetime
from typing import Any

import requests
from celery import Task as BaseTask
from django.apps import apps

from blueflow.celery import celery_app
from blueflow.models import ViperWebhookJob
from blueflow.models.viper import ViperWebhookRequest

logger = logging.getLogger(__name__)


class Task(BaseTask):
    max_retries = 5
    retry_backoff = True
    retry_backoff_max = 60
    retry_jitter = True
    dont_auto_retry_for = (TypeError,)

    def on_failure(self, exc, task_id, args, kwargs, einfo):
        logger.error("[!!] %s failed: %s", task_id, exc)


_VALID_STATUSES = {"Active", "Decommissioned", "Maintenance"}


def _to_iso(value: Any) -> str | None:
    """Coerce a datetime (or string, or None) to ISO-8601 string for JSON."""
    if value is None:
        return None
    if isinstance(value, datetime):
        return value.isoformat()
    return str(value)


def _viper_asset_payload(asset: Any, blueflow_base_url: str) -> dict[str, Any]:
    """Map a BlueFlow Asset row to Viper's integrationUpload schema."""
    ip = str(getattr(asset, "ip_address", "") or "") or "0.0.0.0"
    mac = str(getattr(asset, "mac_address", "") or "")
    serial = getattr(asset, "serial_number", None)
    hostname = getattr(asset, "hostname", None)
    raw_status = (getattr(asset, "status", None) or "Active").capitalize()
    status = raw_status if raw_status in _VALID_STATUSES else "Active"
    upstream_api = f"{blueflow_base_url.rstrip('/')}/api/assets/{asset.id}/"
    vendor_id = (
        str(getattr(asset, "nic_vendor", "") or "")
        or str(getattr(asset, "manufacturer", "") or "")
        or "unknown"
    )

    return {
        "ip": ip,
        "upstreamApi": upstream_api,
        "vendorId": vendor_id,
        "hostname": hostname,
        "macAddress": mac or None,
        "serialNumber": serial,
        "networkSegment": None,
        "role": None,
        "status": status,
        "location": {},
    }


def _build_pages(
    viper_data: ViperWebhookRequest,
    blueflow_base_url: str,
) -> list[dict[str, Any]]:
    """Build the paginated payload list in Viper's expected wrapper shape."""
    Asset = apps.get_model("blueflow", "Asset")
    qs = Asset.objects.all()
    since = viper_data.since
    before = viper_data.before
    if since is not None:
        qs = qs.filter(last_pinged__gte=since)
    if before is not None:
        qs = qs.filter(last_pinged__lte=before)
    qs = qs.order_by("last_pinged")
    rows = list(qs)
    total = len(rows)
    page_size = max(int(viper_data.page_size or 100), 1)
    total_pages = max(math.ceil(total / page_size), 1)
    max_pages = int(viper_data.max_pages or 10)

    pages: list[dict[str, Any]] = []
    for page_index, start in enumerate(range(0, total, page_size), start=1):
        if page_index > max_pages:
            logger.warning(
                "viper sync truncated at max_pages=%d (total=%d, page_size=%d)",
                max_pages,
                total,
                page_size,
            )
            break
        chunk = rows[start : start + page_size]
        pages.append(
            {
                "items": [_viper_asset_payload(a, blueflow_base_url) for a in chunk],
                "page": page_index,
                "pageSize": page_size,
                "totalCount": total,
                "totalPages": total_pages,
                "next": (
                    f"?page={page_index + 1}" if page_index < total_pages else None
                ),
                "previous": f"?page={page_index - 1}" if page_index > 1 else None,
            },
        )

    if total == 0:
        pages.append(
            {
                "items": [],
                "page": 1,
                "pageSize": page_size,
                "totalCount": 0,
                "totalPages": 1,
                "next": None,
                "previous": None,
            },
        )

    return pages


def _send_viper_payload(viper_data: ViperWebhookRequest, request_id: str) -> None:
    """Send pages to viper.callback in Viper's expected shape."""
    from django.conf import settings

    blueflow_base = getattr(settings, "BASE_URL", None) or "http://blueflow:8000"
    pages = _build_pages(viper_data, blueflow_base)
    for page in pages:
        resp = requests.post(
            viper_data.callback,
            json=page,
            headers={"Content-Type": "application/json"},
            timeout=30,
        )
        if not resp.ok:
            logger.error(
                "viper integrationUpload failed (%s): %s",
                resp.status_code,
                resp.text[:512],
            )
        resp.raise_for_status()


@celery_app.task(base=Task)
def viper_webhook(data: dict, request_id: str = "") -> None:
    """Process a viper webhook (patched: see module docstring)."""
    if isinstance(data.get("since"), str):
        data["since"] = datetime.fromisoformat(data["since"].replace("Z", "+00:00"))
    if isinstance(data.get("before"), str):
        data["before"] = datetime.fromisoformat(data["before"].replace("Z", "+00:00"))

    viper_data = ViperWebhookRequest(**data)
    logger.info("Processing viper webhook (patched): %s", viper_data)

    if request_id:
        ViperWebhookJob.objects.filter(pk=request_id).update(
            status=ViperWebhookJob.Status.STARTED,
        )
    try:
        _send_viper_payload(viper_data, request_id)
    except Exception:
        if request_id:
            ViperWebhookJob.objects.filter(pk=request_id).update(
                status=ViperWebhookJob.Status.ERROR,
            )
        raise
    if request_id:
        ViperWebhookJob.objects.filter(pk=request_id).update(
            status=ViperWebhookJob.Status.FINISHED,
        )
