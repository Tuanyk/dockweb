# ModSecurity WAF Configuration

This directory contains the ModSecurity Web Application Firewall configuration.

## Usage

The WAF runs as a reverse proxy in front of your main Nginx server:

```
Internet → Port 8080 (ModSecurity) → Port 80 (Nginx) → PHP-FPM
```

## Paranoia Levels

- **Level 1** (Default): Minimal false positives, good for most sites
- **Level 2**: More security, some false positives possible
- **Level 3**: High security, expect false positives
- **Level 4**: Maximum security, many false positives

Change via `PARANOIA` environment variable in docker-compose.yml.

## Accessing Your Site

- **Direct (bypasses WAF)**: http://your-server-ip
- **Through WAF**: http://your-server-ip:8080

For production, update your firewall to only allow port 8080 and block port 80/443 from external access.

## Logs

Check WAF logs at: `./logs/modsecurity/modsec_audit.log`

## Tuning

If legitimate requests are blocked:
1. Check logs to identify the rule ID
2. Add exceptions in a custom rules file
3. Or lower the PARANOIA level
