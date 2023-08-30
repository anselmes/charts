options { directory "/var/cache/bind";
auth-nxdomain no;
listen-on-v6 { none; };
include "/etc/bind/maas/named.conf.options.inside.maas"; };
