# fdroidserver for release.sh, which builds the release repository locally. The same packages
# as the GitHub Actions job (.github/workflows/publish-dev.yml) installs.
FROM docker.io/library/debian:trixie-slim
RUN apt-get update -qq \
	&& apt-get install -y -qq --no-install-recommends ca-certificates fdroidserver \
	&& rm -rf /var/lib/apt/lists/*
ENV ANDROID_HOME=/usr/lib/android-sdk
