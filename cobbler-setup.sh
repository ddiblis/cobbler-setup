IP=$(hostname -I | awk '{print $1}')
OPTION_ROUTER=$(echo $IP | sed 's/\.[0-9]*$/.1/')
SUBNET=$(echo $IP | sed 's/\.[0-9]*$/.0/')
DHCP_RANGE_START=$(echo $IP | sed 's/\.[0-9]*$/.100/')
DHCP_RANGE_END=$(echo $IP | sed 's/\.[0-9]*$/.250/')

while true; do
    echo "Do you want Cobbler to manage DHCP?"
    echo "1) Yes"
    echo "2) No"
    read -p "Enter your choice (1 or 2): " choice

    if [[ "$choice" == "1" ]]; then
        MANAGE_DHCP=true
        break
    elif [[ "$choice" == "2" ]]; then
        MANAGE_DHCP=false
        break
    else
        echo "Invalid choice. Please select 1 or 2."
    fi
done

sudo subscription-manager repos --enable codeready-builder-for-rhel-9-$(arch)-rpms
dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
dnf install -y cobbler python3-pefile python3-hivex wimlib-utils dhcp-server samba debmirror pykickstart yumutils
systmctl disable --now firewalld
sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
cat <<EOF >> /etc/samba/smb.conf
[DISTRO]
	path = /var/www/cobbler
	guest ok = yes
	browsable = yes
	public = yes
	writeable = no
	printable = no
EOF
sed -i 's/windows_enabled: no/windows_enabled: yes/' /etc/cobbler/settings.d/windows.template

wget https://github.com/ipxe/shim/releases/download/ipxe-15.7/ipxe-shimx64.efi -P /var/lib/cobbler/loaders
wget https://boot.ipxe.org/ipxe.iso
wget https://github.com/ipxe/wimboot/releases/latest/download/wimboot -P /var/lib/cobbler/loaders

mkdir -p /mnt/{cdrom,disk}
mount -o loop,ro ipxe.iso /mnt/cdrom
mount -o loop,ro /mnt/cdrom/esp.img /mnt/disk
cp /mnt/disk/EFI/BOOT/BOOTX64.EFI /var/lib/cobbler/loaders/ipxe.efi

sed -i 's/enable_ipxe: false/enable_ipxe: true/' /etc/cobbler/settings.yaml
sed -i "s/next_server_v4: 127.0.0.1/next_server_v4: ${IP}/; s/server: 127.0.0.1/server: ${IP}/" /etc/cobbler/settings.yaml
sed -i 's/@dists="sid";/#@dists="sid";' /etc/debmirror.conf
sed -i 's/@arches="i306";/#@arches="1306";' /etc/debmirror.conf

if [ ${MANAGE_DHCP} == true ]; then
	sed -i 's/manage_dhcp: false/manage_dhcp: true/' /etc/cobbler/settings.yaml
	sed -i 's/manage_dhcp_v4: false/manage_dhcp_v4: true/' /etc/cobbler/settings.yaml
	sed -i "s/subnet 192.168.1.0 netmask 255.255.255.0 {/subnet ${SUBNET} netmask 255.255.255.0 {/" /etc/cobbler/dhcp.template
	sed -i "s/option routers             192.168.1.5;/option routers             ${OPTION_ROUTER};/" /etc/cobbler/dhcp.template
	sed -i "s/option domain-name-servers 192.168.1.1;/option domain-name-servers 10.1.0.41,10.1.0.42;/" /etc/cobbler/dhcp.template
  	sed -i "s/range dynamic-bootp        192.168.1.100 192.168.1.254;/range dynamic-bootp        ${DHCP_RANGE_START} ${DHCP_RANGE_END};/" /etc/cobbler/dhcp.template
	sed -i '31,85d' /etc/cobbler/dhcp.template
	sed -i '31i\
               if exists user-class and option user-class = "iPXE" {\
                    filename "/ipxe/default.ipxe";\
               }\
               # UEFI-64-1\
               else if option system-arch = 00:07 {\
                    filename "ipxe-shimx64.efi";\
               }' /etc/cobbler/dhcp.template
fi

systemctl enable --now {cobblerd,smb,dhcpd,tftp.service}
reboot
