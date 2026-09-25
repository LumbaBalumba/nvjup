FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

ARG NVIM_VERSION=v0.12.5

RUN apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=5 -o Acquire::http::Timeout=30 update \
    && apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=5 -o Acquire::http::Timeout=30 \
      install --no-install-recommends --yes ca-certificates chafa chromium curl ffmpeg git imagemagick librsvg2-bin \
    && curl --fail --location --retry 3 \
      "https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux-x86_64.tar.gz" \
      -o /tmp/nvim.tar.gz \
    && tar -C /opt -xzf /tmp/nvim.tar.gz \
    && ln -s /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/nvim \
    && rm /tmp/nvim.tar.gz \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --group test --no-install-project

COPY . .

CMD ["./scripts/test"]
