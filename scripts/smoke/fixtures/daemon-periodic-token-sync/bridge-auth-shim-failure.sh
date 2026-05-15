#!/usr/bin/env bash
# Test shim for bridge-auth.sh — simulates the bridge-auth.sh sync command
# failing (e.g. controller token missing). Exit non-zero so the tick takes
# the status=failed branch.
exit 7
