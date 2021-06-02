#!/bin/sh

sssd_config_path=/etc/sssd/sssd.conf
smb_config_path=/etc/samba/smb.conf

script_help(){
	echo "
	-s/--server-ip ip      LDAP server ip.
	-b/--baseDN  dn        LDAP dn.
	-u/--user user         LDAP user.  
	-w/--ldappw pw         LDAP admin passwd.
	-p/--passwd pw         samba user passwd.
	"
	exit 0
}

command_exist(){
	command -v $@ > /dev/null 2>&1 
}

if [ $# -lt 8 ];then
	script_help
	exit 1
fi


while [ $# -ge 2 ] ; do
	case "$1" in
		-s|--server-ip)
			server_ip=$2;shift 2
		;;

		-b|--baseDN)
			baseDN=$2;shift 2
		;;

		-u|--user)
			ldap_user=$2;shift 2
		;;
		-w|--ldappw)
			ldap_passwd=$2;shift 2
		;;
		-p|--passwd)
			smb_passwd=$2;shift 2
		;;
		-h|--help)
			script_help
		;;
		--)
			break
		;;
		*)                                                                  
		        printf "Unknown option %s\n" "$1"                           
			exit 1                                                 
		;;
	esac
done

if [ -z "$server_ip" ];then
	echo "parameter error. the IP of the ldap server cannot be empty."
	exit 1
elif [ -z "$baseDN" ];then
	echo "parameter error. the ldap domain must be specified. "
	exit 1
elif [ -z "$ldap_user" ];then
	echo "parameter error. the ldap user must be specified."
	exit 1
elif [ -z "$ldap_passwd" ];then
	echo "parameter error. the ldap admin passwd must be specified."
	exit 1
