#!/bin/bash

# Skript zur Einrichtung von Gruppen, Benutzern, Verzeichnissen und weiteren Schritten für Oracle-Installation

# Gruppen anlegen
echo "Erstelle Gruppen..."
groupadd -g 110 dba
groupadd -g 111 oinstall
groupadd -g 202 oper
echo "Gruppen wurden erstellt."

# Benutzernamen abfragen
read -p "Geben Sie den Benutzernamen ein: " username

if [[ -z "$username" ]]; then
    echo "Fehler: Kein Benutzername angegeben."
    exit 1
fi

# Oracle-Verzeichnispfad abfragen
read -p "Geben Sie den Oracle-Unterverzeichnispfad(/oracle/...) an: " oracleverzeichnis
if [[ -z "$oracleverzeichnis" ]]; then
    echo "Fehler: Kein Verzeichnispfad angegeben."
    exit 1
fi

# Oracle-Hostname abfragen
read -p "Geben Sie den Oracle-Hostname an: " oracle_hostname
if [[ -z "$oracle_hostname" ]]; then
    echo "Fehler: Kein Hostname angegeben."
    exit 1
fi

# Oracle SID abfragen
read -p "Geben Sie die Oracle SID an: " oracle_sid
if [[ -z "$oracle_sid" ]]; then
    echo "Fehler: Keine Oracle SID angegeben."
    exit 1
fi

# Pruefung: Wurde das Skript moeglicherweise bereits ausgefuehrt?
echo "Pruefe, ob das System bereits vorbereitet wurde..."

# Existiert der Oracle-Benutzer?
if id "$username" &>/dev/null; then
    echo "Der Benutzer $username existiert bereits."
    user_exists=true
else
    user_exists=false
fi

# Gibt es ein Oracle-Verzeichnis?
if [[ -d "/oracle/$oracleverzeichnis" ]]; then
    echo "Das Verzeichnis /oracle/$oracleverzeichnis existiert bereits."
    oracle_dir_exists=true
else
    oracle_dir_exists=false
fi

# Wurde .profile bereits erweitert?
profile_path="/home/$username/.profile"
if [[ -f "$profile_path" ]] && grep -q "ORACLE_HOME=" "$profile_path"; then
    echo "Die Datei $profile_path enthaelt bereits Oracle-Konfiguration."
    profile_configured=true
else
    profile_configured=false
fi

# Kernel-Parameter bereits gesetzt?
if grep -q "kernel.shmmax" /etc/sysctl.conf; then
    echo "/etc/sysctl.conf scheint bereits Oracle-Eintraege zu enthalten."
    kernel_configured=true
else
    kernel_configured=false
fi

# Gesamtergebnis
if [[ "$user_exists" == true || "$oracle_dir_exists" == true || "$profile_configured" == true || "$kernel_configured" == true ]]; then
    echo ""
    echo "Es scheint, als ob das Setup bereits (teilweise) durchgefuehrt wurde."
    read -p "Wirklich fortfahren? (j/n): " confirm_continue
    if [[ "$confirm_continue" != "j" ]]; then
        echo "Du willst es nicht - wir hoeren auf."
        exit 1
    fi
fi

echo "Alles einsteigen, jetzt geht es los..."
echo ""

# User anlegen
echo "Erstelle Benutzer $username..."
useradd -u 489 -g oinstall -G dba,oper -m "$username"
echo "Bitte legen Sie das Passwort für $username fest:"
passwd "$username"
echo "Benutzer $username wurde erfolgreich erstellt."

# Verzeichnis anlegen
oracle_dir="/oracle/$oracleverzeichnis/product/19c"
if [[ ! -d "$oracle_dir" ]]; then
    echo "Erstelle Verzeichnis $oracle_dir..."
    mkdir -p "$oracle_dir"
else
    echo "Verzeichnis $oracle_dir existiert bereits."
fi

