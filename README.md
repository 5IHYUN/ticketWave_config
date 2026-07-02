# Team5 Ticket Config

## 1. Overview

이 저장소는 Team5 티켓팅 플랫폼의 Kubernetes Manifest와 ArgoCD Application을 관리하는 GitOps Config 저장소입니다.

애플리케이션 소스 코드는 app repository에서 관리하고, AWS 인프라는 infra repository에서 Terraform으로 관리합니다. 이 저장소는 두 저장소 사이에서 실제 Kubernetes 배포 상태를 정의하는 역할을 담당합니다.

즉, app repository에서 빌드된 Docker image tag가 이 저장소의 Kustomize overlay에 반영되면, ArgoCD가 변경 사항을 감지하여 EKS 클러스터에 배포합니다.

### 주요 목표

- dev/prod 환경별 Kubernetes Manifest 관리
- ArgoCD 기반 GitOps 배포 구조 구성
- Web API Pod와 Booking Worker Pod 분리 배포
- Gateway API 기반 ALB 라우팅 구성
- HPA/KEDA 기반 오토스케일링 구성
- External Secrets Operator 기반 Secret 동기화
- Prometheus/Grafana/YACE 기반 관측성 구성
- system add-ons와 application manifest의 배포 경계 분리

---

## 2. Architecture

Config repository는 EKS 클러스터에 배포되는 Kubernetes 리소스를 선언합니다.

```text
app repo
  |
  |  GitHub Actions
  |  Docker build / ECR push
  v
config repo
  |
  |  image tag update
  |  Kustomize overlay
  v
ArgoCD
  |
  |  sync
  v
EKS
  |
  +-- system add-ons
  |     - AWS Load Balancer Controller
  |     - External Secrets Operator
  |     - ExternalDNS
  |     - KEDA
  |     - kube-prometheus-stack
  |     - YACE
  |     - Cluster Autoscaler
  |     - Metrics Server
  |
  +-- ticket application
        - Gateway / HTTPRoute
        - ticket-service
        - Web API Pod
        - Booking Worker Pod
        - HPA
        - KEDA ScaledObject
        - ServiceMonitor
```

### 핵심 설계 방향

- Application Manifest는 `apps/ticket-app`에서 관리합니다.
- Kubernetes add-on은 `system-addons`에서 관리합니다.
- ArgoCD Application은 `argocd` 디렉터리에서 관리합니다.
- Grafana Dashboard ConfigMap은 `infra/monitoring`에서 관리합니다.
- dev/prod 환경은 Kustomize overlay로 분리합니다.
- ALB 진입은 Ingress가 아니라 Gateway API 중심으로 구성합니다.
- `ticket-service` API Pod는 HPA가 replicas를 관리합니다.
- `booking-worker` Pod는 KEDA가 SQS 지표를 기준으로 replicas를 관리합니다.
- ArgoCD는 HPA/KEDA가 관리하는 replicas drift를 무시하도록 설정합니다.

---

## 3. Repository Structure

```text
team5-ticket-config/
├── argocd/
│   ├── project.yaml
│   ├── application-dev.yaml
│   ├── application-prod.yaml
│   ├── application-addons-dev.yaml
│   ├── application-addons-prod.yaml
│   └── application-monitoring.yaml
│
├── apps/
│   └── ticket-app/
│       ├── base/
│       │   ├── deployment.yaml
│       │   ├── service.yaml
│       │   ├── serviceaccount.yaml
│       │   ├── gatewayclass.yaml
│       │   ├── gateway.yaml
│       │   ├── httproute.yaml
│       │   └── loadbalancerconfiguration.yaml
│       │
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
│           │
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
├── system-addons/
│   ├── base/
│   │   ├── namespaces.yaml
│   │   ├── storageclass.yaml
│   │   ├── external-secrets.yaml
│   │   ├── external-dns.yaml
│   │   ├── aws-load-balancer-controller.yaml
│   │   ├── zipkin.yaml
│   │   └── clustersecretstore.yaml
│   │
│   └── overlays/
│       ├── dev/
│       └── prod/
│
└── infra/
    └── monitoring/
        ├── kustomization.yaml
        ├── team5-overview.json
        ├── team5-sync.json
        ├── team5-system.json
        └── team5-unified.json
```

