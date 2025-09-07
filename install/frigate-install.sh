#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Authors: MickLesk (CanbiZ)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://frigate.video/

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies (Patience)"
$STD apt-get install -y {git,ca-certificates,automake,build-essential,xz-utils,libtool,ccache,pkg-config,libgtk-3-dev,libavcodec-dev,libavformat-dev,libswscale-dev,libv4l-dev,libxvidcore-dev,libx264-dev,libjpeg-dev,libpng-dev,libtiff-dev,gfortran,openexr,libatlas-base-dev,libssl-dev,libtbb-dev,libdc1394-dev,libopenexr-dev,libgstreamer-plugins-base1.0-dev,libgstreamer1.0-dev,gcc,gfortran,libopenblas-dev,liblapack-dev,libusb-1.0-0-dev,jq,moreutils}
msg_ok "Installed Dependencies"

msg_info "Setup Python3"
$STD apt-get install -y {python3,python3-dev,python3-setuptools,python3-distutils,python3-pip,python3-venv}
$STD pip install --upgrade pip
msg_ok "Setup Python3"

NODE_VERSION="22" NODE_MODULE="yarn" setup_nodejs
fetch_and_deploy_gh_release "go2rtc" "AlexxIT/go2rtc" "singlefile" "latest" "/usr/local/go2rtc/bin" "go2rtc_linux_amd64"
fetch_and_deploy_gh_release "frigate" "blakeblackshear/frigate" "tarball" "latest" "/opt/frigate"
fetch_and_deploy_gh_release "libusb" "libusb/libusb" "tarball" "v1.0.29" "/opt/frigate/libusb"

# msg_info "Setting Up Hardware Acceleration"
# $STD apt-get -y install {va-driver-all,ocl-icd-libopencl1,intel-opencl-icd,vainfo,intel-gpu-tools}
# if [[ "$CTTYPE" == "0" ]]; then
#   chgrp video /dev/dri
#   chmod 755 /dev/dri
#   chmod 660 /dev/dri/*
# fi
# msg_ok "Set Up Hardware Acceleration"

