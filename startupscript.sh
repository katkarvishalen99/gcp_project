#!/bin/bash
sudo apt-get update
sudo apt-get install -y apache2
systemctl start apache2
systemctl enable apache2
#echo "<html><body>Hello, from ${hostname} server </body></html>" > /var/www/html/index.html
curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh && sudo bash add-google-cloud-ops-agent-repo.sh --also-install