# Mountpoints umhängen
echo "Passe Mountpoints an..."
declare -A mounts
mounts["/oracle/admin"]="/oracle/$oracleverzeichnis/admin"
mounts["/oracle/onlinelog"]="/oracle/$oracleverzeichnis/onlinelog"
mounts["/oracle/flash_recovery_area"]="/oracle/$oracleverzeichnis/flash_recovery_area"
mounts["/oracle/oradata"]="/oracle/$oracleverzeichnis/oradata"

for old_mount in "${!mounts[@]}"; do
    new_mount="${mounts[$old_mount]}"
    mkdir -p "$new_mount"
    sed -i "s|$old_mount|$new_mount|g" /etc/fstab
    umount "$old_mount"
    if [[ $? -eq 0 ]]; then
        rmdir "$old_mount"
        mount "$new_mount"
        echo "Mountpoint $old_mount erfolgreich verschoben nach $new_mount."
    else
        echo "Fehler beim Umhängen von $old_mount. Bitte manuell prüfen."
        exit 1
    fi
done

# Verzeichnisrechte setzen
echo "Setze Besitzerrechte..."
chown -R "$username":oinstall /oracle
chown -R "$username":oinstall /tmp/oracle



# --------------------- LVM Vergrößerung ---------------------
echo "Starte SCSI-Bus-Scan..."
rescan-scsi-bus.sh

echo "Ermittle physikalische Volumes (PVs)..."
pvs_output=$(pvs --noheadings -o pv_name | awk '{print $1}')

for pv in $pvs_output; do
    echo "Verarbeite PV: $pv"
    rescan_path="/sys/block/$(basename $pv)/device/rescan"

    if [[ -e "$rescan_path" ]]; then
        echo "Rescan für Device $pv..."
        echo 1 > "$rescan_path"
    else
        echo "Hinweis: Kein rescan-Interface für $pv vorhanden – wahrscheinlich virtuelles oder gemapptes Device. Überspringe Rescan."
    fi

    echo "Führe pvresize für $pv aus..."
    pvresize "$pv"
done

# Benutzerdefinierte Zielgrößen abfragen
read -p "Geben Sie die gewünschte Größe in GB für /oracle an: " size_oracle
read -p "Geben Sie die gewünschte Größe in GB für $oracleverzeichnis/oradata an: " size_oradata
read -p "Geben Sie die gewünschte Größe in GB für $oracleverzeichnis/admin an: " size_admin
read -p "Geben Sie die gewünschte Größe in GB für $oracleverzeichnis/flash_recovery_area an: " size_flash
read -p "Geben Sie die gewünschte Größe in GB für $oracleverzeichnis/onlinelog an: " size_redo

# VMDK Groesse ermitteln... 
sum_vg_ora=$((size_oracle + size_admin + size_flash + size_redo))
sum_vg_db=$((size_oradata))

echo ""
echo "---------------------------------------------------------"
echo "WARNUNG: Stelle sicher, dass die VMDKs groß genug sind!"
echo ""
echo "Für Volume Group 'vg_ora' wird mindestens benötigt: ${sum_vg_ora} GB"
echo "Für Volume Group 'vg_db'  wird mindestens benötigt: ${sum_vg_db} GB"
echo "---------------------------------------------------------"
echo ""

read -p "Willste wirklich? (j/n): " confirm_lvextend
if [[ "$confirm_lvextend" != "j" ]]; then
    echo "Er will es nicht. Dann halt nicht...."
    exit 1
fi

echo "Er hat ja gesagt - dann los..."

# Logical Volumes erweitern
echo "Erweitere Logical Volumes..."
lvextend -L ${size_oracle}G /dev/mapper/vg_ora-lv_ora01
lvextend -L ${size_admin}G /dev/mapper/vg_ora-lv_admin01
lvextend -L ${size_flash}G /dev/mapper/vg_ora-lv_flash01
lvextend -L ${size_redo}G /dev/mapper/vg_ora-lv_redo01
lvextend -L ${size_oradata}G /dev/mapper/vg_db-lv_data01