msg_info "Setting up Python"
cd /opt/frigate
mkdir -p /opt/frigate/models
$STD pip3 wheel --wheel-dir=/wheels -r /opt/frigate/docker/main/requirements-wheels.txt
cp -a /opt/frigate/docker/main/rootfs/. /
export TARGETARCH="amd64"
echo 'libc6 libraries/restart-without-asking boolean true' | debconf-set-selections
$STD apt update
$STD ln -svf /usr/lib/btbn-ffmpeg/bin/ffmpeg /usr/local/bin/ffmpeg
$STD ln -svf /usr/lib/btbn-ffmpeg/bin/ffprobe /usr/local/bin/ffprobe
$STD pip3 install -U /wheels/*.whl
ldconfig
$STD pip3 install -r /opt/frigate/docker/main/requirements-dev.txt
$STD /opt/frigate/.devcontainer/initialize.sh
$STD make version
msg_ok "Python venv ready"

msg_info "Building Web UI"
cd /opt/frigate/web
$STD npm ci
$STD npm run build
cp -r /opt/frigate/web/dist/* /opt/frigate/web/
cp -r /opt/frigate/config/. /config
msg_ok "Web UI built"

msg_info "Writing default config"
sed -i '/^s6-svc -O \.$/s/^/#/' /opt/frigate/docker/main/rootfs/etc/s6-overlay/s6-rc.d/frigate/run
mkdir -p /opt/frigate/config
cat <<EOF >/opt/frigate/config/config.yml
mqtt:
  enabled: false
cameras:
  test:
    ffmpeg:
      inputs:
        - path: /media/frigate/person-bicycle-car-detection.mp4
          input_args: -re -stream_loop -1 -fflags +genpts
          roles:
            - detect
            - rtmp
    detect:
      height: 1080
      width: 1920
      fps: 5
EOF
mkdir -p /config
ln -sf /config/config.yml /opt/frigate/config/config.yml
if [[ "$CTTYPE" == "0" ]]; then
  sed -i -e 's/^kvm:x:104:$/render:x:104:root,frigate/' -e 's/^render:x:105:root$/kvm:x:105:/' /etc/group
else
  sed -i -e 's/^kvm:x:104:$/render:x:104:frigate/' -e 's/^render:x:105:$/kvm:x:105:/' /etc/group
fi
echo "tmpfs   /tmp/cache      tmpfs   defaults        0       0" >>/etc/fstab
mkdir -p /media/frigate
wget -qO /media/frigate/person-bicycle-car-detection.mp4 https://github.com/intel-iot-devkit/sample-videos/raw/master/person-bicycle-car-detection.mp4
cat <<'EOF' >/opt/frigate/frigate/version.py
VERSION = "0.16.0"
EOF
msg_ok "Config ready"

if grep -q -o -m1 -E 'avx[^ ]*' /proc/cpuinfo; then
  msg_ok "AVX Support Detected"
  msg_info "Installing Openvino Object Detection Model (Resilience)"
  $STD pip install -r /opt/frigate/docker/main/requirements-ov.txt
  cd /opt/frigate/models
  export ENABLE_ANALYTICS=NO
  $STD /usr/local/bin/omz_downloader --name ssdlite_mobilenet_v2 --num_attempts 2
  $STD /usr/local/bin/omz_converter --name ssdlite_mobilenet_v2 --precision FP16 --mo /usr/local/bin/mo
  cd /
  cp -r /opt/frigate/models/public/ssdlite_mobilenet_v2 openvino-model
  curl -fsSL "https://github.com/openvinotoolkit/open_model_zoo/raw/master/data/dataset_classes/coco_91cl_bkgr.txt" -o "openvino-model/coco_91cl_bkgr.txt"
  sed -i 's/truck/car/g' openvino-model/coco_91cl_bkgr.txt
  cat <<EOF >>/config/config.yml
detectors:
  ov:
    type: openvino
    device: CPU
    model:
      path: /openvino-model/FP16/ssdlite_mobilenet_v2.xml
model:
  width: 300
  height: 300
  input_tensor: nhwc
  input_pixel_format: bgr
  labelmap_path: /openvino-model/coco_91cl_bkgr.txt
EOF
  msg_ok "Installed Openvino Object Detection Model"
else
  cat <<EOF >>/config/config.yml
model:
  path: /cpu_model.tflite
EOF
fi

msg_info "Building and Installing libUSB without udev"
wget -qO /tmp/libusb.zip https://github.com/libusb/libusb/archive/v1.0.29.zip
unzip -q /tmp/libusb.zip -d /tmp/
cd /tmp/libusb-1.0.29
./bootstrap.sh
./configure --disable-udev --enable-shared
make -j$(nproc --all)
make install
ldconfig
rm -rf /tmp/libusb.zip /tmp/libusb-1.0.29
msg_ok "Installed libUSB without udev"

msg_info "Installing Coral Object Detection Model (Patience)"
cd /opt/frigate
export CCACHE_DIR=/root/.ccache
export CCACHE_MAXSIZE=2G
curl -fsSL "https://github.com/libusb/libusb/archive/v1.0.26.zip" -o "v1.0.26.zip"
$STD unzip v1.0.26.zip
rm v1.0.26.zip
cd libusb-1.0.26
$STD ./bootstrap.sh
$STD ./configure --disable-udev --enable-shared
$STD make -j $(nproc --all)
cd /opt/frigate/libusb-1.0.26/libusb
mkdir -p /usr/local/lib
$STD /bin/bash ../libtool --mode=install /usr/bin/install -c libusb-1.0.la '/usr/local/lib'
mkdir -p /usr/local/include/libusb-1.0
$STD /usr/bin/install -c -m 644 libusb.h '/usr/local/include/libusb-1.0'
ldconfig
cd /
curl -fsSL "https://github.com/google-coral/test_data/raw/release-frogfish/ssdlite_mobiledet_coco_qat_postprocess_edgetpu.tflite" -o "edgetpu_model.tflite"
curl -fsSL "https://github.com/google-coral/test_data/raw/release-frogfish/ssdlite_mobiledet_coco_qat_postprocess.tflite" -o "cpu_model.tflite"
cp /opt/frigate/labelmap.txt /labelmap.txt
curl -fsSL "https://www.kaggle.com/api/v1/models/google/yamnet/tfLite/classification-tflite/1/download" -o "yamnet-tflite-classification-tflite-v1.tar.gz"
tar xzf yamnet-tflite-classification-tflite-v1.tar.gz
rm -rf yamnet-tflite-classification-tflite-v1.tar.gz
mv 1.tflite cpu_audio_model.tflite
cp /opt/frigate/audio-labelmap.txt /audio-labelmap.txt
mkdir -p /media/frigate
curl -fsSL "https://github.com/intel-iot-devkit/sample-videos/raw/master/person-bicycle-car-detection.mp4" -o "/media/frigate/person-bicycle-car-detection.mp4"
msg_ok "Installed Coral Object Detection Model"

# ------------------------------------------------------------
# Tempio installieren
msg_info "Installing Tempio"
sed -i 's|/rootfs/usr/local|/usr/local|g' /opt/frigate/docker/main/install_tempio.sh
export TARGETARCH="amd64"
export DEBIAN_FRONTEND=noninteractive
echo "libedgetpu1-max libedgetpu/accepted-eula select true" | debconf-set-selections
echo "libedgetpu1-max libedgetpu/install-confirm-max select true" | debconf-set-selections
$STD /opt/frigate/docker/main/install_tempio.sh
chmod +x /usr/local/tempio/bin/tempio
ln -sf /usr/local/tempio/bin/tempio /usr/local/bin/tempio
msg_ok "Installed Tempio"

# msg_info "Copying model files"
# cp /opt/frigate/cpu_model.tflite /
# cp /opt/frigate/edgetpu_model.tflite /
# cp /opt/frigate/audio-labelmap.txt /
# cp /opt/frigate/labelmap.txt /
# msg_ok "Copied model files"

msg_info "Building Nginx with Custom Modules"
sed -i 's/if \[\[ "$VERSION_ID" == "12" \]\]; then/if [[ -f \/etc\/apt\/sources.list.d\/debian.sources ]]; then/' /opt/frigate/docker/main/build_nginx.sh
$STD /opt/frigate/docker/main/build_nginx.sh
sed -e '/s6-notifyoncheck/ s/^#*/#/' -i /opt/frigate/docker/main/rootfs/etc/s6-overlay/s6-rc.d/nginx/run
ln -sf /usr/local/nginx/sbin/nginx /usr/local/bin/nginx
msg_ok "Built Nginx"