| Directory | Description |
|-----------|-------------|
| `argocd` | ArgoCD Project와 Application 정의 |
| `apps/ticket-app/base` | dev/prod 공통 application manifest |
| `apps/ticket-app/overlays/dev` | dev application overlay |
| `apps/ticket-app/overlays/prod` | prod application overlay |
| `system-addons/base` | 공통 Kubernetes add-on Application |
| `system-addons/overlays/dev` | dev add-on overlay |
| `system-addons/overlays/prod` | prod add-on overlay |
| `infra/monitoring` | Grafana dashboard ConfigMap 생성용 Kustomize |

---

## 4. Environment

### dev

dev는 개발 및 통합 검증을 위한 환경입니다.

- `apps/ticket-app/overlays/dev`
- ECR image: `team5-dev-app`
- Spring profile: `dev`
- Secret source: `team5/dev/ticket-app`
- SQS queue metric: `team5-dev-booking-queue`
- API HPA: min 1 / max 5
- Worker KEDA: min 1 / max 20
- 일반적으로 ALB DNS 기준 접근

### prod

prod는 운영 환경 기준으로 구성한 환경입니다.

- `apps/ticket-app/overlays/prod`
- ECR image: `team5-prod-app`
- Spring profile: `prod`
- Secret source: `team5/prod/ticket-app`
- SQS queue metric: `team5-prod-booking-queue.fifo`
- API HPA: min 3 / max 8
- Worker KEDA: min 1 / max 20
- Route53 domain: `team5.cloud-infra.shop`
- WAF ACL을 Gateway annotation으로 연결
- Read Replica URL과 CloudFront CDN base URL을 ExternalSecret으로 동기화

---

## 5. Application Manifests

### Gateway API

현재 application 진입 경로는 Gateway API를 기준으로 구성합니다.

```text
User
  |
  v
Route53 / ALB DNS
  |
  v
AWS Load Balancer Controller
  |
  v
Gateway / HTTPRoute
  |
  v
ticket-service
  |
  v
Web API Pods
```

base manifest에는 아래 리소스가 포함됩니다.

- `GatewayClass`
- `Gateway`
- `HTTPRoute`
- `LoadBalancerConfiguration`
- `Service`
- `Deployment`
- `ServiceAccount`


### Web API Pod

`ticket-service` Deployment는 사용자 요청을 처리하는 Spring Boot API Pod입니다.

주요 설정은 다음과 같습니다.

- container port: `8080`
- ServiceAccount: `ticket-service`
- Secret 주입: `ticket-app-secret`
- Actuator readiness/liveness probe 사용
- resource request/limit 설정
- `SPRING_PROFILES_ACTIVE`를 overlay에서 dev/prod로 분리
- `QUEUE_TOKEN_BYPASS=false`
- 환경별 poster bucket 지정

### Booking Worker Pod

`booking-worker` Deployment는 API와 동일한 image를 사용하지만, `worker` profile을 함께 활성화하여 SQS message consumer로 동작합니다.

```text
SQS Booking Queue
  |
  v
booking-worker
  |
  v
Booking Processor
  |
  v
RDS
```

Worker Pod는 사용자 요청을 직접 받지 않으며, SQS에 적재된 예매 요청 메시지를 처리합니다.

---

## 6. Autoscaling

### API HPA

`ticket-service` API Pod는 CPU 사용률을 기준으로 HPA가 확장합니다.

| Environment | Min | Max | Metric |
|-------------|-----|-----|--------|
| dev | 1 | 5 | CPU 50% |
| prod | 3 | 8 | CPU 50% |

scale behavior는 급격한 scale up과 과도한 scale down을 제어하도록 설정되어 있습니다.

