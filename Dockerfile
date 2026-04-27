FROM ghcr.io/prefix-dev/pixi:latest

WORKDIR /app

COPY pixi.toml ./
RUN pixi install -e grthub-bclconvert

ENV PATH=/app/.pixi/envs/grthub-bclconvert/bin:$PATH
ENV CONDA_DEFAULT_ENV=grthub-bclconvert

CMD ["/bin/bash"]
