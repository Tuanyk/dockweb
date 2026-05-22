  @@SERVICE_NAME@@:
    image: clau-broker:latest
    container_name: @@SERVICE_NAME@@
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - NET_RAW
    environment:
      CLAU_FIREWALL: "1"
      CLAU_INBOUND_PORTS: "8080"
      BROKER_AUTH_TOKEN: "${@@TOKEN_ENV_VAR@@}"
    volumes:
      - @@SECRETS_DIR@@/@@CLAU_PROJECT@@/broker:/run/broker-secrets
      - ./brokers/@@SITE@@/allowlist.txt:/etc/allowlist.txt:ro
    networks:
      web_network:
        aliases:
          - @@ALIAS@@
    healthcheck:
      test: ["CMD-SHELL", "curl -fs -m 2 -H \"Authorization: Bearer $$BROKER_AUTH_TOKEN\" http://127.0.0.1:8080/health || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    deploy:
      resources:
        limits:
          memory: 256M
          cpus: '0.5'
        reservations:
          memory: 64M
          cpus: '0.1'