- scale up stabilization: 60s
- scale down stabilization: 300s
- scale up policy: 100% or +4 pods / 60s
- scale down policy: 50% / 60s

### Worker KEDA

`booking-worker` Pod는 KEDA ScaledObject가 관리합니다.

KEDA는 SQS를 직접 조회하지 않고, YACE가 CloudWatch에서 수집한 SQS metric을 Prometheus query로 조회합니다.

```text
CloudWatch SQS Metrics
  |
  v
YACE
  |
  v
Prometheus
  |
  v
KEDA ScaledObject
  |
  v
booking-worker replicas
```

| Environment | Queue Metric | Min | Max | Threshold |
|-------------|--------------|-----|-----|-----------|
| dev | `team5-dev-booking-queue` | 1 | 20 | 5 |
| prod | `team5-prod-booking-queue.fifo` | 1 | 20 | 5 |

ArgoCD Application은 HPA/KEDA가 관리하는 `/spec/replicas` drift를 무시하도록 설정되어 있습니다.

---

## 7. System Add-ons

`system-addons`는 애플리케이션 실행과 운영에 필요한 Kubernetes add-on을 관리합니다.

### Common add-ons

| Add-on | Role |
|--------|------|
| AWS Load Balancer Controller | Gateway API 기반 ALB 생성 및 관리 |
| External Secrets Operator | AWS Secrets Manager 값을 Kubernetes Secret으로 동기화 |
| ExternalDNS | Gateway/HTTPRoute 기반 Route53 record 관리 |
| ClusterSecretStore | Secrets Manager 접근용 SecretStore 정의 |
| StorageClass | EBS 기반 동적 볼륨 프로비저닝 |
| Zipkin | 분산 트레이싱 확장용 구성 |

### Environment add-ons

dev/prod overlay는 아래 add-on을 추가로 관리합니다.

| Add-on | Role |
|--------|------|
| KEDA | Worker Pod 오토스케일링 |
| YACE | CloudWatch SQS metric을 Prometheus metric으로 export |
| Cluster Autoscaler | Pending Pod 발생 시 EKS Node Group 확장 |
| kube-prometheus-stack | Prometheus, Grafana, Alertmanager 구성 |
| Metrics Server | HPA resource metric 제공 |
| Alertmanager Slack ExternalSecret | Slack webhook secret 동기화 |

---

## 8. Secrets

Application secret은 External Secrets Operator를 통해 AWS Secrets Manager에서 Kubernetes Secret으로 동기화합니다.

```text
AWS Secrets Manager
  |
  v
ExternalSecret
  |
  v
Kubernetes Secret: ticket-app-secret
  |
  v
Web API Pod / Booking Worker Pod
```

### dev secret source

```text
team5/dev/ticket-app
```

동기화 항목:

- `SPRING_DATASOURCE_URL`
- `SPRING_DATASOURCE_USERNAME`
- `SPRING_DATASOURCE_PASSWORD`
- `SPRING_DATA_REDIS_HOST`
- `SPRING_DATA_REDIS_PORT`
- `AWS_SQS_BOOKING_QUEUE_URL`
- `AWS_SQS_BOOKING_QUEUE_ARN`
- `JWT_SECRET`

### prod secret source

```text
team5/prod/ticket-app
```

dev 항목에 더해 아래 값을 추가로 동기화합니다.

- `SPRING_DATASOURCE_REPLICA_URL`
- `APP_S3_CDN_BASE_URL`

---

## 9. Observability

관측성 구성은 application metric, SQS metric, system metric을 함께 확인하는 것을 목표로 합니다.

### Application metrics

API/Worker Pod는 Spring Boot Actuator metric을 노출합니다.

`servicemonitor-booking.yaml`은 Prometheus가 API/Worker의 Actuator Prometheus endpoint를 scrape하도록 구성합니다.

### SQS metrics

YACE는 CloudWatch의 SQS metric을 Prometheus metric으로 변환합니다.

수집 대상 metric:

