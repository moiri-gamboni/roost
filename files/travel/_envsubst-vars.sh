# Centralized envsubst variable allowlist for xray config rendering.
#
# Sourced by both files/setup/travel-vpn.sh (initial setup) and
# files/hooks/roost-apply.sh (config refresh) to ensure both consumers
# expand the same set of state.env values. Adding a new variable here
# (e.g. when a new xray inbound is introduced) makes both render paths
# pick it up automatically — fixes the "config validates, auth fails"
# silent footgun where the two consumers had divergent allowlists.
#
# This file is sourced, not executed. Do not add side effects.

XRAY_ENVSUBST_VARS='$XRAY_UUID $XRAY_PATH $GRPC_SERVICE_NAME $REALITY_PRIVATE_KEY $REALITY_SHORT_IDS $SS2022_PASSWORD $VISION_SNI'
