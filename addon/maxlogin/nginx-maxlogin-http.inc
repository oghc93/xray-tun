# MaxLogin: di-include di blok http {} (sekali), mis. lewat /etc/nginx/conf.d/maxlogin-map.conf
map $ml_proto $ml_backend {
    vless  127.0.0.1:10102;
    vmess  127.0.0.1:10101;
    trojan 127.0.0.1:10105;
}