elif [ -z "$smb_passwd" ];then
	if ! command_exist ldapsearch ; then
		dnf install  openldap openldap-clients openldap-servers -y &>/dev/null
		if [ $? -ne 0 ];then
			echo "install openldap error!!!"
		fi
	fi 

	id=$(ldapsearch -x -b "uid=$ldap_user,ou=People,$baseDN" -H ldap://$server_ip | grep sambaSID | awk '{print $2}')
	if [ -z "$id" ];then
		echo "parameter error, the samba passwd must be specified."
		exit 1
	fi
fi

install_sssd()
{
	if [ `rpm -qa | grep sssd | wc -l` -eq 0 ];then
		
		dnf install sssd -y &> /dev/null
		if [ $? != 0 ];then
			echo "install sssd error!!!"
			exit 1
		fi
	fi
}


sssd_config()
{
cat > $sssd_config_path << EOF 
[main/default]
id_provider = ldap
autofs_provider = ldap
auth_provider = ldap
chpass_provider = ldap
ldap_uri = ldap://$server_ip
ldap_search_base = $baseDN
ldap_id_use_start_tls = False 
cache_credentials = False

[sssd]
services = nss, pam, autofs
domains = default

[nss]
homedir_substring = /home
EOF
	if ! command_exist authselect ;then
		mkdir -p /etc/authselect
		authselect select sssd with-mkhomedir --force &> /dev/null
	fi
}

install_mkhomedir()
{

	if [ `rpm -qa | grep oddjob | wc -l` -eq 0 ];then
		dnf install oddjob-mkhomedir -y &> /dev/null
		if [ $? != 0 ];then
			echo "install oddjob-mkhomedir error!!!"
			exit 1
		fi
	fi
	systemctl enable oddjobd
	echo "session optional pam_oddjob_mkhomedir.so skel=/etc/skel/ umask=0022" >> /etc/pam.d/system-auth
	systemctl restart oddjobd

}

start_sssd()
{
	sssctl config-check &> /dev/null
	chown -R root: /etc/sssd
	chmod 600 -R /etc/sssd
	systemctl enable --now sssd
	systemctl restart sssd
}

samba_config(){
	if ! command_exist smbd ;then
		dnf install samba samba-common -y &>/dev/null
		if [ $? != 0 ];then
			echo "install samba error!!!"
			exit 1
		fi
	fi

	grep "passdb backend" $smb_config_path &> /dev/null
	if [ $? -ne 0 ];then
		sed -i '/global/a\passdb backend = ldapsam:ldap://'$server_ip'' $smb_config_path
	else
		sed -i 's!passdb backend.*$!passdb backend = ldapsam:ldap://'$server_ip'!g' $smb_config_path
	fi

	grep "ldap suffix" $smb_config_path &> /dev/null
	if [ $? -ne 0 ];then
		sed -i '/passdb backend/a\ldap suffix = '$baseDN' ' $smb_config_path
	else
		sed -i 's!ldap suffix.*$!ldap suffix = '$baseDN'!g' $smb_config_path
	fi

	grep "ldap user suffix" $smb_config_path &> /dev/null
	if [ $? -ne 0 ];then
		sed -i '/ldap suffix/a\ldap user suffix = ou=People' $smb_config_path
	else
		sed -i 's!ldap user suffix.*$!ldap user suffix = ou=People!g' $smb_config_path
	fi

	grep "ldap group suffix" $smb_config_path &> /dev/null
	if [ $? -ne 0 ] ;then
		sed -i '/ldap user suffix/a\ldap group suffix = ou=Groups' $smb_config_path
	else
		sed -i 's!ldap group suffix.*$!ldap group suffix = ou=Groups!g' $smb_config_path
	fi

	grep "ldap admin dn" $smb_config_path &> /dev/null
	if [ $? -ne 0 ];then
		sed -i '/ldap group suffix/a\ldap admin dn = cn=Manager,'$baseDN'' $smb_config_path
	else
		sed -i 's!ldap admin dn.*$!ldap admin dn = cn=Manager,'$baseDN'!g' $smb_config_path
	fi

	grep "ldap ssl" $smb_config_path &> /dev/null 
	if [ $? -ne 0 ];then
		sed -i '/ldap admin dn/a\ldap ssl = no' $smb_config_path
	else
		sed -i 's!ldap ssl.*$!ldap ssl = no!g' $smb_config_path
	fi

	smbpasswd -w $ldap_passwd &> /dev/null
	systemctl restart smb

}


pdbedit_user(){
	if ! command_exist ldapsearch ;then
		dnf install  openldap openldap-clients openldap-servers -y &>/dev/null
		if [ $? -ne 0 ];then
			echo "install openldap error!!!"
			exit 1
		fi
	fi

	user_sid=$(ldapsearch -x -b "uid=$ldap_user,ou=People,$baseDN" -H ldap://$server_ip | grep sambaSID | awk '{print $2}')
	if [ -n "$user_sid" ];then
		sid=${user_sid%-*}
		host=$(echo `hostname` | tr '[:lower:]' '[:upper:]') 
		host_sid=$(ldapsearch -x -b "sambaDomainName=$host,$baseDN" -H ldap://$server_ip  | grep sambaSID | awk '{print $2}')
		if [ $sid != $host_sid ];then
cat > /root/ldap_modify_sid.ldif << EOF
dn: sambaDomainName=$host,$baseDN
changetype: modify
replace: sambaSID
sambaSID: $sid 
EOF
			ldapmodify -axcD "cn=Manager,$baseDN" -w 123456 -H ldap://$server_ip -f /root/ldap_modify_sid.ldif &> /dev/null
			if [ $? != 0 ];then 
				echo "ldapmodify error!!!"
			fi
			rm -rf /root/ldap_modify_sid.ldif
		fi
	else
		if ! command_exist  expect ; then
			dnf install expect -y &> /dev/null
			if [ $? != 0 ];then
				echo "install expect error!!!"
			fi
		fi

		/usr/bin/expect <<-EOF
		set timeout -1
		spawn pdbedit -a $ldap_user &> /dev/null 
		expect {
			"*new password" { send "$smb_passwd\r"; exp_continue }
			"*retype new password:" { send "$smb_passwd\r" }
		}
		EOF

	fi
}

start_smb(){
	systemctl restart smb
}

install_sssd
sssd_config
install_mkhomedir
start_sssd
samba_config
pdbedit_user
start_smb
