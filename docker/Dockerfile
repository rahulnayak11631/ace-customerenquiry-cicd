# Layers on top of the already-built/pushed base image (which itself bakes
# in the full ~4.9GB ACE 13.0.8.0 runtime - see /opt/IBM/Dockerfile on
# ai-poc-worker-02 for how that base was produced). This Dockerfile does NOT
# repeat that install - it only swaps in the freshly-built BAR, which is why
# the CI build step here is fast and only needs the small .bar as context,
# not the whole ACE tree.
FROM rahulnayak11631/customerenqapi:main-7

ARG BAR_FILE
ARG SERVER_NAME=customerenqapi

# Remove whatever BAR shipped in the base image before adding the new one -
# ACE auto-deploys everything it finds in this run/ folder at startup, and
# two BARs defining the same Application name would collide.
RUN rm -f /home/aceuser/ace-server/run/*.bar
COPY ${BAR_FILE} /home/aceuser/ace-server/run/

ENV LICENSE=accept
WORKDIR /opt/IBM/ace-13.0.8.0

ENTRYPOINT ["/bin/bash", "-c", "source /opt/IBM/ace-13.0.8.0/server/bin/mqsiprofile && IntegrationServer --work-dir /home/aceuser/ace-server --name ${SERVER_NAME} --http-port-number 7800"]
