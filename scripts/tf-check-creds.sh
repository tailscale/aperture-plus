#!/bin/bash
#
# tf-check-creds.sh — verify App Store Connect upload credentials are available
# BEFORE the (slow) archive/export steps of `make tf`, so the build fails fast
# with clear instructions instead of after a multi-minute archive.
#
# Credentials may be provided any of three ways (all checked here):
#   1. A shell env file at $APERTURE_TF_ENV (default ~/.aperture-testflight.env),
#      sourced if present. Example contents (API key, preferred):
#        ASC_KEY_ID=FG54QN43A3
#        ASC_ISSUER_ID=9ff1ebe7-73a7-4102-9451-3472e4e629a7
#      (Or ASC_USERNAME + ASC_PASSWORD for Apple-ID auth.)
#   2. Real environment variables (e.g. `export ASC_KEY_ID=...` in your shell).
#   3. On the make command line: `make tf ASC_KEY_ID=... ASC_ISSUER_ID=...`
#
# Auth modes:
#   - API key (preferred): ASC_KEY_ID + ASC_ISSUER_ID
#     (key file at ~/private_keys/AuthKey_<ASC_KEY_ID>.p8, or override with
#     ASC_KEY_PATH). Create at App Store Connect → Users and Access →
#     Integrations → App Store Connect API.
#   - Apple ID: ASC_USERNAME + ASC_PASSWORD (an app-specific password from
#     appleid.apple.com, NOT the account login password).
#
# Exit 0 = creds available; exit 1 = missing (with instructions).
set -euo pipefail

ENV_FILE="${APERTURE_TF_ENV:-$HOME/.aperture-testflight.env}"

# Source the env file if it exists (idempotent; harmless if absent).
if [ -f "$ENV_FILE" ]; then
	set -a
	. "$ENV_FILE"
	set +a
fi

have_api_key=0
have_appleid=0
[ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] && have_api_key=1
[ -n "${ASC_USERNAME:-}" ] && [ -n "${ASC_PASSWORD:-}" ] && have_appleid=1

if [ "$have_api_key" -eq 1 ] || [ "$have_appleid" -eq 1 ]; then
	exit 0
fi

cat >&2 <<EOF
❌ No App Store Connect upload credentials found.

Provide them one of these ways:

  1) Env file (recommended for repeated use) at:
       $ENV_FILE
     with contents (API key, preferred):
       ASC_KEY_ID=<key-id>
       ASC_ISSUER_ID=<issuer-id>
     or (Apple ID + app-specific password):
       ASC_USERNAME=<apple-id>
       ASC_PASSWORD=<app-specific-password>
     The API key .p8 goes at ~/private_keys/AuthKey_<ASC_KEY_ID>.p8
     (override its path with ASC_KEY_PATH=...).

  2) Environment variables: export ASC_KEY_ID=... ASC_ISSUER_ID=... (or
     ASC_USERNAME/ASC_PASSWORD) before running make.

  3) On the make command line:
       make tf ASC_KEY_ID=<key-id> ASC_ISSUER_ID=<issuer-id>

Get an API key at App Store Connect → Users and Access → Integrations →
App Store Connect API. Uploads also require the Paid Applications Agreement
to be signed (App Store Connect → Business → Agreements). See
README.testflight.md for the full flow.
EOF
exit 1
