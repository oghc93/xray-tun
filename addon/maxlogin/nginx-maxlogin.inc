# MaxLogin: di-include DI DALAM blok server yang sama dengan location /vless-ws dst.
# Letakkan SEBELUM location lama. Tidak mengubah location SSHWS/Dropbear.
location = /_ml_auth {
    internal;
    proxy_pass http://127.0.0.1:10901/auth;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header X-Original-URI $request_uri;
    proxy_set_header X-Real-IP $remote_addr;
}
location ~ ^/(?<ml_proto>vless|vmess|trojan)-(?:ws|ntls)/[A-Za-z0-9]+$ {
    auth_request /_ml_auth;
    rewrite ^ /$ml_proto-ml break;
    proxy_pass http://$ml_backend;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_read_timeout 3600s;
}
