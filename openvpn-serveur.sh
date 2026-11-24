#!/bin/bash
# =====================================================================
# TD3 - Machine "OpenVPN" : crée la PKI (easy-rsa), la configuration
# serveur du tunnel n°2, et une configuration client "tout-en-un"
# (certificats inclus), puis démarre le serveur.
# Usage : bash openvpn-serveur.sh
# =====================================================================
set -euo pipefail

IP_LAN_WG="10.0.2.2"          # IP de cette machine sur le LAN "WireGuard" <-> "OpenVPN"
RESEAU_VPN="10.9.8.0 255.255.255.0"

apt-get install -y openvpn easy-rsa >/dev/null
umask 077
mkdir -p /root/partage

# 1) PKI : CA, paramètres DH, certificats serveur et client (nopass = clés non chiffrées)
rm -rf /etc/openvpn/easy-rsa
make-cadir /etc/openvpn/easy-rsa
cd /etc/openvpn/easy-rsa
export EASYRSA_BATCH=1
./easyrsa init-pki
EASYRSA_REQ_CN="TD3 OpenVPN CA" ./easyrsa build-ca nopass
echo ">> Génération des paramètres Diffie-Hellman (peut prendre 1 à 2 minutes)..."
./easyrsa gen-dh
./easyrsa build-server-full server nopass
./easyrsa build-client-full client nopass

# 2) Clé d'authentification TLS (HMAC sur les paquets de contrôle)
openvpn --genkey secret /etc/openvpn/ta.key

PKI=/etc/openvpn/easy-rsa/pki

# 3) Configuration serveur (/etc/openvpn/server.conf -> openvpn@server.service)
cat > /etc/openvpn/server.conf <<EOF
port 1194
proto udp
dev tun
ca   $PKI/ca.crt
cert $PKI/issued/server.crt
key  $PKI/private/server.key
dh   $PKI/dh.pem
tls-auth /etc/openvpn/ta.key 0
topology subnet
server $RESEAU_VPN
keepalive 10 120
persist-key
persist-tun
status /var/log/openvpn-status.log
verb 3
EOF
# Aucune directive push "route ..." / push "redirect-gateway" : split-tunneling.

# 4) Configuration client tout-en-un (certificats et clés intégrés)
{
cat <<EOF
client
dev tun
proto udp
remote $IP_LAN_WG 1194
nobind
remote-cert-tls server
# ne pas laisser le serveur remplacer la route par défaut du client
pull-filter ignore redirect-gateway
persist-key
persist-tun
verb 3
key-direction 1
EOF
echo "<ca>";       cat "$PKI/ca.crt";                       echo "</ca>"
echo "<cert>";     openssl x509 -in "$PKI/issued/client.crt"; echo "</cert>"
echo "<key>";      cat "$PKI/private/client.key";           echo "</key>"
echo "<tls-auth>"; cat /etc/openvpn/ta.key;                 echo "</tls-auth>"
} > /root/partage/client.conf

# 5) Démarrage + activation au démarrage
systemctl enable --now openvpn@server.service
sleep 2
systemctl --no-pager status openvpn@server.service | head -5 || true

echo
echo "OK. Pour transmettre la config au client (à travers le tunnel WireGuard), lance :"
echo "  python3 -m http.server 8000 --bind $IP_LAN_WG --directory /root/partage"
echo "puis, une fois récupérée par le client : Ctrl+C et  rm -rf /root/partage"
