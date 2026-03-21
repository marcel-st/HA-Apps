ARG BUILD_FROM
FROM $BUILD_FROM

RUN apk add --no-cache openssh-client autossh jq python3
COPY run.sh /
COPY update_server.py /
RUN chmod a+x /run.sh

CMD [ "/run.sh" ]
