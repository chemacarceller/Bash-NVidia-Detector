# Bash-NVidia-Detector

This utility, written in the bash shell, detects if an Nvidia graphics card is installed on your PC. If so, it will install the latest drivers.

We have the file detector-nvidia.sh, which we will place in the /usr/local/bin/ directory.

Then we will execute the following commands:

sudo chmod 755 /usr/local/bin/detector-nvidia.sh  <br/>

sudo chown root:root /usr/local/bin/detector-nvidia.sh

We also have the file nvidia-autoinstall.service, which we will place in /etc/systemd/system/.

The Systemd service file /etc/systemd/system/nvidia-autoinstall.service must belong to root:root and have the standard 644 permissions (rw-r--r--).

sudo chmod 644 /etc/systemd/system/nvidia-autoinstall.service    <br/>
sudo chown root:root /etc/systemd/system/nvidia-autoinstall.service

Update the Systemd daemon and enable the service to run on the next reboot:

sudo systemctl daemon-reload    <br/>
sudo systemctl enable nvidia-autoinstall.service

Don't forget to delete the files /var/log/nvidia_autoinstall.log and /var/local/nvidia_success.flag when creating an image. The first one simply clears the contents of previous executions, while the second is the success flag for the execution; it must be deleted, otherwise the script will never run when restoring the image on another PC.

==========================================================================================

Esta utilidad escrita en shell bash permite detectar si el PC tiene instalada una tarjeta NVidia, en cuyo caso se instalarían los drivers más actuales

Tenemos el fichero detector-nvidia.sh que colocaremos en el directorio /usr/local/bin/

Ejecutaremos entonces los siguientes comandos :

sudo chmod 755 /usr/local/bin/detector-nvidia.sh    <br/>
sudo chown root:root /usr/local/bin/detector-nvidia.sh

Tenemos el fichero nvidia-autoinstall.service  que colocaremos en /etc/systemd/system/

El archivo del servicio de Systemd /etc/systemd/system/nvidia-autoinstall.service debe pertenecer obligatoriamente a root:root y tener los permisos estándar 644 (rw-r--r--).

sudo chmod 644 /etc/systemd/system/nvidia-autoinstall.service    <br/>
sudo chown root:root /etc/systemd/system/nvidia-autoinstall.service

No olvides eliminar los archivos /var/log/nvidia_autoinstall.log , /var/local/nvidia_success.flag en el caso de hacer una imagen, el primero simplemente para vaciar contenido de ejecuciones anteriores, mientras que el segundo es el flag de exito de la ejecución, hay que eliminarlo, sino el script nunca se ejecutaría al restaurar la imagen en otro pc

Actualiza el demonio de Systemd y activa el servicio para que se ejecute en el próximo reinicio: 

sudo systemctl daemon-reload   <br/>
sudo systemctl enable nvidia-autoinstall.service
