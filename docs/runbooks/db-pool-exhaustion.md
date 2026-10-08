# 런북: DB 커넥션 풀 고갈

- 대상 알림: `DbConnectionPending`(warning, 원인), `WorkerProcessSlow`(warning, 증상)
- 대시보드: `booking-pipeline` (http://localhost:3000/d/booking-pipeline)
- 상태: 초안 (2026-10-08 작성). 판별·확인 절차는 시나리오 결과(로컬·AWS) 근거, 조치 절차(특히 DLQ redrive)는 실행 검증하지 않음

## 0. 알림 역할 분담
- `DbConnectionPending`(> 0, 1분 지속) = **지속 고갈**만 잡음. 30~40초 단위로 생겼다 사라지는 순간 고갈은 놓침 (2026-10-07 시나리오 2a)
- 순간 고갈은 `WorkerProcessSlow`(처리 p95 > 500ms, 2분)가 담당 → WorkerProcessSlow 단독 발화여도 이 런북으로 확인

## 1. 사용자 영향
- Worker 쪽: 예약 확정 지연 → 획득 타임아웃(3초) 반복 시 처리 실패 → 5회 실패 후 DLQ (결과 PROCESSING 유지)
- API 쪽: 앱 풀은 Worker와 분리돼 있지만 **RDS(Proxy) 연결 상한 약 50은 공유** → 연결을 오래 붙잡으면 좌석 선점·조회까지 지연 가능 (2026-10-07 시나리오 2b)

## 2. 1차 트리아지 (5분 이내)
### 2-1. 패턴 확인
- 구간별 p95: **③ Worker 처리만 상승**, ② 큐 대기 평상이면 이 런북 (② 상승이면 `worker-delay.md`)
### 2-2. 어느 Pod의 풀이 고갈됐나
```
max by (pod) (hikaricp_connections_pending{namespace="ticketing"})
max by (pod) (hikaricp_connections_active{namespace="ticketing"})
max by (pod) (hikaricp_connections_max{namespace="ticketing"})
```
- active = max(8)에 붙어 있고 pending > 0인 Pod가 고갈 대상
- Worker만 → 4장 조치 / ticket-service도 → API 영향 동반, 우선순위 상향
### 2-3. DB 쪽 연결 상한
- CloudWatch RDS `DatabaseConnections` (상한 약 50에서 평평하면 DB 측 한도 도달), RDS Proxy `ClientConnections`
### 2-4. 로그
```
sum(count_over_time({namespace="ticketing"} | json | message=~".*Connection is not available.*" [1m]))
{namespace="ticketing", container="booking-worker"} | json | event="worker.processed" | processMs > 500
```
- 획득 타임아웃은 앱 이벤트(`worker.failed`)보다 라이브러리 ERROR 로그(`SqlExceptionHelper`)로 주로 남음 (알려진 추적 공백)
### 2-5. CPU·JVM 원인 배제
- Worker CPU·GC pause 평상이면 DB 연결 보유 시간 증가가 원인

## 3. 원인 후보
- 커넥션을 오래 쥐는 코드 경로 (트랜잭션 안의 느린 쿼리·외부 호출·락 대기)
- 최근 배포 변경 (쿼리·트랜잭션 범위)
- DB 자체 지연 (RDS CPU·IOPS, 락 경합)

## 4. 조치
| 우선 | 조치 | 비고 |
|---|---|---|
| 1 | 최근 배포 확인 → 해당 변경이면 **롤백** (Argo CD 이전 revision) | 원인 제거 |
| 2 | 원인 미확정 + API까지 영향 → Worker 동시 처리 축소(KEDA max 일시 하향)로 **API 보호** | 확정 지연·적체 증가를 감수, 큐가 완충 |
| 3 | 원인 해소 후 DLQ 처리 → `worker-delay.md` 4절 | 해소 전 redrive 금지 |
- 하지 말 것
  - **Worker 확장**: Pod마다 풀 8개 추가 → RDS 상한 50에 먼저 도달, API 연결까지 잠식 (2026-10-07 시나리오 1에서 확장 요청 200 → 연결 50 고정)
  - **풀 크기 증가**: 같은 이유. 보유 시간이 늘어난 원인은 그대로
  - 재시작: 처리 중 메시지 재전달로 부하만 반복

## 5. 복구 확인
- pending 0, active < max, ③ Worker 처리 p95 하강 (`rate[2m]` 창 → 약 2분 지연)
- 처리량 회복, 적체 0, DLQ 추가 유입 없음
- `DbConnectionPending`·`WorkerProcessSlow` RESOLVED

## 6. 에스컬레이션
- RDS DatabaseConnections 상한 도달 + API 지연 동반
- 롤백 대상 없음 + 15분 이상 지속 → DB 담당(쿼리·락 분석)

## 7. 기록할 것
- 시각: 첫 알림(탐지) → 런북 판별 완료(원인 확인) → 조치 또는 "추가 조치 불필요" 결정 → 복구(지표 정상 + 알림 RESOLVED)
- 결정 기록: `시각 | 본 것 | 판단 | 한 일 / 하지 않은 일과 이유` (하지 말 것을 하지 않은 판단도 기록)
- 고갈 Pod·지속 시간, RDS 연결 수 그래프, 실패 건수(ERROR 로그), DLQ 건수와 결정, 조치·시각