echo "LVM-Vergroeßerung abgeschlossen."

# Vergroeßere Dateisystem

xfs_growfs /oracle/
xfs_growfs /oracle/${oracleverzeichnis}/onlinelog
xfs_growfs /oracle/${oracleverzeichnis}/flash_recovery_area
xfs_growfs /oracle/${oracleverzeichnis}/admin
xfs_growfs /oracle/${oracleverzeichnis}/oradata

# Verzeichnisrechte setzen
echo "Setze Besitzer und Gruppe für /oracle und /tmp/oracle..."
chown -R "$username":oinstall /oracle
chown -R "$username":oinstall /tmp/oracle

# ZIP-Datei entpacken
zip_file="/tmp/oracle/LINUX.X64_193000_db_home.zip"
if [[ -f "$zip_file" ]]; then
    echo "Entpacke $zip_file nach $oracle_dir..."
    unzip -q "$zip_file" -d "$oracle_dir"
    chown -R "$username":oinstall "$oracle_dir"
    echo "ZIP-Datei wurde erfolgreich entpackt."
else
    echo "Fehler: ZIP-Datei $zip_file nicht gefunden. Bitte prüfen Sie den Pfad."
    exit 1
fi

# OPatch-Ordner entfernen und neue Datei entpacken
opatch_zip="/tmp/oracle/1926/opatch_p6880880_190000_Linux-x86-64.zip"
if [[ -d "$oracle_dir/OPatch" ]]; then
    echo "Lösche Ordner $oracle_dir/OPatch..."
    rm -rf "$oracle_dir/OPatch"
fi

if [[ -f "$opatch_zip" ]]; then
    echo "Entpacke $opatch_zip nach $oracle_dir..."
    unzip -q "$opatch_zip" -d "$oracle_dir"
    echo "OPatch-Datei wurde erfolgreich entpackt."
else
    echo "Fehler: OPatch-Datei $opatch_zip nicht gefunden. Bitte prüfen Sie den Pfad."
    exit 1
fi

#Berechtigung für OPatch wieder korrigieren
echo "Setze Besitzer und Gruppe für OPatch"
chown -R "$username":oinstall "$oracle_dir/OPatch"

# Weitere Dateien entpacken
echo "Entpacke zusätzliche Dateien..."
dbru_zip="/tmp/oracle/1926/1926_dbru_p37260974_190000_Linux-x86-64.zip"
ojvm_zip="/tmp/oracle/1926/1926_ojvm_p37102264_190000_Linux-x86-64.zip"

# Entpacken der dbru Datei
if [[ -f "$dbru_zip" ]]; then
    echo "Entpacke $dbru_zip nach /tmp/oracle/1926/dbru..."
    unzip -q "$dbru_zip" -d "/tmp/oracle/1926/dbru"
else
    echo "Fehler: dbru ZIP-Datei $dbru_zip nicht gefunden. Bitte prüfen Sie den Pfad."
    exit 1
fi

# Entpacken der ojvm Datei
if [[ -f "$ojvm_zip" ]]; then
    echo "Entpacke $ojvm_zip nach /tmp/oracle/1926/ojvm..."
    unzip -q "$ojvm_zip" -d "/tmp/oracle/1926/ojvm"
else
    echo "Fehler: ojvm ZIP-Datei $ojvm_zip nicht gefunden. Bitte prüfen Sie den Pfad."
    exit 1
fi

# Besitzerrechte erneut setzen
echo "Setze Besitzerrechte für /tmp/oracle..."
chown -R "$username":oinstall /tmp/oracle

# ~/.profile für den Benutzer anpassen
echo "Bearbeite ~/.profile für den Benutzer $username..."

profile_path="/home/$username/.profile"

# Sicherstellen, dass die Datei existiert
if [[ ! -f "$profile_path" ]]; then
    echo "Fehler: Datei $profile_path nicht gefunden."
    exit 1
fi

