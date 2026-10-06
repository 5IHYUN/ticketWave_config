#!/usr/bin/env bash
# 알림 규칙 검증: PrometheusRule → 규칙 파일 추출 → promtool 문법 검사·단위 테스트
#   promtool 없으면 Docker 이미지(prom/prometheus)의 promtool 사용
# 사용: ./scripts/test-rules.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROM_IMAGE="prom/prometheus:v2.54.1"

"$ROOT/scripts/extract-rules.sh" "$ROOT/build/rules"

run_promtool() {
  if command -v promtool >/dev/null 2>&1; then
    (cd "$ROOT" && promtool "$@")
  else
    docker run --rm -v "$ROOT:/work" -w /work --entrypoint promtool "$PROM_IMAGE" "$@"
  fi
}

run_promtool check rules build/rules/*.rules.yaml
run_promtool test rules tests/*.test.yaml
