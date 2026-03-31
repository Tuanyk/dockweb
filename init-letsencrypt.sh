#!/bin/bash

# Initialize Let's Encrypt SSL certificates for your domains
# Run this script ONCE after initial setup

set -e

# Load environment variables
if [ -f .env ]; then
  export $(cat .env | grep -v '^#' | xargs)
fi

# Configuration
domains=(example.com www.example.com)  # Change to your domains
email="${CERTBOT_EMAIL:-your-email@example.com}"  # Set your email
staging=0  # Set to 1 for testing to avoid rate limits

echo "### Initializing Let's Encrypt SSL Certificates ###"
echo ""

# Create directories
mkdir -p certbot/conf
mkdir -p certbot/www
mkdir -p certbot/logs
mkdir -p nginx/cache

# Download recommended TLS parameters
if [ ! -f "certbot/conf/options-ssl-nginx.conf" ]; then
  echo "### Downloading recommended TLS parameters..."
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf > certbot/conf/options-ssl-nginx.conf
fi

if [ ! -f "certbot/conf/ssl-dhparams.pem" ]; then
  echo "### Downloading DH parameters..."
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem > certbot/conf/ssl-dhparams.pem
fi

echo ""
echo "### Creating dummy certificate for ${domains[0]}..."
path="/etc/letsencrypt/live/${domains[0]}"
mkdir -p "certbot/conf/live/${domains[0]}"
docker-compose run --rm --entrypoint "\
  openssl req -x509 -nodes -newkey rsa:4096 -days 1\
    -keyout '$path/privkey.pem' \
    -out '$path/fullchain.pem' \
    -subj '/CN=localhost'" certbot

echo ""
echo "### Starting nginx..."
docker-compose up -d nginx

echo ""
echo "### Removing dummy certificate..."
docker-compose run --rm --entrypoint "\
  rm -rf /etc/letsencrypt/live/${domains[0]} && \
  rm -rf /etc/letsencrypt/archive/${domains[0]} && \
  rm -rf /etc/letsencrypt/renewal/${domains[0]}.conf" certbot

echo ""
echo "### Requesting Let's Encrypt certificate for ${domains[*]}..."

# Join domains with -d flag
domain_args=""
for domain in "${domains[@]}"; do
  domain_args="$domain_args -d $domain"
done

# Select appropriate email arg
case "$email" in
  "") email_arg="--register-unsafely-without-email" ;;
  *) email_arg="--email $email" ;;
esac

# Enable staging mode if needed
if [ $staging != "0" ]; then staging_arg="--staging"; fi

docker-compose run --rm --entrypoint "\
  certbot certonly --webroot -w /var/www/certbot \
    $staging_arg \
    $email_arg \
    $domain_args \
    --rsa-key-size 4096 \
    --agree-tos \
    --force-renewal" certbot

echo ""
echo "### Reloading nginx..."
docker-compose exec nginx nginx -s reload

echo ""
echo "### SSL certificates successfully installed! ###"
echo "Certificates will auto-renew every 12 hours."
echo ""
echo "IMPORTANT: Update your DNS records to point to this server:"
for domain in "${domains[@]}"; do
  echo "  - $domain -> $(curl -s ifconfig.me)"
done
echo ""