# Füge Oracle-Umgebungsvariablen und andere Parameter hinzu
{
    echo "export TMP=/tmp"
    echo "export TMPDIR=\${TMP}"
    echo "# Oracle Parameter"
    echo "export ORACLE_HOSTNAME=$oracle_hostname"
    echo "export ORACLE_UNQNAME=$oracle_sid"
    echo "export ORACLE_BASE=/oracle/$oracleverzeichnis"
    echo "export ORACLE_HOME=\${ORACLE_BASE}/product/19c"
    echo "export OH=\${ORACLE_HOME}"
    echo "export ORACLE_SID=$oracle_sid"
    echo "TNS_ADMIN=\${ORACLE_HOME}/network/admin"
    echo "export TNS_ADMIN"
    echo "ORATAB=/etc/oratab"
    echo "export ORATAB"
    echo "export JAVA_HOME=/usr/lib64/jvm/jre-21-openjdk"
    echo ""
    echo "export PATH=/usr/sbin:/usr/local/bin:\${PATH}"
    echo "export PATH=\${ORACLE_HOME}/bin:\${PATH}"
    echo "export PATH=\${JAVA_HOME}/bin:\${PATH}"
    echo ""
    echo "export LD_LIBRARY_PATH=\${ORACLE_HOME}/lib:/lib:/usr/lib"
    echo "export CLASSPATH=\${ORACLE_HOME}/jlib:\${ORACLE_HOME}/rdbms/jlib"
    echo ""
    echo "# OPatch aktivieren"
    echo "export PATH=\${OH}/OPatch:\${PATH}"
    echo ""
    echo "# Consolen Pfad"
    echo 'PS1="\033[0;31m\]$ORACLE_HOSTNAME:\$PWD\$ # \[\033[1;37m\]"'
    echo "export PS1"
    echo ""
    echo 'if [ -d $ORACLE_HOME/bin ]'
    echo 'then'
    echo '  cd $ORACLE_HOME/bin'
    echo 'else'
    echo '  cd'
    echo 'fi'
    echo ""
    echo "# DISPLAY"
    echo "export DISPLAY=\$DISPLAY"
    echo ""
    echo "echo " " "
    echo "echo "Der User \$USER verwaltet folgende Oracle Umgebung:""
    echo "echo """
    echo "echo "Oracle_SID=\$ORACLE_SID""
    echo "echo "ORACLE_HOME=\$OH""
    echo "echo """
    echo "echo "DISPLAY=\$DISPLAY""
    echo "echo """
    echo "echo """
} >> "$profile_path"

# Zeigen Sie an, dass die Änderungen vorgenommen wurden
echo "~/.profile für den Benutzer $username wurde erfolgreich angepasst."

# Maschine an RMT Server registrieren:
curl --insecure https://rmtserver.domain.tld/tools/rmt-client-setup --output rmt-client-setup
sh rmt-client-setup https://rmtserver/

# Installation der Pakete mit zypper
echo "Installiere benoetigte Pakete..."
zypper install -y bc
zypper install -y binutils
zypper install -y glibc
zypper install -y glibc-devel
zypper install -y insserv-compat
zypper install -y libaio-devel
zypper install -y libaio1
zypper install -y libX11-6
zypper install -y libXau6
zypper install -y libXext-devel
zypper install -y libXext6
zypper install -y libXi-devel
zypper install -y libXi6
zypper install -y libXrender-devel
zypper install -y libXrender1
zypper install -y libXtst6
zypper install -y libcap-ng-utils
zypper install -y libcap-ng0
zypper install -y libcap-progs
zypper install -y libcap11
zypper install -y libcap2
zypper install -y libelf1
zypper install -y libgcc_s1
zypper install -y libjpeg8
zypper install -y libpcap1
zypper install -y libpcre1
zypper install -y libpcre16-0
zypper install -y libpng16-16
zypper install -y libstdc++6
zypper install -y libtiff5
zypper install -y libgfortran4
zypper install -y mksh
zypper install -y make
zypper install -y pixz
zypper install -y rdma-core
zypper install -y rdma-core-devel
zypper install -y smartmontools
zypper install -y sysstat
zypper install -y xorg-x11-libs
zypper install -y xz
zypper install -y java-21-openjdk

