# - Create 'build and test' image -
FROM ubuntu:20.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update -qq \
    && apt-get install --no-install-recommends -y  \
        autoconf \
        automake \
        ca-certificates  \
        expat \
        fcgiwrap \
        g++ \
        git \
        libexpat1-dev \
        libbz2-dev \
        libcereal-dev \
        libfcgi-dev \
        libfmt-dev \
        libgoogle-perftools-dev \
        libicu-dev \
        liblz4-dev \
        libpcre2-dev \
        libtool \
        libxml2-dev \
        make \
        zlib1g-dev \
    && update-ca-certificates \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Clone mmd-osm/Overpass-API repository
RUN git clone --depth 1 https://github.com/mmd-osm/Overpass-API.git overpass \
    && cd overpass \
    && git submodule init \
    && git submodule update \
    && cd ..

# Change working directory
WORKDIR /overpass

# Compile sources
RUN cd src/ \
    && chmod u+x test-bin/*.sh \
    && autoscan \
    && aclocal \
    && autoheader \
    && libtoolize \
    && automake --add-missing \
    && autoconf \
    && cd .. \
    && mkdir -p build \
    && cd build \
    && ../src/configure  \
        CXXFLAGS="-D_FORTIFY_SOURCE=2 -fexceptions -fpie -Wl,-pie -fpic -shared -fstack-protector-strong -Wl,--no-as-needed -pipe -Wl,-z,defs -Wl,-z,now -Wl,-z,relro -fno-omit-frame-pointer -flto -fwhole-program  -O2"  \
        LDFLAGS="-ltcmalloc -flto -fwhole-program -lfmt"  \
        --prefix=/root/overpass  \
        --enable-lz4  \
        --enable-fastcgi  \
        --enable-tests

# Build and install binaries
RUN cd build \
    && make V=0 -j3 \
    && make install \
    && cp -R test-bin/ bin/ cgi-bin/ ../src \
    && export PATH=$PATH:/root/overpass/bin:/root/overpass/cgi-bin:/root/overpass/test-bin

# Run tests
RUN cd osm-3s_testing/ \
    && ../src/test-bin/run_testsuite.sh 200 notimes

# Compile export tool for database files
RUN cd src/ \
    && make V=0 -j3 bin/export_tables \
    && strip bin/export_tables \
    && cp bin/export_tables /root/overpass/bin/export_tables_0756 \
    && cd ..

# --------------------------------------------------------------------------------------------------------------
# - Create final image -
FROM nginx:1.21

# Install dependencies
RUN apt-get update -qq \
    && apt-get install --no-install-recommends -y \
        bash \
        bzip2 \
        curl \
        expat \
        fcgiwrap \
        git \
        jq \
        libfcgi-bin \
        liblz4-1 \
        libgomp1 \
        libgoogle-perftools4 \
        libpcre2-8-0 \
        nginx \
        osmium-tool \
        python3 \
        python3-venv \
        supervisor \
        wget \
        zlib1g  \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN wget http://archive.ubuntu.com/ubuntu/pool/main/i/icu/libicu66_66.1-2ubuntu2_amd64.deb \
    && dpkg -i libicu66_66.1-2ubuntu2_amd64.deb \
    && rm libicu66_66.1-2ubuntu2_amd64.deb

# Copy binaries and rules
COPY --from=builder /root/overpass/bin /opt/overpass/bin
COPY --from=builder /root/overpass/cgi-bin /opt/overpass/cgi-bin
COPY --from=builder /overpass/src/rules /opt/overpass/rules

# Create overpass user
RUN addgroup overpass \
    && adduser --home /db --disabled-password --gecos overpass --ingroup overpass overpass

# Clone lhbelfanti/overpass-api repository
RUN git clone --depth 1 https://github.com/lhbelfanti/overpass-api scripts \
    && cd scripts

# Install python dependencies
COPY requirements.txt /opt/overpass/

RUN python3 -m venv /opt/overpass/venv \
    && /opt/overpass/venv/bin/pip install -r /opt/overpass/requirements.txt --only-binary osmium

# Create necessary folders for the database initialization
RUN mkdir -p /db/diffs \
    /opt/overpass/etc \
    /nginx \
    /docker-entrypoint-initdb.d

RUN chown nginx:nginx /nginx \
    && chown -R overpass:overpass /db

# Copy configuration files
COPY etc/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

COPY etc/nginx-overpass.conf.template /etc/nginx/nginx.conf.template

# Copy scripts files and give them permissions
COPY bin/update_overpass.sh \
    bin/update_overpass_loop.sh \
    bin/rules_loop.sh \
    bin/dispatcher_start.sh \
    bin/start_fcgiwrap.sh \
    /opt/overpass/bin/

COPY docker-entrypoint.sh docker-healthcheck.sh /opt/overpass/

RUN chmod a+rx /opt/overpass/docker-entrypoint.sh  \
    /opt/overpass/bin/update_overpass.sh \
    /opt/overpass/bin/rules_loop.sh \
    /opt/overpass/bin/dispatcher_start.sh \
    /opt/overpass/bin/start_fcgiwrap.sh

EXPOSE 80

HEALTHCHECK --start-period=48h CMD /opt/overpass/docker-healthcheck.sh

CMD ["/opt/overpass/docker-entrypoint.sh"]