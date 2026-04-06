FROM php:8.3-fpm-alpine

# 0. Remap www-data to match host deploy user UID/GID
# This avoids permission conflicts on bind-mounted volumes.
# Default 1000 works for most single-user Linux servers.
ARG PHP_UID=1000
ARG PHP_GID=1000
RUN deluser www-data 2>/dev/null || true && \
    delgroup www-data 2>/dev/null || true && \
    addgroup -g ${PHP_GID} www-data && \
    adduser -u ${PHP_UID} -G www-data -s /bin/sh -D www-data

# 1. Install Runtime Dependencies
# These libraries are needed for the PHP extensions to run.
# - freetype, libjpeg-turbo, libpng: For GD (Images)
# - libzip: For Zip
# - icu-libs: For Intl
# - imagemagick: For Imagick
# - ghostscript: For PDF previews in Imagick
RUN apk add --no-cache \
    freetype \
    libjpeg-turbo \
    libpng \
    libzip \
    icu-libs \
    imagemagick \
    libgomp \
    ghostscript

# 2. Install Build Dependencies & Compile Extensions
# We use --virtual to group these so we can delete them all at once later.
RUN set -eux; \
    apk add --no-cache --virtual .build-deps \
    $PHPIZE_DEPS \
    freetype-dev \
    libjpeg-turbo-dev \
    libpng-dev \
    libzip-dev \
    icu-dev \
    imagemagick-dev \
    linux-headers \
    ; \
    \
    # Configure & Install Core Extensions
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j$(nproc) \
        bcmath \
        exif \
        gd \
        intl \
        mysqli \
        pdo_mysql \
        zip \
        opcache \
    ; \
    \
    # Install PECL Extensions
    pecl install imagick redis; \
    docker-php-ext-enable imagick redis; \
    \
    # Cleanup Build Dependencies
    apk del .build-deps

# 3. Install healthcheck script
RUN echo '#!/bin/sh' > /usr/local/bin/php-fpm-healthcheck && \
    echo 'SCRIPT_NAME=/ping SCRIPT_FILENAME=/ping REQUEST_METHOD=GET cgi-fcgi -bind -connect 127.0.0.1:9000 || exit 1' >> /usr/local/bin/php-fpm-healthcheck && \
    chmod +x /usr/local/bin/php-fpm-healthcheck && \
    apk add --no-cache fcgi

# 4. Custom Configs
COPY local.ini /usr/local/etc/php/conf.d/local.ini
COPY www.conf /usr/local/etc/php-fpm.d/www.conf

WORKDIR /var/www/sites

EXPOSE 9000