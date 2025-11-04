server {
    listen 443 ssl http2;
    server_name {{SERVER_NAME}};

    ssl_certificate {{SSL_CERT}};
    ssl_certificate_key {{SSL_CERT_KEY}};
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options DENY;
    add_header X-XSS-Protection "1; mode=block";

    access_log /var/log/nginx/cobweb.access.log;
    error_log /var/log/nginx/cobweb.error.log warn;

    client_max_body_size 25m;

{{ROUTE_BLOCKS}}
}
