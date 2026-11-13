FROM docker.io/library/debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y samba smbclient && \
    useradd --uid 1000 --no-create-home --shell /usr/sbin/nologin shelfarr && \
    printf 'shelfarr-test\nshelfarr-test\n' | smbpasswd -a -s shelfarr && \
    mkdir /share && \
    chown shelfarr:shelfarr /share && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY test/filesystem_contracts/smb.conf /etc/samba/smb.conf

EXPOSE 445

CMD ["smbd", "--foreground", "--no-process-group", "--debug-stdout", "--debuglevel=1"]
