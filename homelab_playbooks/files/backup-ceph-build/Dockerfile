# Stage 1: Use the official AWS CLI image as the source
FROM amazon/aws-cli:latest AS awscli-builder

# Stage 2: Copy the AWS CLI binary into rook/ceph
FROM rook/ceph:v1.15.5

USER root

COPY --from=awscli-builder /usr/local/aws-cli /usr/local/aws-cli

RUN ln -s /usr/local/aws-cli/v2/current/bin/aws /usr/bin/aws && \
    ln -s /usr/local/aws-cli/v2/current/bin/aws_completer /usr/bin/aws_completer

# Verify installation
RUN aws --version

# docker build \
#   --platform linux/amd64 \
#   -t "registry.thekor.eu/kube/rook/rook-ceph-mytoolbox:latest" \
#   .