msg_info "Creating Services"
cat <<EOF >/etc/systemd/system/create_directories.service
[Unit]
Description=Create necessary directories for logs

[Service]
Type=oneshot
ExecStart=/bin/bash -c '/bin/mkdir -p /dev/shm/logs/{frigate,go2rtc,nginx} && /bin/touch /dev/shm/logs/{frigate/current,go2rtc/current,nginx/current} && /bin/chmod -R 777 /dev/shm/logs'

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now create_directories
sleep 3
cat <<EOF >/etc/systemd/system/go2rtc.service
[Unit]
Description=go2rtc service
After=network.target
After=create_directories.service
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=1
User=root
Environment=DEFAULT_FFMPEG_VERSION=7.0
Environment=INCLUDED_FFMPEG_VERSIONS=5.0
ExecStartPre=+rm /dev/shm/logs/go2rtc/current
ExecStart=/bin/bash -c "bash /opt/frigate/docker/main/rootfs/etc/s6-overlay/s6-rc.d/go2rtc/run 2> >(/usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S ' >&2) | /usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S '"
StandardOutput=file:/dev/shm/logs/go2rtc/current
StandardError=file:/dev/shm/logs/go2rtc/current

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now go2rtc
sleep 3
cat <<EOF >/etc/systemd/system/frigate.service
[Unit]
Description=Frigate service
After=go2rtc.service
After=create_directories.service
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=1
User=root
# Environment=PLUS_API_KEY=
Environment=DEFAULT_FFMPEG_VERSION=7.0
Environment=INCLUDED_FFMPEG_VERSIONS=5.0
ExecStartPre=+rm /dev/shm/logs/frigate/current
ExecStart=/bin/bash -c "bash /opt/frigate/docker/main/rootfs/etc/s6-overlay/s6-rc.d/frigate/run 2> >(/usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S ' >&2) | /usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S '"
StandardOutput=file:/dev/shm/logs/frigate/current
StandardError=file:/dev/shm/logs/frigate/current

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now frigate
sleep 3
cat <<EOF >/etc/systemd/system/nginx.service
[Unit]
Description=Nginx service
After=frigate.service
After=create_directories.service
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=1
User=root
ExecStartPre=+rm /dev/shm/logs/nginx/current
ExecStart=/bin/bash -c "bash /opt/frigate/docker/main/rootfs/etc/s6-overlay/s6-rc.d/nginx/run 2> >(/usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S ' >&2) | /usr/bin/ts '%%Y-%%m-%%d %%H:%%M:%%.S '"
StandardOutput=file:/dev/shm/logs/nginx/current
StandardError=file:/dev/shm/logs/nginx/current

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now nginx
msg_ok "Configured Services"