- `ApproximateNumberOfMessagesVisible`
- `ApproximateAgeOfOldestMessage`
- `NumberOfMessagesSent`
- `NumberOfMessagesDeleted`

KEDA는 이 metric 중 visible message count를 기준으로 Worker Pod를 확장합니다.

### Grafana dashboards

`infra/monitoring`은 Grafana dashboard JSON 파일을 ConfigMap으로 생성합니다.

```text
infra/monitoring
  |
  v
ConfigMap: team5-grafana-dashboards
  |
  v
Grafana sidecar auto import
```

대시보드 목록:

- `team5-overview.json`
- `team5-sync.json`
- `team5-system.json`
- `team5-unified.json`

---

## 10. ArgoCD Applications

이 저장소는 ArgoCD Application 단위로 배포 대상을 분리합니다.

| Application | Path | Target |
|-------------|------|--------|
| `ticket-app-dev` | `apps/ticket-app/overlays/dev` | dev application |
| `ticket-app-prod` | `apps/ticket-app/overlays/prod` | prod application |
| `system-addons-dev` | `system-addons/overlays/dev` | dev add-ons |
| `system-addons-prod` | `system-addons/overlays/prod` | prod add-ons |
| `application-monitoring` | `infra/monitoring` | Grafana dashboard |

ArgoCD sync policy는 자동 동기화를 기본으로 사용합니다.

```text
automated:
  prune: true
  selfHeal: true
```

prod Application은 Gateway API CRD 초기 검증 문제를 완화하기 위해 `SkipSchemaValidation=true`를 사용합니다.

---

## 11. CI/CD Integration

이 저장소는 app repository의 GitHub Actions workflow와 연결됩니다.

### dev deployment flow

```text
app repo push / merge
  |
  v
GitHub Actions
  |
  v
Docker build
  |
  v
ECR push: team5-dev-app
  |
  v
config repo dev image tag update
  |
  v
ArgoCD sync
  |
  v
EKS dev deploy
```

### prod promotion flow

```text
dev image verified
  |
  v
prod promotion workflow
  |
  v
retag / push to team5-prod-app
  |
  v
config repo prod image tag update
  |
  v
ArgoCD sync
  |
  v
EKS prod deploy
```

Kustomize의 image 설정이 실제 애플리케이션 배포를 트리거하는 기준점입니다.

```yaml
images:
  - name: ticket-service
    newName: 194722398200.dkr.ecr.ap-northeast-2.amazonaws.com/team5-dev-app
    newTag: dev-...
```

```yaml
images:
  - name: ticket-service
    newName: 194722398200.dkr.ecr.ap-northeast-2.amazonaws.com/team5-prod-app
    newTag: prod-...
```

---

## 12. Operations

운영 시 주요 확인 사항은 다음과 같습니다.

### ArgoCD

- Application sync 상태 확인
- `ticket-app-dev`, `ticket-app-prod` sync 상태 확인
- `system-addons-dev`, `system-addons-prod` sync 상태 확인
- HPA/KEDA replicas drift가 ignoreDifferences에 의해 정상 처리되는지 확인

### Application

- `ticket-service` Pod 상태 확인
- `booking-worker` Pod 상태 확인
- readiness/liveness probe 실패 여부 확인
- `ticket-app-secret` 동기화 상태 확인
- Gateway/HTTPRoute accepted 상태 확인
- ALB target group health 확인

### Autoscaling

- HPA current replicas 확인
- KEDA ScaledObject 상태 확인
- Prometheus SQS metric 수집 여부 확인
- Cluster Autoscaler node scale-out 로그 확인

### Observability

- Prometheus target 상태 확인
- YACE metric 수집 여부 확인
- Grafana dashboard import 여부 확인
- Alertmanager Slack 알림 Secret 동기화 확인

### DNS / Traffic

- dev: ALB DNS 접근 확인
- prod: `team5.cloud-infra.shop` 접근 확인
- ExternalDNS record 생성 여부 확인
- prod Gateway WAF annotation 적용 여부 확인


