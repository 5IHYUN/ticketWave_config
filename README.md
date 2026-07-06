# Team5 Ticket Config 
> GitOps & Kubernetes Configuration Repository  
> ArgoCD 및 Kustomize 기반으로 EKS 클러스터에 배포되는 애플리케이션 Manifest, System Add-on, 오토스케일링 및 관측성 리소스를 선언적으로 관리하는 Config 저장소입니다.

애플리케이션 소스 코드는 [team5-ticket-app](https://github.com/CLD-05/team5-ticket-app)에서 관리하고, AWS 인프라는 [team5-ticket-infra](https://github.com/CLD-05/team5-ticket-infra)에서 Terraform으로 관리합니다.  
이 저장소는 두 저장소 사이에서 실제 Kubernetes 배포 상태를 정의하는 역할을 담당합니다.

즉, app repository에서 빌드된 Docker image tag가 이 저장소의 Kustomize overlay에 반영되면, ArgoCD가 변경 사항을 감지하여 EKS 클러스터에 배포합니다.

---

## 1. 개요 및 설계 목표

이 저장소는 Ticket Wave 플랫폼의 Kubernetes Manifest 및 ArgoCD Application을 관리하는 GitOps Config 저장소입니다.

주요 설계 목표는 다음과 같습니다.

- **dev/prod 환경별 Kubernetes Manifest 관리**: Kustomize overlay를 활용하여 환경별 배포 설정을 분리합니다.
- **ArgoCD 기반 GitOps 배포 구조 구성**: 선언적 매니페스트 동기화와 자동 복구(Self-Healing)를 제공합니다.
- **Web API Pod와 Booking Worker Pod 분리 배포**: 사용자 요청 처리와 예매 확정 처리를 분리합니다.
- **Gateway API 기반 ALB 라우팅 구성**: Ingress 대신 Gateway API(`GatewayClass`, `Gateway`, `HTTPRoute`)를 사용합니다.
- **HPA/KEDA 기반 오토스케일링**: API Pod는 HPA(CPU), Worker Pod는 KEDA(SQS queue depth) 기준으로 확장합니다.
- **External Secrets Operator 기반 Secret 동기화**: AWS Secrets Manager의 민감 정보를 Kubernetes Secret(`ticket-app-secret`)으로 동기화합니다.
- **관측성 및 알림 연동**: Prometheus, Grafana, YACE, Alertmanager를 통해 메트릭 수집과 Slack 알림을 구성합니다.
- **배포 경계 분리**: System Add-on과 Application Manifest의 관리 책임을 분리합니다.

---

## 2. GitOps 아키텍처

```text
app repo (GitHub Actions)
  │
  ├─ Docker build / ECR push
  └─ image tag update (Kustomize Overlay)
        │
        ▼
config repo (GitHub)
  │
  ▼
ArgoCD (EKS Cluster)
  │
  ├─ system-addons
  │   - AWS Load Balancer Controller (Gateway API)
  │   - External Secrets Operator (ESO)
  │   - ExternalDNS (Route53 레코드 관리)
  │   - KEDA (Worker 오토스케일링)
  │   - kube-prometheus-stack (Prometheus, Grafana, Alertmanager)
  │   - YACE (CloudWatch 메트릭 수집 Exporter)
  │   - Cluster Autoscaler & Metrics Server
  │   - StorageClass (EBS GP3 동적 볼륨 프로비저닝)
  │
  └─ ticket application (apps/ticket-app)
      - Gateway / HTTPRoute (ALB 라우팅)
      - ticket-service (Web API Pods, HPA)
      - booking-worker (Worker Pods, KEDA)
      - ServiceMonitor / PrometheusRule (SLI/SLO 및 알림)
```

---

## 3. 저장소 구조

```text
team5-ticket-config/
├── argocd/                         # ArgoCD Project 및 Application 정의
│   ├── project.yaml
│   ├── application-dev.yaml
│   ├── application-prod.yaml
│   ├── application-addons-dev.yaml
│   ├── application-addons-prod.yaml
│   └── application-monitoring.yaml
│
├── apps/
│   └── ticket-app/                 # 애플리케이션 Kustomize Manifest
│       ├── base/
│       │   ├── deployment.yaml     # Web API Pod Deployment
│       │   ├── service.yaml        # ticket-service ClusterIP Service
│       │   ├── serviceaccount.yaml # ticket-service ServiceAccount
│       │   ├── gatewayclass.yaml   # AWS ALB GatewayClass
│       │   ├── gateway.yaml        # Gateway API
│       │   ├── httproute.yaml      # HTTPRoute Routing Rule
│       │   └── loadbalancerconfiguration.yaml
│       └── overlays/
│           ├── dev/
│           │   ├── kustomization.yaml
│           │   ├── deployment-patch.yaml
│           │   ├── deployment-booking-worker.yaml
│           │   ├── service-booking-worker.yaml
│           │   ├── externalsecret.yaml
│           │   ├── hpa.yaml
│           │   ├── scaledobject-booking-worker.yaml
│           │   ├── servicemonitor-booking.yaml
│           │   └── gateway-class-patch.yaml
│           └── prod/
│               ├── kustomization.yaml
│               ├── deployment-patch.yaml
│               ├── deployment-booking-worker.yaml
│               ├── service-booking-worker.yaml
│               ├── externalsecret.yaml
│               ├── hpa.yaml
│               ├── scaledobject-booking-worker.yaml
│               ├── servicemonitor-booking.yaml
│               ├── httproute-patch.yaml
│               ├── gateway-waf-patch.yaml
│               ├── gateway-class-patch.yaml
│               └── service-patch.yaml
│
├── system-addons/                  # Kubernetes System Add-on Manifests
│   ├── base/
│   │   ├── namespaces.yaml
│   │   ├── storageclass.yaml
│   │   ├── external-secrets.yaml
│   │   ├── external-dns.yaml
│   │   ├── aws-load-balancer-controller.yaml
│   │   ├── zipkin.yaml
│   │   └── clustersecretstore.yaml
│   └── overlays/
│       ├── dev/
│       └── prod/
│
└── infra/
    └── monitoring/                 # Grafana Dashboard ConfigMaps
        ├── kustomization.yaml
        ├── team5-overview.json
        ├── team5-sync.json
        ├── team5-system.json
        └── team5-unified.json
```

| 디렉터리 경로 | 역할 |
| --- | --- |
| `argocd` | ArgoCD Project와 환경별 Application 정의 |
| `apps/ticket-app/base` | dev/prod 공통 애플리케이션 매니페스트 |
| `apps/ticket-app/overlays/dev` | dev 환경용 애플리케이션 패치 |
| `apps/ticket-app/overlays/prod` | prod 환경용 애플리케이션 패치 |
| `system-addons/base` | 공통 System Add-on 매니페스트 |
| `system-addons/overlays/dev` | dev 환경 Add-on 설정 |
| `system-addons/overlays/prod` | prod 환경 Add-on 설정 |
| `infra/monitoring` | Grafana Dashboard JSON 및 ConfigMap 관리 |

---

## 4. 환경별 설정 비교

| 구분 | dev 환경 | prod 환경 |
| --- | --- | --- |
| Kustomize Overlay | `apps/ticket-app/overlays/dev` | `apps/ticket-app/overlays/prod` |
| ECR Image | `team5-dev-app` | `team5-prod-app` |
| Spring Profile | `dev` | `prod` |
| Secret Source | `team5/dev/ticket-app` | `team5/prod/ticket-app` |
| SQS Queue Metric | `team5-dev-booking-queue` | `team5-prod-booking-queue.fifo` |
| Web API HPA | Min 1 / Max 5 / CPU 50% | Min 3 / Max 15 / CPU 50% |
| Worker KEDA | Min 1 / Max 20 / Threshold 5 | Min 1 / Max 20 / Threshold 5 |
| Ingress / DNS | ALB DNS 직접 접근 | Route53 (`team5.cloud-infra.shop`) |
| 보안 및 운영 설정 | 기본 보안 규칙 적용 | AWS WAF, Read Replica, S3 CDN 연동 |

---

## 5. Application Manifests 상세

### 5.1 Gateway API

기존 Ingress 대신 Gateway API를 사용하여 ALB 생성과 HTTP 라우팅을 선언적으로 관리합니다.

- **GatewayClass**: AWS Load Balancer Controller와 Gateway API를 연결합니다.
- **Gateway**: ALB의 scheme, listener, target type 등 진입 지점 설정을 정의합니다.
- **HTTPRoute**: 외부 요청을 EKS 내부의 `ticket-service`로 라우팅합니다.

라우팅 흐름은 다음과 같습니다.

```text
ALB
  ↓
Gateway / HTTPRoute
  ↓
ticket-service
  ↓
Web API Pods
```

### 5.2 Web API Pod (`ticket-service`)

사용자 요청을 동기적으로 처리하는 API Pod입니다.

주요 처리 대상은 다음과 같습니다.

- 대기열 진입 및 상태 조회
- 좌석 조회 및 임시 선점
- 예매 요청 접수
- 예매 상태 조회
- 회원, 공연, 예매 내역 관련 API

주요 설정은 다음과 같습니다.

- Container Port: `8080`
- Liveness Probe: `/actuator/health/liveness`
- Readiness Probe: `/actuator/health/readiness`
- HPA 대상 Deployment

### 5.3 Booking Worker Pod (`booking-worker`)

SQS 큐에 적재된 예매 요청 메시지를 소비하여 최종 예매 확정 처리를 수행하는 Worker Pod입니다.

- API Pod와 동일한 Docker 이미지를 사용합니다.
- `SPRING_PROFILES_ACTIVE={env},worker` 형태로 실행 역할을 분리합니다.
- 사용자 외부 트래픽을 직접 받지 않습니다.
- SQS 메시지를 소비한 뒤 BookingProcessor를 통해 RDS에 예매 결과를 저장합니다.
- KEDA ScaledObject를 통해 SQS queue depth 기준으로 확장됩니다.

비동기 처리 흐름은 다음과 같습니다.

```text
SQS Booking Queue
  ↓
Booking Worker Pods
  ↓
BookingProcessor
  ↓
RDS MySQL
```

---

## 6. 오토스케일링

### 6.1 Web API HPA

Web API Pod는 CPU 사용률을 기준으로 HPA가 확장합니다.

- Target CPU Utilization: 50%
- dev: Min 1 / Max 5
- prod: Min 3 / Max 15
- Scale-up Stabilization Window: 60초
- Scale-down Stabilization Window: 300초

이를 통해 티켓 오픈 시점의 동기 API 요청 증가에 대응합니다.

### 6.2 Worker KEDA

Worker Pod는 SQS 큐의 대기 메시지 수를 기준으로 KEDA가 확장합니다.

```text
CloudWatch SQS Metrics
  ↓
YACE
  ↓
Prometheus
  ↓
KEDA ScaledObject
  ↓
booking-worker Scaling
```

주요 설정은 다음과 같습니다.

- `minReplicaCount`: 1
- `maxReplicaCount`: 20
- Threshold: SQS 대기 메시지 5개 기준
- Metric Type: `AverageValue`

Worker Pod는 큐 적체가 발생하기 전에도 최소 1개 이상 실행되도록 구성하여 초기 메시지 처리 지연을 줄입니다.

KEDA가 Deployment replicas를 동적으로 변경하므로, ArgoCD가 이를 불필요한 drift로 판단하지 않도록 `ignoreDifferences` 설정을 적용합니다.

---

## 7. Secrets & Security

민감 정보는 소스코드와 매니페스트에 직접 저장하지 않고 AWS Secrets Manager와 External Secrets Operator를 통해 주입합니다.

Secret 동기화 흐름은 다음과 같습니다.

```text
AWS Secrets Manager
  ↓
External Secrets Operator
  ↓
Kubernetes Secret (ticket-app-secret)
  ↓
Web API / Worker Pod Environment Variables
```

주요 동기화 항목은 다음과 같습니다.

- `SPRING_DATASOURCE_URL`
- `SPRING_DATASOURCE_USERNAME`
- `SPRING_DATASOURCE_PASSWORD`
- `SPRING_DATA_REDIS_HOST`
- `SPRING_DATA_REDIS_PORT`
- `AWS_SQS_BOOKING_QUEUE_URL`
- `AWS_SQS_BOOKING_QUEUE_ARN`
- `JWT_SECRET`
- `SPRING_DATASOURCE_REPLICA_URL`
- `APP_S3_CDN_BASE_URL`

---

## 8. 관측성

### 8.1 Application Metrics

API Pod와 Worker Pod는 Spring Boot Actuator를 통해 Prometheus 형식의 메트릭을 노출합니다.

`ServiceMonitor`는 Prometheus가 API/Worker의 `/actuator/prometheus` endpoint를 주기적으로 수집하도록 scrape target을 등록합니다.

```text
Web API / Worker Pods
  ↓
Spring Boot Actuator
  ↓
ServiceMonitor
  ↓
Prometheus
```

### 8.2 AWS Managed Service Metrics

SQS, RDS, Redis 등 AWS Managed Service의 메트릭은 CloudWatch에 저장됩니다.  
YACE는 CloudWatch 메트릭을 Prometheus 형식으로 변환하여 Prometheus가 함께 수집할 수 있도록 합니다.

```text
AWS Managed Services
  ↓
CloudWatch
  ↓
YACE
  ↓
Prometheus
```

주요 수집 대상은 다음과 같습니다.

- SQS queue depth
- SQS oldest message age
- DLQ message count
- RDS 상태 및 연결 관련 지표
- Redis 상태 및 리소스 지표

### 8.3 Grafana Dashboard

`infra/monitoring`은 Grafana Dashboard JSON 파일을 ConfigMap으로 관리합니다.

- `team5-overview.json`: 전체 시스템 개요
- `team5-sync.json`: SQS 및 KEDA 동기화 상태
- `team5-system.json`: EKS Node / Pod 리소스 사용량
- `team5-unified.json`: 통합 관측성 및 SLO 모니터링

### 8.4 Alert

PrometheusRule은 SLO 위반, 큐 적체, DLQ 메시지 발생 등 주요 조건을 정의합니다.  
조건을 만족하면 Alertmanager를 통해 Slack으로 알림을 전송합니다.

```text
PrometheusRule
  ↓
Alertmanager
  ↓
Slack
```

---

## 9. CI/CD 파이프라인 연동

### 9.1 dev 배포 흐름

```text
app repo push
  ↓
GitHub Actions Build
  ↓
ECR Push
  ↓
config repo dev image tag update
  ↓
ArgoCD Auto Sync
  ↓
dev EKS 배포
```

dev 환경은 애플리케이션 이미지 빌드 후 config repository의 dev overlay image tag를 직접 갱신합니다.  
ArgoCD는 변경된 Kustomize image tag를 감지하여 dev 클러스터에 자동 배포합니다.

### 9.2 prod 승격 흐름

```text
dev 검증 완료
  ↓
prod promotion workflow
  ↓
dev image pull
  ↓
prod ECR retag / push
  ↓
config repo prod image tag PR 생성
  ↓
PR 검토 및 merge
  ↓
ArgoCD Sync
  ↓
prod EKS 배포
```

prod 환경은 dev에서 검증된 이미지를 재사용하여 prod ECR로 승격하는 방식입니다.  
config repository의 prod overlay 변경은 PR 기반으로 관리하여 운영 배포 전 검토 단계를 둡니다.

---

## 10. 운영 가이드라인

운영 시 아래 항목을 주기적으로 확인합니다.

### 10.1 ArgoCD 상태 점검

- `ticket-app-dev`, `ticket-app-prod` Application의 Synced / Healthy 상태 확인
- system-addons Application의 Sync 상태 확인
- HPA/KEDA에 의해 변경되는 replicas가 불필요한 OutOfSync를 만들지 않는지 확인

### 10.2 애플리케이션 상태 점검

- `ticket-service` Pod 상태 확인
- `booking-worker` Pod 상태 확인
- Liveness / Readiness Probe 통과 여부 확인
- `CrashLoopBackOff`, `ImagePullBackOff` 발생 여부 확인

### 10.3 Secret 동기화 점검

- `ticket-app-secret` 생성 여부 확인
- ExternalSecret 동기화 상태 확인
- Secrets Manager 값 변경 시 Pod 환경변수 반영 여부 확인

### 10.4 오토스케일링 점검

- `kubectl get hpa -n ticketing`
- `kubectl get scaledobject -n ticketing`
- HPA CPU target 도달 여부 확인
- KEDA가 SQS queue depth 기준으로 Worker Pod를 확장하는지 확인

### 10.5 관측성 점검

- Prometheus target 상태 확인
- ServiceMonitor scrape 상태 확인
- CloudWatch SQS 지표가 YACE를 통해 Prometheus로 수집되는지 확인
- Grafana Dashboard에서 API 지연, SQS 적체, Worker 처리량, 시스템 리소스 상태 확인
- Alertmanager와 Slack 알림 연동 상태 확인

### 10.6 트래픽 및 DNS 점검

- Route53 레코드가 ALB 주소로 올바르게 매핑되었는지 확인
- ExternalDNS가 prod 도메인 레코드를 정상 반영했는지 확인
- prod Gateway에 연결된 WAF WebACL 동작 여부 확인
- WAF 로그가 CloudWatch로 정상 적재되는지 확인
