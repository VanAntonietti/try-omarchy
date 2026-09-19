# Disposable verification environment, not a guest/factory build input.
FROM oven/bun:1.4.2@sha256:9114c058aeae42162ee16dd5084b95fe9473970bb6bcb5b232ab1630f0546895
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash jq python3 patch shellcheck libjpeg-turbo-progs \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /work/guest/blip
COPY guest/blip/package.json guest/blip/bun.lock ./
RUN bun install --frozen-lockfile
COPY guest/blip/*.py guest/blip/*.ts guest/blip/*.json guest/blip/transport.patch ./
COPY guest/blip/upstream/ ./upstream/
ENV TZ=UTC
CMD ["python3", "test.py", "--upstream"]