echo "Pakete wurden erfolgreich installiert."

# Swap-Dateigröße abfragen
read -p "Geben Sie die Größe des Swapfiles in GB an: " gbswap

# Überprüfen, ob die Eingabe gültig ist
if [[ ! "$gbswap" =~ ^[0-9]+$ ]] || [[ "$gbswap" -le 0 ]]; then
    echo "Fehler: Ungültige Swap-Größe. Bitte geben Sie eine positive ganze Zahl ein."
    exit 1
fi

# Swap-Datei erstellen
echo "Erstelle Swap-Datei mit $gbswap GB..."
mkdir -p /var/lib/swap
dd if=/dev/zero of=/var/lib/swap/swapfile bs=1G count="$gbswap"
chmod 0600 /var/lib/swap/swapfile
mkswap /var/lib/swap/swapfile
swapon /var/lib/swap/swapfile

# fstab-Eintrag für Autostart hinzufügen (wenn nicht bereits vorhanden)
if ! grep -q "/var/lib/swap/swapfile" /etc/fstab; then
    echo "/var/lib/swap/swapfile swap swap defaults 0 0" >> /etc/fstab
    echo "Swapfile wurde in /etc/fstab eingetragen."
else
    echo "Swapfile ist bereits in /etc/fstab eingetragen."
fi

echo "Swap-Datei wurde erfolgreich erstellt und aktiviert."

# RAM-Größe auslesen und Berechnungen durchführen
ram_kb=$(cat /proc/meminfo | grep MemTotal | awk '{print $2}')
ram_gb=$((ram_kb / 1024 / 1024))

# RAM-Größe in GB ausgeben
echo "Gesamt-RAM: $ram_gb GB"

# Berechnungen für shmall und shmmax
shmall=$(echo "scale=0; ($ram_gb * 1024 * 1024 * 1024) / 4096" | bc)
shmmax=$(echo "scale=0; ($ram_gb * 1024 * 1024 * 1024) / 2" | bc)

echo "shmall: $shmall"
echo "shmmax: $shmmax"

# Ergänzen der Zeilen in /etc/sysctl.conf
echo "Füge Oracle-spezifische Kernel-Parameter in /etc/sysctl.conf hinzu..."
{
    echo "# Oracle"
    echo "fs.suid_dumpable = 1"
    echo "fs.aio-max-nr = 1048576"
    echo "fs.file-max = 6815744"
    echo "kernel.panic_on_oops = 1"
    echo "kernel.shmall = $shmall"
    echo "kernel.shmmax = $shmmax"
    echo "kernel.shmmni = 4096"
    echo "kernel.sem = 250 32000 100 128"
    echo "net.ipv4.ip_local_port_range = 9000 65500"
    echo "net.core.rmem_default = 4194304"
    echo "net.core.rmem_max = 4194304"
    echo "net.core.wmem_default = 4194304"
    echo "net.core.wmem_max = 4194304"
    echo "vm.max_map_count = 655360"
} >> /etc/sysctl.conf

# Sysctl anwenden
echo "Wende Sysctl-Änderungen an..."
sysctl -p

# Anzeige der DISPLAY-Variable
echo "DISPLAY Variable: $DISPLAY"

# Ausgabe von xauth list
echo "xauth list:"
xauth list

#Ausgabe vom Installationsbefehl als Oracle User
echo "Als $username ausfuehren: cd $oracle_dir "
echo "export DISPLAY=localhost:xx.0"
echo "xauth add etc. pp"
echo "./runInstaller -applyRU /tmp/oracle/1926/dbru/37260974"


# Installation abgeschlossen
echo "Installation abgeschlossen."

