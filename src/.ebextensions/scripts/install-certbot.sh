#!/bin/bash
cert_type=$(/opt/elasticbeanstalk/bin/get-config environment -k CERT_TYPE)
cert_email=$(/opt/elasticbeanstalk/bin/get-config environment -k CERT_EMAIL)
cert_domain=$(/opt/elasticbeanstalk/bin/get-config environment -k CERT_DOMAIN)
eb_env=$(/opt/elasticbeanstalk/bin/get-config container -k environment_name)
region=$(/opt/aws/bin/ec2-metadata -z | awk '{print substr($2, 0, length($2)-1)}')
eb_url=$(aws elasticbeanstalk describe-environments --region ${region} --environment-names ${eb_env} | jq -r '.Environments[0].CNAME')

if  [ ${cert_domain} == "None" ]; then
   cert_domain=${eb_url}
   sed -i "s/server_name .*;/server_name ${cert_domain};/" /etc/nginx/conf.d/http-https-proxy.conf
fi

if [[ "$cert_type" == "None" ]] || [[ "$cert_type" == "" ]]; then
   echo "do not install ssl cert, use stub cert"
   #cp -a .ebextensions/platform/options-ssl-nginx.conf /etc/letsencrypt/
   #cp -a .ebextensions/platform/ssl-dhparams.pem /etc/letsencrypt/
   #cp -a .platform/nginx/conf.d/http-https-proxy.conf /etc/nginx/conf.d/
   exit 0
fi
if [[ "$cert_type" != "production" ]]; then
# !! --test-cert: REMOVE FOR PRODUCTION, use the staging server for the certificate !!
staging=--test-cert
fi
[[ ! -e /etc/letsencrypt/accounts ]] && ls /etc/letsencrypt -al
#remove stub files, can't do this as certbot needs function nginx but the configure already is with ssl
#should restore a non-ssl version of /etc/nginx/conf.d/http-https-proxy.conf if this needs to be removed
[[ ! -e /etc/letsencrypt/accounts ]] && sed -i 's/^.*managed by Certbot.*$//' /etc/nginx/conf.d/http-https-proxy.conf
[[ ! -e /etc/letsencrypt/accounts ]] && rm -f /etc/letsencrypt/* 
sed -i "s/server_name .*;/server_name ${cert_domain};/" /etc/nginx/conf.d/http-https-proxy.conf
# cater for case of super long domain name generated automatically
sed -i "s/types_hash_max_size 4096;$/types_hash_max_size 4096;server_names_hash_bucket_size 128;/" /etc/nginx/nginx.conf
certbot $staging --debug --non-interactive --redirect --agree-tos --nginx --email ${cert_email} --domains ${cert_domain} --keep-until-expiring
#make the modified http-https-proxy.conf listen on 80/443(certbot make it 443 only which is not good for behind ALB
sed -i 's/listen 443 ssl;/listen 80; listen 443 ssl;/' /etc/nginx/conf.d/http-https-proxy.conf
#enable ssl redirection
#sed -i 's/set \$ssl N;/set $ssl Y;/' /etc/nginx/conf.d/http-https-proxy.conf
#4. make a copy of the modified .conf to platform(disappeared after deploy !!, restore via postdeploy hook)
#mkdir -p /tmp/nginx/conf.d && cp -a /etc/nginx/conf.d/http-https-proxy.conf /tmp/nginx/conf.d/
#5 also save it to /tmp, urber important
if [[ "$cert_type" == "production" ]]; then
	dos2unix .ebextensions/scripts/import-certificate.sh && /bin/bash .ebextensions/scripts/import-certificate.sh
fi
cp -a /etc/nginx/conf.d/http-https-proxy.conf /tmp/  
[[ -e /etc/letsencrypt/live/${cert_domain} ]] && ln -nsf ${cert_domain} /etc/letsencrypt/live/default
#[[ -e /etc/letsencrypt/live/${cert_domain} ]] && cp -a /etc/letsencrypt/live/${cert_domain}/* /etc/letsencrypt/live/acme.local/

