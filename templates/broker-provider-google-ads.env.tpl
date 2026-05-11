# Google Ads credentials for clau-broker.
#
# Required for any /google-ads/* endpoint to work.
# All four GOOGLE_ADS_* values below are required together; missing one
# returns HTTP 503 from /google-ads/*.

GOOGLE_ADS_DEVELOPER_TOKEN=
GOOGLE_ADS_CLIENT_ID=
GOOGLE_ADS_CLIENT_SECRET=
GOOGLE_ADS_REFRESH_TOKEN=

# Optional: only needed when accessing accounts under a manager (MCC).
# GOOGLE_ADS_LOGIN_CUSTOMER_ID=
