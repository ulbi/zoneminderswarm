# Use the official Ubuntu 20.04 LTS as the base image for building OpenCV
FROM ubuntu:22.04 as opencv_builder

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV OPENCV_VERSION=4.6.0

# Update the package list and install required packages
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    pkg-config \
    libjpeg-dev \
    libtiff-dev \
    libpng-dev \
    libavcodec-dev \
    libavformat-dev \
    libswscale-dev \
    libv4l-dev \
    libxvidcore-dev \
    libx264-dev \
    libgtk-3-dev \
    libatlas-base-dev \
    gfortran \
    python3-dev \
    wget \
    unzip

# Download, build, and install OpenCV
RUN cd /opt && \
    wget -O opencv.zip https://github.com/opencv/opencv/archive/${OPENCV_VERSION}.zip && \
    wget -O opencv_contrib.zip https://github.com/opencv/opencv_contrib/archive/${OPENCV_VERSION}.zip && \
    unzip opencv.zip && \
    unzip opencv_contrib.zip && \
    mkdir /opt/opencv-${OPENCV_VERSION}/build && \
    cd /opt/opencv-${OPENCV_VERSION}/build && \
    cmake -D CMAKE_BUILD_TYPE=RELEASE \
          -D CMAKE_INSTALL_PREFIX=/usr/local \
          -D OPENCV_EXTRA_MODULES_PATH=/opt/opencv_contrib-${OPENCV_VERSION}/modules \
          -D BUILD_DOCS=OFF \
          -D BUILD_EXAMPLES=OFF \
          -D BUILD_TESTS=OFF \
          -D BUILD_PERF_TESTS=OFF \
          -D BUILD_opencv_python3=ON \
          -D BUILD_opencv_python2=OFF \
          -D WITH_CUDA=OFF \
          -D ENABLE_FAST_MATH=1 \
          -D WITH_CUBLAS=1 \
          -D WITH_TBB=ON \
          /opt/opencv-${OPENCV_VERSION} && \
    make -j$(nproc) && \
    make install && \
    ldconfig

FROM ubuntu:22.04

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV ZONEMINDERVERSION=1.36

# Update the package list and install required packages
RUN apt-get update && apt-get install -y \
    software-properties-common \
    wget \
    git \
    libmysqlclient-dev \
    mysql-client 

RUN apt-get upgrade -y
RUN apt-get install -y \
    python3-pip \
    python3-dev \
    python3-setuptools \
    python3-wheel \
    python3-mysql.connector \
    netcat \
    curl
#RUN pip3 install face_recognition
COPY --from=opencv_builder /usr/local /usr/local
# Install ZoneMinder and other required packages
RUN add-apt-repository -y ppa:iconnor/zoneminder-${ZONEMINDERVERSION}
RUN apt-get update 
RUN apt-get install -y \
    zoneminder 
RUN apt-get remove mysql-server && \
    apt-get autoremove
RUN apt-get install -y \
    vim

# Install the event notification server and the AI face recognition dependencies
RUN apt-get install -y \
    libmodule-build-perl \
    libyaml-perl \
    make \
    libprotocol-websocket-perl \
    libjson-perl \
    liblwp-protocol-https-perl 
RUN perl -MCPAN -e "install Net::WebSocket::Server" \
    perl -MCPAN -e "install Net::MQTT::Simple" \
    perl -MCPAN -e "install Config::Inifiles"
RUN mkdir -p /opt/zmeventnotification
RUN git clone https://github.com/zoneminder/zmeventnotification.git /opt/zmeventnotification \
    && cd /opt/zmeventnotification \
    && git fetch --tags \
    && git checkout $(git describe --tags $(git rev-list --tags --max-count=1)) \
    && ./install.sh --install-es --install-hook --install-config --no-interactive --hook-config-upgrade --no-pysudo
RUN sed -i 's/^enable = yes/enable = no/g' /etc/zm/zmeventnotification.ini


# Enable and configure Apache
RUN a2enmod cgi \
    && a2enmod rewrite \
    && a2enconf zoneminder

# Set up the entrypoint script
COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

# backup the config to init from there
RUN mkdir -p /org/etc/zm
RUN cp -R /etc/zm/* /org/etc/zm/

HEALTHCHECK --interval=1m --timeout=10s --retries=3 \
    CMD curl -f http://localhost/zm/ || exit 1

# Expose ports
EXPOSE 80 9000

# Define the entrypoint and start services
ENTRYPOINT ["entrypoint.sh"]
