#!/bin/bash
# =====================================================================
# TD3 - Machine "WireGuard" : génère les clés et les deux configurations
# du tunnel n°1 (serveur + client), puis démarre le tunnel côté serveur.
# Usage : bash wg-serveur.sh
# =====================================================================
set -euo pipefail

IP_LAN_CLIENT="10.0.1.1"   # IP de cette machine sur le LAN "cliente" <-> "WireGuard"
PORT=51820                 # port UDP d'écoute WireGuard
IF=wg0                     # nom de l'interface WireGuard

umask 077                  # fichiers de clés lisibles par root uniquement
mkdir -p /etc/wireguard /root/partage
cd /etc/wireguard

# 1) Paires de clés (privée -> publique) et clé pré-partagée
wg genkey | tee serveur.key | wg pubkey > serveur.pub
wg genkey | tee client.key  | wg pubkey > client.pub
wg genpsk > psk.key

# 2) Configuration serveur
cat > "$IF.conf" <<EOF
[Interface]
PrivateKey = $(cat serveur.key)
Address = 192.168.42.1/24
ListenPort = $PORT

# post-up : NAT des paquets sortant du tunnel + routage noyau
PostUp = nft add table ip "nat-%i"
PostUp = nft add chain ip "nat-%i" postrouting \{ type nat hook postrouting priority srcnat \; \}
PostUp = nft add ip "nat-%i" postrouting iifname "%i" masquerade
PostUp = sysctl -q -w net.ipv4.ip_forward=1

# post-down
PostDown = sysctl -q -w net.ipv4.ip_forward=0
PostDown = nft delete table ip "nat-%i"

[Peer]
PublicKey = $(cat client.pub)
PresharedKey = $(cat psk.key)
AllowedIPs = 192.168.42.10/32
EOF

# 3) Configuration client (déposée dans /root/partage pour être récupérée)
cat > /root/partage/wg0-client.conf <<EOF
[Interface]
PrivateKey = $(cat client.key)
Address = 192.168.42.10/32

[Peer]
PublicKey = $(cat serveur.pub)
PresharedKey = $(cat psk.key)
# 10.0.2.0/24 : pour joindre le serveur OpenVPN A TRAVERS le tunnel (oignon)
AllowedIPs = 192.168.42.0/24, 10.0.2.0/24
Endpoint = $IP_LAN_CLIENT:$PORT
PersistentKeepalive = 25
EOF

# La clé privée du client n'a rien à faire sur le serveur
rm -f client.key

# 4) Démarrage du tunnel + activation au démarrage
systemctl enable --now "wg-quick@$IF.service"
wg show "$IF"

echo
echo "OK. Pour transmettre la config au client, lance :"
echo "  python3 -m http.server 8000 --bind $IP_LAN_CLIENT --directory /root/partage"
echo "puis, une fois récupérée par le client : Ctrl+C et  rm -rf /root/partage"
