  {{SERVICE_NAME}}:
    build: ./php
    container_name: {{CONTAINER_NAME}}
    restart: unless-stopped
    environment:
      PM_MAX_CHILDREN: ${PHP_PM_MAX_CHILDREN:-5}
      SITE_NAME: "{{DOMAIN}}"
    volumes:
      - ./sites/{{DOMAIN}}:/var/www/sites/{{DOMAIN}}
      - ./logs/php/{{DOMAIN}}:/var/log
    depends_on:
      - mysql
      - redis
    networks:
      - web_network
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    healthcheck:
      test: ["CMD-SHELL", "php-fpm-healthcheck || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    deploy:
      resources:
        limits:
          memory: 512M
          cpus: '1.0'
        reservations:
          memory: 128M
          cpus: '0.25'
