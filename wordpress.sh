#!/bin/bash

# Function to display usage instructions
usage() {
    echo "Usage: bash $(basename $0) [options]"
    echo "Options:"
    echo "  -d DOMAIN_NAME   Your domain name (e.g., example.com)"
    echo "  -u DB_USER       MySQL database user"
    echo "  -p DB_PASSWORD   MySQL database password"
    echo "  -n DB_NAME       MySQL database name"
    echo "  -e DB_HOST       MySQL database host (default: localhost)"
    exit 1
}

# Function to install a package and handle errors
install_package() {
    if ! apt-get install -y "$@"; then
        echo "Failed to install packages. Exiting..."
        exit 1
    fi
}

# Check if Redis is installed
if ! command -v redis-server &>/dev/null; then
    echo "Redis server is not installed. Installing..."
    install_package redis-server
fi

# Check if PHP and required extensions are installed
if ! command -v php &>/dev/null; then
    echo "PHP is not installed. Installing..."
    install_package php php-fpm php-mysql php-redis
fi

# Read input arguments
while getopts "d:u:p:n:e:" opt; do
    case $opt in
        d) DOMAIN="$OPTARG" ;;
        u) DB_USER="$OPTARG" ;;
        p) DB_PASSWORD="$OPTARG" ;;
        n) DB_NAME="$OPTARG" ;;
        e) DB_HOST="$OPTARG" ;;
        *) usage ;;
    esac
done

# Check if required arguments are provided
if [[ -z $DOMAIN ]] || [[ -z $DB_USER ]] || [[ -z $DB_PASSWORD ]] || [[ -z $DB_NAME ]]; then
    echo "Required arguments missing. Exiting..."
    usage
fi

# Set default database host if not provided
if [[ -z $DB_HOST ]]; then
    DB_HOST="localhost"
fi

# Install WordPress
echo "Installing WordPress..."
cd /tmp
curl -O https://wordpress.org/latest.zip

mkdir -p /var/www/$DOMAIN/html
unzip /tmp/latest.zip -d /var/www/$DOMAIN/html/
chown -R www-data:www-data /var/www/$DOMAIN/html/

# Configure WordPress
echo "Configuring WordPress..."
cd /var/www/$DOMAIN/html/
cp wp-config-sample.php wp-config.php

sed -i "s/database_name_here/$DB_NAME/g" wp-config.php
sed -i "s/username_here/$DB_USER/g" wp-config.php
sed -i "s/password_here/$DB_PASSWORD/g" wp-config.php
sed -i "s|localhost|$DB_HOST|g" wp-config.php

# Configure PHP-FPM
echo "Configuring PHP-FPM..."
sed -i 's/^;?pm =.*/pm = dynamic/g' /etc/php/7.4/fpm/php-fpm.conf
sed -i 's/^;?pm.max_children =.*/pm.max_children = 5/g' /etc/php/7.4/fpm/php-fpm.conf
sed -i 's/^;?pm.start_servers =.*/pm.start_servers = 2/g' /etc/php/7.4/fpm/php-fpm.conf
sed -i 's/^;?pm.min_spare_servers =.*/pm.min_spare_servers = 1/g' /etc/php/7.4/fpm/php-fpm.conf
sed -i 's/^;?pm.max_spare_servers =.*/pm.max_spare_servers = 3/g' /etc/php/7.4/fpm/php-fpm.conf

sed -i 's/;?user = .*/user = www-data/g' /etc/php/7.4/fpm/pool.d/www.conf
sed -i 's/;?group = .*/group = www-data/g' /etc/php/7.4/fpm/pool.d/www.conf

systemctl restart php7.4-fpm

# Configure Nginx
echo "Configuring Nginx..."
cat > /etc/nginx/sites-available/$DOMAIN << EOF
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    root /var/www/$DOMAIN/html;

    index index.php index.html index.htm;

    location / {
        try_files $uri $uri/ =404;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php7.4-fpm.sock;
        fastcgi_cache WORDPRESS;
        fastcgi_cache_valid 200 301 302 1h;
        fastcgi_cache_valid 404 1m;
    }
}
EOF

ln -s /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
systemctl restart nginx

# Install Redis Object Cache plugin
echo "Installing Redis Object Cache plugin..."
cd /var/www/$DOMAIN/html/wp-content/plugins/
curl -O https://downloads.wordpress.org/plugin/redis-object-cache.zip
unzip redis-object-cache.zip
rm redis-object-cache.zip

# Activate Redis Object Cache plugin
echo "Activating Redis Object Cache plugin..."
cd /var/www/$DOMAIN/html/wp-content/
curl -X POST http://$DOMAIN/wp-admin/plugins.php?plugin_status=activate&plugin=redis-object-cache%2Fredis-object-cache.php

echo "WordPress with Redis object caching, Redis Cache plugin, and FastCGI/Proxy Page Caching installed successfully!"
