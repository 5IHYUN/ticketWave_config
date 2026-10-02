#!/usr/bin/env bash
# PrometheusRule(CRD) → Prometheus 규칙 파일 변환
#   원본: system-addons/overlays/dev/prometheusrule-*.yaml (k8s 배포용, 알림 규칙의 단일 원본)
#   출력: spec 하위(groups)만 추출, 들여쓰기 2칸 제거 → 로컬 Prometheus·promtool 공용
# 사용: ./scripts/extract-rules.sh [출력 디렉터리]   (기본 build/rules, git 추적 제외)
# 의존성 없음 (awk만 사용, yq 불필요)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/rules}"
mkdir -p "$OUT"

for f in "$ROOT"/system-addons/overlays/dev/prometheusrule-*.yaml; do
  name="$(basename "$f" .yaml)"
  dest="$OUT/${name#prometheusrule-}.rules.yaml"
  awk 'found { sub(/^  /, ""); print } /^spec:/ { found = 1 }' "$f" > "$dest"
  echo "generated: $dest"
done
