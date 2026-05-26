FROM ghcr.io/astral-sh/uv:python3.11-bookworm-slim

WORKDIR /app

# 先 copy 依賴定義 → 程式碼變動時不會重裝套件，build 快很多
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev

COPY . .

# 讓 .venv 的 python 成為預設 interpreter
ENV PATH="/app/.venv/bin:$PATH"

CMD ["python", "-u", "generator.py", "--backfill", "3"]
