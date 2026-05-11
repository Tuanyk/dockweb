# Meta (Facebook / Instagram) credentials for clau-broker.
#
# Required for any /meta/* or /passthrough/meta/* endpoint to work.
# At minimum, set META_ACCESS_TOKEN.
#
# These are read by the broker process at startup. Restart the broker after
# editing: `dockweb broker restart <site>`.

# Primary Meta token. Use a long-lived system-user token with access to all
# ad accounts / pages / Instagram accounts you need.
META_ACCESS_TOKEN=

# Optional: separate page-access token. If unset, the broker resolves page
# tokens from META_USER_ACCESS_TOKEN via /me/accounts when needed.
# META_PAGE_ACCESS_TOKEN=

# Optional: user-access token used inside the broker to resolve page tokens.
# Falls back to META_ACCESS_TOKEN if not set.
# META_USER_ACCESS_TOKEN=

# Optional default IDs — only used when a request omits the explicit ID.
# Multi-account workflows should pass page_id / ad_account_id per request
# instead of relying on these defaults.
# META_PAGE_ID=
# META_INSTAGRAM_BUSINESS_ACCOUNT_ID=

# Optional: override the Graph API version (default v21.0).
# META_GRAPH_VERSION=v21.0
