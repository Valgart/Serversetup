apt update
apt upgrade -y
apt install curl git npm -y
npm install pm2 -g
curl -fsSL https://get.Docker.com -o get-Docker.sh
sudo sh get-Docker.sh
sudo usermod -aG docker $USER
newgrp docker
