# 런북: 예약 Worker 처리 지연 (큐 적체·큐 대기·DLQ)

- 대상 알림: `BookingQueueWaitHigh`(critical, 증상), `BookingBacklogGrowing`(warning, 원인 후보), `BookingDlqNotEmpty`(critical, 원인)
- 대시보드: `booking-pipeline` (http://localhost:3000/d/booking-pipeline)
- 상태: 초안 (2026-10-08 작성). 판별·확인 절차는 시나리오 결과(로컬·AWS) 근거, 조치 절차(특히 DLQ redrive)는 실행 검증하지 않음

## 1. 사용자 영향
- 좌석 선점·예약 접수(API)는 정상, **예약 확정 결과가 늦게 옴** → 결과 폴링 증가, 클라이언트 대기 시간 초과 시 사용자는 "처리 중"만 보게 됨
- DLQ 발생 시: 해당 예약 요청은 처리되지 않고 결과가 PROCESSING에 머묾 (유실 후보)

## 2. 1차 트리아지 (5분 이내)
### 2-1. 어느 구간이 느린가 (대시보드 "구간별 p95")
| 구간 | 이 런북(Worker 처리 지연) | DB 풀 고갈 → `db-pool-exhaustion.md` |
|---|---|---|
| ① SQS 전송 p95 | 평상 | 평상 |
| ② 큐 대기 p95 | **상승** | 평상~약간 |
| ③ Worker 처리 p95 | 평상 | **상승** |
| DB 커넥션 pending | 0 | **양수** |
| 큐 적체 visible | **증가** | 유입 방식에 따라 다름 |
- ③이 함께 올랐거나 pending > 0이면 DB 풀 고갈 런북으로 이동

### 2-2. 처리 용량 vs 유입량
```
sum(rate(booking_confirm_total{namespace="ticketing"}[1m]))
max(booking_sqs_messages{namespace="ticketing", queue="main", state="visible"})
max(booking_sqs_messages{namespace="ticketing", queue="main", state="in_flight"})
```
- Pod 1개 처리량 ≈ 동시 처리 40 ÷ 메시지당 소요 시간
- in_flight가 `40 × Worker 수`에 붙어 있으면 = 처리 슬롯 포화 (메시지당 시간이 길어진 것)
- Worker 수 확인
```bash
kubectl -n ticketing get scaledobject,hpa
kubectl -n ticketing get pods -l app.kubernetes.io/name=booking-worker -o wide
kubectl get pods -A --field-selector=status.phase=Pending
```

### 2-3. 메시지당 시간이 어디서 늘었나 (Loki)
```
{namespace="ticketing", container="booking-worker"} | json | event="worker.processed" | queueWaitMs > 5000
```
- `processMs`(DB 트랜잭션)는 짧은데 `e2eMs - queueWaitMs - processMs` 가 크면 = DB 밖(외부 호출·지연)에서 시간 소모
- 최근 배포 여부: Argo CD `ticket-app-dev` History, `kubectl -n ticketing rollout history deploy/booking-worker`

## 3. 조치
| 상황 | 조치 | 하지 말 것 |
|---|---|---|
| KEDA가 확장 중 (replicas < 3) | 확장 완료까지 관찰. Pending이면 노드 부족 → Cluster Autoscaler 이벤트 확인 | 수동 scale (KEDA가 덮어씀) |
| 확장 상한(3) 도달, 처리량 ≥ 유입량 | 적체 감소 확인 = 자동 대응으로 회복 중 → 복구 확인 단계로 | 상한 상향 (DB 연결 예산 (3+3)×8=48 ≤ 50 초과 → 2026-10-07 연쇄 장애 재발 위험) |
| 상한 도달, 처리량 < 유입량 (적체 계속 증가) | 원인 제거 우선: 최근 배포면 롤백(Argo CD 이전 revision), 외부 의존이면 담당 에스컬레이션. SQS가 완충 → 확정 지연을 공지. 유입 자체를 줄여야 하면 대기열 승격 속도 하향(`QUEUE_PROMOTION_BATCH_SIZE`, ticket-service 재배포 필요 → 새 Pod 워밍업 지연 동반) | Worker 재시작 (처리 중 메시지가 visibility timeout 후 재전달 → 지연만 늘어남) |
| DLQ 발생 | 4절 DLQ 처리 | 바로 redrive (원인 해소 전 재투입 → 다시 DLQ) |

## 4. DLQ 처리
### 4-1. 확인
```bash
aws sqs list-queues --queue-name-prefix team5-dev --region ap-northeast-2
DLQ_URL=<team5-dev-booking-dlq URL>
aws sqs get-queue-attributes --queue-url $DLQ_URL --attribute-names ApproximateNumberOfMessages QueueArn --region ap-northeast-2
aws sqs receive-message --queue-url $DLQ_URL --max-number-of-messages 3 --visibility-timeout 0 --attribute-names ApproximateReceiveCount --region ap-northeast-2
```
- 본문의 `requestId`(bookingRequestId)·`httpRequestId`로 Loki 역추적: `{namespace="ticketing"} | json | bookingRequestId="<ID>"`
- 실패 원인(예: 커넥션 획득 타임아웃)이 **해소됐는지** 먼저 확인

### 4-2. 재처리(redrive) 판단 — 현재 코드 기준 주의점
- Worker는 Redis 좌석 선점(hold) 만료 여부를 보지 않음 → 오래된 메시지도 좌석이 비어 있으면 그대로 확정
- 좌석이 이미 SOLD이면 **소유자 확인 없이 CONFIRMED** 반환 (`worker.already_sold`) → 다른 사람이 산 좌석이면 잘못된 성공 결과
- 결과 키(`result:<requestId>`) TTL 5분 → 사용자가 이미 폴링을 멈췄으면 결과를 못 봄
- 따라서: 원인 해소 확인 → 샘플 메시지 좌석 상태 확인 → redrive 또는 기록 후 폐기 결정, 결정과 근거를 기록

### 4-3. 실행·확인
```bash
DLQ_ARN=<QueueArn>
aws sqs start-message-move-task --source-arn $DLQ_ARN --region ap-northeast-2
aws sqs list-message-move-tasks --source-arn $DLQ_ARN --region ap-northeast-2
```
- 목적지 생략 = 원래 큐(booking-queue)로 이동
- Loki 결과 분포
```
sum by (result) (count_over_time({namespace="ticketing", container="booking-worker"} | json | event="worker.processed" [5m]))
sum(count_over_time({namespace="ticketing", container="booking-worker"} | json | event="worker.already_sold" [5m]))
```

## 5. 복구 확인
- **적체 게이지 0 + 처리량이 유입량 수준** = 복구 (해제 후 수 초~1분)
- `BookingQueueWaitHigh` 해제는 `rate[2m]` 창 때문에 복구 후 약 2분 늦음 → 알림 해제만 기다리지 말 것
- DLQ visible 0, `BookingDlqNotEmpty` RESOLVED
- k6/사용자 지표: 확정률, e2e p95

## 6. 에스컬레이션
- 상한 도달 + 적체 15분 이상 증가 지속
- DLQ 원인을 30분 내 특정 못함
- 노드 NotReady·CoreDNS 재시작 동반 (2026-10-07 연쇄 장애 패턴) → 즉시 부하 원인 차단 우선

## 7. 기록할 것
- 시각: 첫 알림(탐지) → 런북 판별 완료(원인 확인) → 조치 또는 "추가 조치 불필요" 결정 → 복구(지표 정상 + 알림 RESOLVED)
- 결정 기록: `시각 | 본 것 | 판단 | 한 일 / 하지 않은 일과 이유` (하지 말 것을 하지 않은 판단도 기록)
- 알림 발화·Slack 수신 시각, 트리아지 판별 근거(구간별 p95 캡처), Worker 수 변화, 적체 최대·0 도달 시각, DLQ 건수·결정
