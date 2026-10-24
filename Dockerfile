# The base image is a build argument so CI can pin it by digest
# (e.g. php:8.5-fpm-alpine@sha256:...). The default keeps local builds simple.
ARG PHP_BASE=php:8.5-fpm-alpine
FROM ${PHP_BASE}

RUN docker-php-ext-install pdo_mysql \
 && mv /usr/local/etc/php/php.ini-production /usr/local/etc/php/php.ini

COPY conf/zz-hardening.ini /usr/local/etc/php/conf.d/zz-hardening.ini
COPY conf/zz-pool.conf /usr/local/etc/php-fpm.d/zz-pool.conf

# Safe default; deployments may override it (e.g. user: "99:100").
USER www-data
