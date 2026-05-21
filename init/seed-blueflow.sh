#!/bin/bash
# Provisions the BlueFlow admin user and API token from env vars.
# Called via: docker compose exec blueflow bash /demo-init/seed-blueflow.sh
set -eu

cd /app
.venv/bin/python project/manage.py shell -c "
from django.contrib.auth import get_user_model
from rest_framework.authtoken.models import Token
from waffle.models import Switch
import os

User = get_user_model()
username = os.environ.get('DEFAULT_USERNAME', 'admin')
password  = os.environ.get('DEFAULT_PASSWORD', 'admin')
token_val = os.environ['API_TOKEN']

user, _ = User.objects.get_or_create(
    username=username,
    defaults={'is_superuser': True, 'is_staff': True},
)
user.set_password(password)
user.save()

token, created = Token.objects.get_or_create(user=user, defaults={'key': token_val})
if not created and token.key != token_val:
    token.key = token_val
    token.save()

# AssetViewSet (and every other BlueFlow ViewSet) inherits
# waffle.mixins.WaffleSwitchMixin with waffle_switch='core'. An inactive (or
# missing-then-auto-created) 'core' switch makes the viewset return 404 from
# invalid_waffle() — which surfaces in TapirXL's Vector log as
# 'Http status: 404 Not Found' on /api/assets/upsert/. Waffle's default
# WAFFLE_CREATE_MISSING_SWITCHES=True auto-creates the row with active=False
# on the first request that probes it, so a plain
# get_or_create(defaults={'active': True}) is *not* enough — defaults are
# ignored when the row already exists. Force active=True unconditionally.
#
# This script must run BEFORE any request hits a Waffle-protected route,
# otherwise BlueFlow's Django runserver will cache 'core=False' in its
# per-process LocMemCache (settings.CACHES['default']) and keep returning
# 404 until the container restarts. 'just boot' satisfies that ordering;
# 'just demo' depends on 'boot' for the same reason.
core_switch, _ = Switch.objects.get_or_create(name='core')
if not core_switch.active:
    core_switch.active = True
    core_switch.save()

print('BlueFlow seed complete. Token:', token_val[:8] + '...')
print('  core waffle switch active:', core_switch.active)
"
